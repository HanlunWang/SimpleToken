package limits

import (
	"context"
	"errors"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// newTestStore has no real probes: Claude goes to the given fake server, Codex and Cursor to the funcs.
func newTestStore(t *testing.T, claudeURL string) (*Store, *CredentialStore) {
	t.Helper()
	dir := t.TempDir()
	creds := &CredentialStore{Path: filepath.Join(dir, "credentials.json"), LegacyPath: filepath.Join(dir, "none.json")}
	s := NewStore(creds)
	s.claudeBaseURL = claudeURL
	s.planLabelLoader = func(context.Context) string { return "Max 20x" }
	notConfigured := func(context.Context) (Snapshot, error) { return Snapshot{}, ErrNotConfigured }
	s.probes[Codex] = notConfigured
	s.probes[Cursor] = notConfigured
	return s, creds
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestStoreClaudeFlowWritesRotatedKey(t *testing.T) {
	fake := &fakeClaude{rotate: "sk-ant-rotated"}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()
	s, creds := newTestStore(t, srv.URL)
	var changes atomic.Int64
	s.OnChange = func() { changes.Add(1) }

	// Not configured without a cookie.
	s.Start()
	waitFor(t, "not configured", func() bool { return s.Get(Claude).Status.State == StateNotConfigured })
	if e := s.Get(Codex); e.Status.State != StateNotConfigured {
		t.Fatalf("codex: %+v", e.Status)
	}

	if err := creds.SetClaudeCookie("sk-ant-original"); err != nil {
		t.Fatal(err)
	}
	s.RefreshNow()
	waitFor(t, "ok", func() bool { return s.Get(Claude).Status.State == StateOK })
	e := s.Get(Claude)
	if e.Snapshot == nil || len(e.Snapshot.Windows) != 3 || e.Snapshot.AccountLabel != "Max 20x" || e.Status.UpdatedAt.IsZero() {
		t.Fatalf("entry: %+v", e)
	}
	if got := creds.ClaudeCookie(); got != "sk-ant-rotated" {
		t.Fatalf("rotated key not written back: %q", got)
	}
	if s.claudeOrgIDForTest() != "org-1" {
		t.Fatal("organisation not cached")
	}

	// A failure keeps the snapshot, reports the reason and clears the organisation cache.
	fake.mu.Lock()
	fake.usageCode = 401
	fake.mu.Unlock()
	s.RefreshNow()
	waitFor(t, "failed", func() bool { return s.Get(Claude).Status.State == StateFailed })
	e = s.Get(Claude)
	if e.Snapshot == nil || e.Status.Reason != ErrUnauthorized.Error() {
		t.Fatalf("after failure: %+v", e)
	}
	s.Stop()
	if s.claudeOrgIDForTest() != "" {
		t.Fatal("organisation cache kept after a failure")
	}
	if changes.Load() == 0 {
		t.Fatal("OnChange never called")
	}
	if s.Busy() {
		t.Fatal("busy after stop")
	}
}

func (s *Store) claudeOrgIDForTest() string {
	ps := s.providers[Claude]
	ps.probing.Lock()
	defer ps.probing.Unlock()
	return s.claudeOrgID
}

func TestStoreConcurrentAccessAndHidden(t *testing.T) {
	s, _ := newTestStore(t, "http://127.0.0.1:1") // Claude stays not configured: no cookie
	var calls atomic.Int64
	s.probes[Cursor] = func(ctx context.Context) (Snapshot, error) {
		calls.Add(1)
		return Snapshot{Provider: Cursor, Windows: []Window{NewWindow(Weekly, 40, nil, 0, "")}}, nil
	}
	s.probes[Codex] = func(ctx context.Context) (Snapshot, error) { return Snapshot{}, errors.New("boom") }
	s.OnChange = func() { _ = s.Entries(); _ = s.Busy() } // reading from the callback must not deadlock
	s.Start()
	defer s.Stop()
	for range 20 {
		s.RefreshNow()
		_ = s.Snapshots()
		s.SetHidden(Cursor, true)
		s.SetHiddenProviders(nil)
	}
	waitFor(t, "cursor ok and codex failed", func() bool {
		return s.Get(Cursor).Status.State == StateOK && s.Get(Codex).Status.State == StateFailed
	})
	if s.Get(Codex).Status.Reason != "boom" {
		t.Fatalf("codex reason: %+v", s.Get(Codex).Status)
	}
	s.SetHidden(Codex, true)
	if !s.Get(Codex).Hidden || !s.Hidden()[Codex] || s.Get(Cursor).Hidden {
		t.Fatal("hidden flags")
	}
	// Returned snapshots are copies.
	e := s.Get(Cursor)
	e.Snapshot.Windows[0].UsedPercent = 99
	if s.Get(Cursor).Snapshot.Windows[0].UsedPercent != 40 {
		t.Fatal("snapshot aliasing")
	}
}

func TestStoreLoadDemo(t *testing.T) {
	s, _ := newTestStore(t, "")
	now := time.Now()
	s.LoadDemo(Snapshot{Provider: Codex, Windows: []Window{NewWindow(Weekly, 10, nil, 0, "")}, UpdatedAt: now})
	if e := s.Get(Codex); e.Status.State != StateOK || e.Snapshot == nil {
		t.Fatalf("demo: %+v", e)
	}
	if len(s.Snapshots()) != 1 {
		t.Fatal("demo snapshots")
	}
}

func TestScheduling(t *testing.T) {
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	snap := func(resets ...time.Duration) Snapshot {
		var ws []Window
		for _, r := range resets {
			ws = append(ws, NewWindow(Session, 1, ptr(now.Add(r)), 0, ""))
		}
		return Snapshot{Windows: ws}
	}
	if d := nextRegularDelay(snap(), now); d != 5*time.Minute {
		t.Fatalf("no resets: %v", d)
	}
	if d := nextRegularDelay(snap(time.Hour, 2*time.Minute), now); d != 2*time.Minute+30*time.Second {
		t.Fatalf("reset soon: %v", d)
	}
	if d := nextRegularDelay(snap(-time.Minute), now); d != 5*time.Minute {
		t.Fatalf("past reset: %v", d)
	}
	if d := nextRegularDelay(snap(time.Second), now); d != 31*time.Second {
		t.Fatalf("imminent reset: %v", d)
	}
	for n, base := range map[int]time.Duration{1: 5 * time.Second, 2: 10 * time.Second, 4: 40 * time.Second, 7: 5 * time.Minute, 100: 5 * time.Minute} {
		for range 20 {
			if d := backoffDelay(n); d < base/2 || d > base {
				t.Fatalf("backoff(%d) = %v, want %v…%v", n, d, base/2, base)
			}
		}
	}
}
