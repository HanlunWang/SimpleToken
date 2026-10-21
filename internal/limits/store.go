package limits

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand/v2"
	"slices"
	"sync"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/proc"
)

// State is where a provider's probing stands.
type State int

const (
	StateIdle          State = iota // not read yet
	StateRefreshing                 // a probe is running
	StateOK                         // the last probe succeeded
	StateFailed                     // the last probe failed; Status.Reason says why (the UI shows "Unreachable")
	StateNotConfigured              // no credentials / no CLI / no sign-in
)

func (s State) String() string {
	switch s {
	case StateRefreshing:
		return "refreshing"
	case StateOK:
		return "ok"
	case StateFailed:
		return "failed"
	case StateNotConfigured:
		return "not configured"
	}
	return "idle"
}

// Status is one provider's probe state.
type Status struct {
	State State
	// Reason is the failure for StateFailed.
	Reason string
	// UpdatedAt is the last successful probe (zero before the first).
	UpdatedAt time.Time
}

// Refreshing reports whether a probe is running.
func (s Status) Refreshing() bool { return s.State == StateRefreshing }

// Entry is one provider's latest snapshot and status.
type Entry struct {
	Provider Provider
	// Snapshot is the last successful read (kept through later failures); nil before the first.
	Snapshot *Snapshot
	Status   Status
	Hidden   bool
}

// Scheduling (unchanged from the Swift app).
const (
	regularDelay      = 5 * time.Minute // every provider, every 5 minutes …
	afterResetDelay   = 30 * time.Second
	backoffBase       = 5 * time.Second // … with exponential backoff on failure: 5 s → 5 min, half jitter
	backoffCap        = 5 * time.Minute
	claudeUnsetDelay  = 5 * time.Minute  // no cookie yet: look again soon (the owner may paste one)
	missingToolDelay  = 15 * time.Minute // no codex CLI / no Cursor sign-in
	oneShotProbeLimit = time.Minute
)

// probeFunc reads one provider. ErrNotConfigured marks it not set up.
type probeFunc func(ctx context.Context) (Snapshot, error)

type providerState struct {
	snap     *Snapshot
	status   Status
	failures int
	probing  sync.Mutex // one probe per provider at a time
	kick     chan struct{}
}

// Store keeps the Claude, Codex and Cursor limits fresh. Each provider refreshes every 5 minutes, 30 s after a
// window reset when that comes sooner, and backs off exponentially on failure. A rotated Claude sessionKey is
// written back at once. All methods are safe for concurrent use.
type Store struct {
	// OnChange is called (from a background goroutine, never under the store's lock) after any snapshot, status or
	// visibility change. Set it before Start; it must not call Stop.
	OnChange func()

	creds *CredentialStore

	mu        sync.Mutex
	providers map[Provider]*providerState
	hidden    map[Provider]bool
	probes    map[Provider]probeFunc
	unset     map[Provider]time.Duration // delay after ErrNotConfigured
	cancel    context.CancelFunc
	wg        sync.WaitGroup

	// Claude probe state, touched only while holding the Claude provider's probing lock (planLabel under mu).
	claudeOrgID string
	planLabel   string
	// claudeBaseURL overrides claude.ai (tests); planLabelLoader reads Claude Code's plan metadata.
	claudeBaseURL   string
	planLabelLoader func(ctx context.Context) string
	now             func() time.Time
}

// NewStore wires the real probes; creds holds the Claude sessionKey (NewCredentialStore for the standard file).
func NewStore(creds *CredentialStore) *Store {
	s := &Store{
		creds:           creds,
		providers:       map[Provider]*providerState{},
		hidden:          map[Provider]bool{},
		unset:           map[Provider]time.Duration{Claude: claudeUnsetDelay, Codex: missingToolDelay, Cursor: missingToolDelay},
		planLabelLoader: loadClaudePlanLabel,
		now:             time.Now,
	}
	for _, p := range Providers {
		s.providers[p] = &providerState{kick: make(chan struct{}, 1)}
	}
	s.probes = map[Provider]probeFunc{
		Claude: s.probeClaude,
		Codex: func(ctx context.Context) (Snapshot, error) {
			exe := LocateCodex()
			if exe == "" {
				return Snapshot{}, ErrNotConfigured
			}
			return CodexProbe{Executable: exe}.Probe(ctx)
		},
		Cursor: func(ctx context.Context) (Snapshot, error) {
			token, ok := LocateCursorToken()
			if !ok {
				return Snapshot{}, ErrNotConfigured
			}
			return CursorProbe{Token: token}.Probe(ctx)
		},
	}
	return s
}

// Start begins probing every provider (and reads the Claude plan label once). Calling it while running is a no-op.
func (s *Store) Start() {
	s.mu.Lock()
	if s.cancel != nil {
		s.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.mu.Unlock()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.loadPlanLabel(ctx)
	}()
	for _, p := range Providers {
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.loop(ctx, p)
		}()
	}
}

// Stop ends probing and waits for running probes to return (they are cancelled).
func (s *Store) Stop() {
	s.mu.Lock()
	cancel := s.cancel
	s.cancel = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.wg.Wait()
}

// RefreshNow probes every provider now. While running, the schedule loops are woken (a probe already in flight
// is not duplicated); otherwise each provider is probed once in the background.
func (s *Store) RefreshNow() {
	s.mu.Lock()
	running := s.cancel != nil
	s.mu.Unlock()
	for _, p := range Providers {
		ps := s.providers[p]
		if running {
			select {
			case ps.kick <- struct{}{}:
			default:
			}
			continue
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), oneShotProbeLimit)
			defer cancel()
			s.refresh(ctx, p)
		}()
	}
}

func (s *Store) loop(ctx context.Context, p Provider) {
	ps := s.providers[p]
	for {
		delay := s.refresh(ctx, p)
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		case <-ps.kick:
			t.Stop()
		}
	}
}

// refresh runs one probe and returns the delay until the next.
func (s *Store) refresh(ctx context.Context, p Provider) time.Duration {
	ps := s.providers[p]
	ps.probing.Lock()
	defer ps.probing.Unlock()
	if ctx.Err() != nil {
		return regularDelay
	}

	s.mu.Lock()
	ps.status.State, ps.status.Reason = StateRefreshing, ""
	s.mu.Unlock()
	s.changed()

	snap, err := s.probes[p](ctx)

	s.mu.Lock()
	var delay time.Duration
	switch {
	case err == nil:
		if p == Claude && snap.AccountLabel == "" {
			snap.AccountLabel = s.planLabel
		}
		ps.snap = &snap
		ps.status = Status{State: StateOK, UpdatedAt: s.now()}
		ps.failures = 0
		delay = nextRegularDelay(snap, s.now())
	case errors.Is(err, ErrNotConfigured):
		ps.status.State, ps.status.Reason = StateNotConfigured, ""
		delay = s.unset[p]
	case ctx.Err() != nil:
		// Stopped mid-probe: not a failure of the source.
		if ps.snap != nil {
			ps.status.State = StateOK
		} else {
			ps.status.State = StateIdle
		}
		delay = regularDelay
	default:
		ps.status.State, ps.status.Reason = StateFailed, err.Error()
		ps.failures++
		delay = backoffDelay(ps.failures)
	}
	s.mu.Unlock()
	s.changed()
	return delay
}

func (s *Store) changed() {
	if f := s.OnChange; f != nil {
		f()
	}
}

// Get returns one provider's entry.
func (s *Store) Get(p Provider) Entry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.entry(p)
}

func (s *Store) entry(p Provider) Entry {
	e := Entry{Provider: p, Hidden: s.hidden[p]}
	ps, ok := s.providers[p]
	if !ok {
		return e
	}
	e.Status = ps.status
	if ps.snap != nil {
		c := *ps.snap
		c.Windows = slices.Clone(c.Windows)
		e.Snapshot = &c
	}
	return e
}

// Entries returns every provider in display order, hidden ones included (Entry.Hidden).
func (s *Store) Entries() []Entry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Entry, 0, len(Providers))
	for _, p := range Providers {
		out = append(out, s.entry(p))
	}
	return out
}

// Snapshots returns the snapshots read so far (hidden providers included), in display order.
func (s *Store) Snapshots() []Snapshot {
	var out []Snapshot
	for _, e := range s.Entries() {
		if e.Snapshot != nil {
			out = append(out, *e.Snapshot)
		}
	}
	return out
}

// Busy reports whether any probe is running (a manual refresh waits for this to settle).
func (s *Store) Busy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, ps := range s.providers {
		if ps.status.State == StateRefreshing {
			return true
		}
	}
	return false
}

// SetHidden shows or hides a provider in the UI and its alerts. Hidden providers are still probed.
func (s *Store) SetHidden(p Provider, hidden bool) {
	s.mu.Lock()
	if s.hidden[p] == hidden {
		s.mu.Unlock()
		return
	}
	if hidden {
		s.hidden[p] = true
	} else {
		delete(s.hidden, p)
	}
	s.mu.Unlock()
	s.changed()
}

// SetHiddenProviders replaces the hidden set (e.g. from settings).
func (s *Store) SetHiddenProviders(hidden []Provider) {
	s.mu.Lock()
	next := map[Provider]bool{}
	for _, p := range hidden {
		next[p] = true
	}
	same := len(next) == len(s.hidden)
	for p := range next {
		same = same && s.hidden[p]
	}
	s.hidden = next
	s.mu.Unlock()
	if !same {
		s.changed()
	}
}

// Hidden returns the hidden providers.
func (s *Store) Hidden() map[Provider]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[Provider]bool, len(s.hidden))
	for p := range s.hidden {
		out[p] = true
	}
	return out
}

// LoadDemo fills synthetic snapshots for the demo mode; nothing is probed (do not Start).
func (s *Store) LoadDemo(snaps ...Snapshot) {
	s.mu.Lock()
	for _, snap := range snaps {
		ps, ok := s.providers[snap.Provider]
		if !ok {
			continue
		}
		c := snap
		c.Windows = slices.Clone(snap.Windows)
		ps.snap = &c
		ps.status = Status{State: StateOK, UpdatedAt: snap.UpdatedAt}
	}
	s.mu.Unlock()
	s.changed()
}

// MARK: Claude

func (s *Store) probeClaude(ctx context.Context) (Snapshot, error) {
	cookie := s.creds.ClaudeCookie()
	if cookie == "" && s.creds.ImportLegacyIfMissing() {
		cookie = s.creds.ClaudeCookie()
	}
	if cookie == "" {
		return Snapshot{}, ErrNotConfigured
	}
	probe, err := NewClaudeWebProbe(cookie)
	if err != nil {
		return Snapshot{}, err
	}
	probe.BaseURL = s.claudeBaseURL
	res, err := probe.Probe(ctx, s.claudeOrgID)
	if err != nil {
		// A stale organisation can cause a 401: redo the full flow next time.
		s.claudeOrgID = ""
		return Snapshot{}, err
	}
	s.claudeOrgID = res.OrganizationID
	if res.RenewedSessionKey != "" {
		_ = s.creds.SetClaudeCookie(res.RenewedSessionKey)
	}
	return res.Snapshot, nil
}

func (s *Store) loadPlanLabel(ctx context.Context) {
	if s.planLabelLoader == nil {
		return
	}
	label := s.planLabelLoader(ctx)
	if label == "" {
		return
	}
	s.mu.Lock()
	s.planLabel = label
	ps := s.providers[Claude]
	patched := false
	if ps.snap != nil && ps.snap.AccountLabel == "" {
		c := *ps.snap
		c.AccountLabel = label
		ps.snap = &c
		patched = true
	}
	s.mu.Unlock()
	if patched {
		s.changed()
	}
}

// loadClaudePlanLabel reads only the subscriptionType / rateLimitTier metadata of Claude Code's Keychain item (new
// builds keep no token there, but the metadata stays). The secret's content is parsed in memory and never kept.
func loadClaudePlanLabel(ctx context.Context) string {
	out, err := proc.Run(ctx, "/usr/bin/security", []string{"find-generic-password", "-s", "Claude Code-credentials", "-w"}, 5*time.Second)
	if err != nil || out.ExitCode != 0 {
		return ""
	}
	return claudePlanLabelFromCredentials(out.Stdout)
}

func claudePlanLabelFromCredentials(data []byte) string {
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil || root == nil {
		return ""
	}
	oauth := object(root["claudeAiOauth"])
	if oauth == nil {
		oauth = root
	}
	sub, _ := str(oauth["subscriptionType"])
	tier, _ := str(oauth["rateLimitTier"])
	return ClaudePlanLabel(sub, tier)
}

// MARK: Scheduling

// nextRegularDelay is 5 minutes, or 30 s after the nearest future reset when that is sooner (at least 30 s).
func nextRegularDelay(snap Snapshot, now time.Time) time.Duration {
	var nearest *time.Time
	for _, w := range snap.Windows {
		if w.ResetsAt != nil && w.ResetsAt.After(now) && (nearest == nil || w.ResetsAt.Before(*nearest)) {
			nearest = w.ResetsAt
		}
	}
	if nearest != nil {
		if d := nearest.Sub(now) + afterResetDelay; d < regularDelay {
			return max(afterResetDelay, d)
		}
	}
	return regularDelay
}

// backoffDelay for the n-th consecutive failure: base 5 s doubling to a 5 min cap, half jitter.
func backoffDelay(n int) time.Duration {
	base := backoffCap
	if n-1 < 16 {
		base = min(backoffCap, backoffBase<<max(0, n-1))
	}
	half := base / 2
	return half + time.Duration(rand.Int64N(int64(half)+1))
}
