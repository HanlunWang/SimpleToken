// Package collector schedules the tokscale scans behind every usage number: full ticks (three serial period scans
// that re-anchor month and all time) and watch ticks (a --today scan only, with month and all time derived from
// the anchor arithmetically). It also owns the daily history store.
//
// Cost: each scan takes about 1.2 CPU-s and a ~570 MB child process, so watch ticks are throttled (LiveInterval,
// default 30 s, however often logs are written) and paused while nothing visible needs live numbers (SetLive);
// a paused store only marks itself dirty and catches up once on resume.
package collector

import (
	"context"
	"sync"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/history"
	"github.com/HanlunWang/SimpleToken/internal/paths"
	"github.com/HanlunWang/SimpleToken/internal/tokscale"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Defaults for the scan intervals (the settings' liveRefreshSeconds and fullRefreshMinutes).
const (
	DefaultLiveInterval     = 30 * time.Second
	DefaultFullInterval     = 15 * time.Minute
	DefaultFallbackInterval = 5 * time.Minute
	// minWatchWait lets a burst of log writes land before a watch tick scans.
	minWatchWait = 2 * time.Second
)

// Scanner runs tokscale (tokscale.Runner). Calls must be serial; the Runner guarantees it.
type Scanner interface {
	Scan(ctx context.Context, s tokscale.Scan) (usage.Report, error)
	Graph(ctx context.Context) (usage.Graph, error)
	Fingerprint() string
}

// Paths names the files the store reads and writes.
type Paths struct {
	Anchor, Timeline, Hourly string
	// Archive is the daily history; LegacyArchive the Token Monitor archive absorbed once ("" skips it).
	Archive, LegacyArchive string
}

// DefaultPaths are the files in the SimpleToken data directory.
func DefaultPaths() Paths {
	return Paths{
		Anchor:        paths.CollectorAnchor(),
		Timeline:      paths.TodayTimeline(),
		Hourly:        paths.HourlyHistory(),
		Archive:       paths.DailyArchive(),
		LegacyArchive: paths.LegacyArchive(),
	}
}

// Store collects usage. Ticks are single-flight: at most one runs at a time, and requests arriving meanwhile
// coalesce into one replay (a pending full tick covers a pending watch tick). All methods are safe for
// concurrent use.
type Store struct {
	sc          Scanner
	paths       Paths
	fingerprint string
	hist        *history.Store

	wg sync.WaitGroup

	mu           sync.Mutex
	running      bool
	ctx          context.Context
	cancel       context.CancelFunc
	onChange     func()
	beforeFull   func(context.Context)
	liveInterval time.Duration
	fullInterval time.Duration
	fallback     time.Duration
	live         bool
	poked        bool // an external file watcher calls Poke: the fallback timer stands down
	dirty        bool // logs changed but not collected yet
	watchTimer   *time.Timer
	pendingFull  bool
	pendingWatch bool
	inFlight     bool
	lastTickAt   time.Time
	minWait      time.Duration
	collecting   bool
	snapshot     *usage.Snapshot
	lastErr      error
	anchor       *Anchor
	timeline     Timeline
	hourly       HourlyHistory
}

// New prepares a store; nothing runs until Start. A saved anchor from today with the same scan configuration
// becomes the first snapshot at once (a full scan then corrects it).
func New(sc Scanner, p Paths) *Store {
	s := &Store{
		sc:           sc,
		paths:        p,
		fingerprint:  sc.Fingerprint(),
		hist:         history.NewStore(sc, p.Archive, p.LegacyArchive),
		liveInterval: DefaultLiveInterval,
		fullInterval: DefaultFullInterval,
		fallback:     DefaultFallbackInterval,
		live:         true,
		minWait:      minWatchWait,
	}
	s.hist.SetOnChange(s.notify)
	now := time.Now()
	if !loadJSON(p.Timeline, &s.timeline) {
		s.timeline = Timeline{DayKey: usage.DayKey(now)}
	}
	if !loadJSON(p.Hourly, &s.hourly) || s.hourly.Days == nil {
		s.hourly = HourlyHistory{Days: map[string][]int64{}}
	}
	if a, ok := LoadAnchor(p.Anchor, s.fingerprint); ok && a.DayKey == usage.DayKey(now) {
		s.anchor = &a
		s.snapshot = &usage.Snapshot{Today: a.Today, Month: a.Month, AllTime: a.AllTime, CollectedAt: a.CollectedAt, DayKey: a.DayKey}
	}
	return s
}

// History is the daily history store (started and stopped with this store).
func (s *Store) History() *history.Store { return s.hist }

// SetOnChange sets the callback run after the snapshot, the last error or the history changes. It is called
// from any goroutine, never with a lock held; set it before Start.
func (s *Store) SetOnChange(f func()) {
	s.mu.Lock()
	s.onChange = f
	s.mu.Unlock()
}

// SetBeforeFullScan sets a hook run before every full scan, such as tokscale.CursorSync.SyncIfDue so the scans
// read a fresh Cursor cache.
func (s *Store) SetBeforeFullScan(f func(context.Context)) {
	s.mu.Lock()
	s.beforeFull = f
	s.mu.Unlock()
}

// SetLiveInterval sets the minimum gap between watch ticks (liveRefreshSeconds).
func (s *Store) SetLiveInterval(d time.Duration) {
	s.mu.Lock()
	s.liveInterval = d
	s.mu.Unlock()
}

// SetFullInterval sets the full rescan interval (fullRefreshMinutes); it applies from the next round.
func (s *Store) SetFullInterval(d time.Duration) {
	if d <= 0 {
		d = DefaultFullInterval
	}
	s.mu.Lock()
	s.fullInterval = d
	s.mu.Unlock()
}

// SetFallbackInterval sets how often the store pokes itself while no file watcher has called Poke
// (0 disables it). Once Poke is called the fallback stands down for good.
func (s *Store) SetFallbackInterval(d time.Duration) {
	s.mu.Lock()
	s.fallback = d
	s.mu.Unlock()
}

// SetLive switches live collection: off when no window or panel is visible and the menu bar shows no today
// numbers. While off, Poke only marks the store dirty; turning it back on runs one catch-up tick.
func (s *Store) SetLive(on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	was := s.live
	s.live = on
	if on && !was && s.dirty {
		s.scheduleWatchLocked()
	}
}

// Poke reports that usage logs changed (call it from the ~/.claude/projects and ~/.claude/transcripts watcher).
// A watch tick follows, throttled to LiveInterval since the last collection.
func (s *Store) Poke() {
	s.mu.Lock()
	s.poked = true
	s.dirty = true
	s.scheduleWatchLocked()
	s.mu.Unlock()
}

// RequestFull asks for a full rescan (a manual refresh). It is ignored before Start.
func (s *Store) RequestFull() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running {
		return
	}
	s.pendingFull = true
	s.spawnDrainLocked()
}

// Start runs a full scan now, then one every FullInterval, and starts the history refresh. Starting a running
// store is a no-op.
func (s *Store) Start(ctx context.Context) {
	s.mu.Lock()
	if s.running {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.ctx, s.cancel = context.WithCancel(ctx)
	runCtx := s.ctx
	s.pendingFull = true
	s.spawnDrainLocked()
	s.wg.Add(2)
	s.mu.Unlock()

	go s.fullLoop(runCtx)
	go s.fallbackLoop(runCtx)
	s.hist.Start(runCtx)
}

// Stop cancels any running scan, stops the timers and waits for the store's goroutines.
func (s *Store) Stop() {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return
	}
	s.running = false
	s.cancel()
	if s.watchTimer != nil {
		s.watchTimer.Stop()
		s.watchTimer = nil
	}
	s.mu.Unlock()
	s.hist.Stop()
	s.wg.Wait()
}

// LoadDemo shows a synthetic snapshot instead of collecting (do not Start the store).
func (s *Store) LoadDemo(snap usage.Snapshot) {
	s.mu.Lock()
	s.snapshot = &snap
	s.mu.Unlock()
	s.notify()
}

// Snapshot is the latest collection; ok is false before the first one. Treat its maps as read-only.
func (s *Store) Snapshot() (snap usage.Snapshot, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.snapshot == nil {
		return usage.Snapshot{}, false
	}
	return *s.snapshot, true
}

// LastError is the last tick's error, nil when it went through.
func (s *Store) LastError() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastErr
}

// IsCollecting reports whether a scan is running. It is not notified through OnChange (background ticks must not
// drive UI animation); poll it while waiting for a manual refresh.
func (s *Store) IsCollecting() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.collecting
}

// Timeline is a copy of today's cumulative samples.
func (s *Store) Timeline() Timeline {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.timeline.clone()
}

// Hourly is a copy of the half-hour history of the last 14 days.
func (s *Store) Hourly() HourlyHistory {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hourly.clone()
}

func (s *Store) notify() {
	s.mu.Lock()
	f := s.onChange
	s.mu.Unlock()
	if f != nil {
		f()
	}
}

func (s *Store) fullLoop(ctx context.Context) {
	defer s.wg.Done()
	for {
		s.mu.Lock()
		d := s.fullInterval
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-time.After(d):
		}
		s.RequestFull()
	}
}

func (s *Store) fallbackLoop(ctx context.Context) {
	defer s.wg.Done()
	for {
		s.mu.Lock()
		d, active := s.fallback, !s.poked
		s.mu.Unlock()
		if !active {
			return
		}
		if d <= 0 {
			d = time.Minute // disabled: look again later
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(d):
		}
		s.mu.Lock()
		if !s.poked && s.fallback > 0 {
			s.dirty = true
			s.scheduleWatchLocked()
		}
		s.mu.Unlock()
	}
}

// scheduleWatchLocked arms the watch timer. Throttle, not debounce: an armed timer is never pushed back, so
// constant log writes cannot starve it; it waits out the rest of LiveInterval since the last collection, and at
// least two seconds so a burst of writes lands.
func (s *Store) scheduleWatchLocked() {
	if !s.running || !s.live || s.watchTimer != nil {
		return
	}
	wait := max(s.minWait, s.liveInterval-time.Since(s.lastTickAt))
	s.watchTimer = time.AfterFunc(wait, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.watchTimer = nil
		if !s.running {
			return
		}
		s.pendingWatch = true
		s.spawnDrainLocked()
	})
}

// spawnDrainLocked starts a drain unless one is running (it picks the request up). Only called while running,
// so Stop's Wait never races an Add.
func (s *Store) spawnDrainLocked() {
	if s.inFlight || !s.running {
		return
	}
	s.inFlight = true
	ctx := s.ctx
	s.wg.Add(1)
	go s.drain(ctx)
}

func (s *Store) drain(ctx context.Context) {
	defer s.wg.Done()
	s.mu.Lock()
	for (s.pendingFull || s.pendingWatch) && ctx.Err() == nil {
		// Full wins: a coalesced watch request is covered by the full scan, which includes the latest today
		full := s.pendingFull
		s.pendingFull, s.pendingWatch, s.dirty = false, false, false
		s.lastTickAt = time.Now()
		s.mu.Unlock()

		var err error
		if full {
			err = s.runFull(ctx)
		} else {
			err = s.runWatch(ctx)
		}

		s.mu.Lock()
		if ctx.Err() != nil {
			break // stopped: a cancelled scan is not an error worth showing
		}
		s.lastErr = err
		s.mu.Unlock()
		s.notify()
		s.mu.Lock()
	}
	s.inFlight = false
	s.mu.Unlock()
}

func (s *Store) setCollecting(on bool) {
	s.mu.Lock()
	s.collecting = on
	s.mu.Unlock()
}

func (s *Store) runFull(ctx context.Context) error {
	s.setCollecting(true)
	defer s.setCollecting(false)
	s.mu.Lock()
	hook := s.beforeFull
	s.mu.Unlock()
	if hook != nil {
		hook(ctx)
	}
	clock := time.Now() // one clock, captured before scanning
	dayKey := usage.DayKey(clock)
	// Serial scans: concurrent ones triple CPU and IO
	var periods [3]usage.Period
	for i, sc := range []tokscale.Scan{tokscale.Today, tokscale.Month, tokscale.AllTime} {
		rep, err := s.sc.Scan(ctx, sc)
		if err != nil {
			return err
		}
		periods[i] = rep.Aggregate()
	}
	a := Anchor{DayKey: dayKey, Fingerprint: s.fingerprint, Today: periods[0], Month: periods[1], AllTime: periods[2], CollectedAt: clock}

	s.mu.Lock()
	s.anchor = &a
	s.snapshot = &usage.Snapshot{Today: a.Today, Month: a.Month, AllTime: a.AllTime, CollectedAt: clock, DayKey: dayKey}
	tl, hh := s.recordLocked(a.Today.TotalTokens, clock)
	s.mu.Unlock()

	_ = SaveAnchor(s.paths.Anchor, a)
	s.saveTimeline(tl, hh)
	return nil
}

func (s *Store) runWatch(ctx context.Context) error {
	clock := time.Now()
	dayKey := usage.DayKey(clock)
	s.mu.Lock()
	a := s.anchor
	s.mu.Unlock()
	// No anchor, or yesterday's: upgrade to a full tick
	if a == nil || a.DayKey != dayKey {
		return s.runFull(ctx)
	}
	s.setCollecting(true)
	defer s.setCollecting(false)
	rep, err := s.sc.Scan(ctx, tokscale.Today)
	if err != nil {
		return err
	}
	fresh := rep.Aggregate()
	// The anchor stays as it is: it belongs to the last full tick; watch ticks only produce snapshots
	snap := usage.Snapshot{
		Today:       fresh,
		Month:       usage.Delta(a.Month, fresh, a.Today),
		AllTime:     usage.Delta(a.AllTime, fresh, a.Today),
		CollectedAt: clock,
		DayKey:      dayKey,
	}
	s.mu.Lock()
	s.snapshot = &snap
	tl, hh := s.recordLocked(fresh.TotalTokens, clock)
	s.mu.Unlock()
	s.saveTimeline(tl, hh)
	return nil
}

// recordLocked adds a timeline sample and refreshes today's half-hour buckets; it returns copies to save.
func (s *Store) recordLocked(tokens int64, at time.Time) (Timeline, HourlyHistory) {
	s.timeline.Record(tokens, at)
	dayKey := usage.DayKey(at)
	s.hourly.Set(dayKey, s.timeline.HalfHourBuckets(at), dayKey)
	return s.timeline.clone(), s.hourly.clone()
}

// saveTimeline writes the timeline files. Only the single drain goroutine calls it, so writes never interleave.
func (s *Store) saveTimeline(tl Timeline, hh HourlyHistory) {
	_ = saveJSON(s.paths.Timeline, tl)
	_ = saveJSON(s.paths.Hourly, hh)
}
