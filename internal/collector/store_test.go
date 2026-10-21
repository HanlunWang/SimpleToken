package collector

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/tokscale"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

type fakeScanner struct {
	mu      sync.Mutex
	calls   []tokscale.Scan
	tokens  map[tokscale.Scan]int64
	fail    error
	block   chan struct{} // when set, scans wait for it or for ctx
	active  atomic.Int32
	overlap atomic.Bool
	graphs  atomic.Int32
}

func newFake() *fakeScanner {
	return &fakeScanner{tokens: map[tokscale.Scan]int64{tokscale.Today: 10, tokscale.Month: 100, tokscale.AllTime: 1000}}
}

func (f *fakeScanner) Fingerprint() string { return "claude|2024-01-01" }

func (f *fakeScanner) Scan(ctx context.Context, s tokscale.Scan) (usage.Report, error) {
	if f.active.Add(1) > 1 {
		f.overlap.Store(true)
	}
	defer f.active.Add(-1)
	f.mu.Lock()
	f.calls = append(f.calls, s)
	n, fail, block := f.tokens[s], f.fail, f.block
	f.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return usage.Report{}, ctx.Err()
		}
	}
	if fail != nil {
		return usage.Report{}, fail
	}
	data := fmt.Sprintf(`{"entries":[{"client":"claude","model":"m","input":%d,"messageCount":1,"cost":%d}]}`, n, n)
	return usage.DecodeReport([]byte(data))
}

func (f *fakeScanner) Graph(context.Context) (usage.Graph, error) {
	f.graphs.Add(1)
	return usage.Graph{}, nil
}

func (f *fakeScanner) set(s tokscale.Scan, n int64) {
	f.mu.Lock()
	f.tokens[s] = n
	f.mu.Unlock()
}

func (f *fakeScanner) callList() []tokscale.Scan {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.calls)
}

func testPaths(t *testing.T) Paths {
	d := t.TempDir()
	return Paths{
		Anchor:   filepath.Join(d, "collector-anchor.json"),
		Timeline: filepath.Join(d, "today-timeline.json"),
		Hourly:   filepath.Join(d, "hourly-history.json"),
		Archive:  filepath.Join(d, "daily-history-archive.json"),
	}
}

// changes counts OnChange calls and lets a test wait for the next one.
type changes struct{ ch chan struct{} }

func watch(s *Store) *changes {
	c := &changes{ch: make(chan struct{}, 64)}
	s.SetOnChange(func() { c.ch <- struct{}{} })
	return c
}

// waitFor waits until cond holds, re-checking after every change.
func (c *changes) waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for !cond() {
		select {
		case <-c.ch:
		case <-time.After(20 * time.Millisecond):
		case <-deadline:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func todayTokens(s *Store) int64 {
	snap, ok := s.Snapshot()
	if !ok {
		return -1
	}
	return snap.Today.TotalTokens
}

func TestFullTickScansSeriallyAndAnchors(t *testing.T) {
	f := newFake()
	p := testPaths(t)
	s := New(f, p)
	if _, ok := s.Snapshot(); ok {
		t.Fatal("snapshot before any scan")
	}
	var hooked atomic.Int32
	s.SetBeforeFullScan(func(context.Context) { hooked.Add(1) })
	c := watch(s)
	s.Start(context.Background())
	defer s.Stop()
	c.waitFor(t, "first snapshot", func() bool { return todayTokens(s) == 10 })

	if got := f.callList()[:3]; !slices.Equal(got, []tokscale.Scan{tokscale.Today, tokscale.Month, tokscale.AllTime}) {
		t.Errorf("scan order %v", got)
	}
	snap, _ := s.Snapshot()
	if snap.Month.TotalTokens != 100 || snap.AllTime.TotalTokens != 1000 || snap.DayKey != usage.DayKey(time.Now()) {
		t.Errorf("snapshot %+v", snap)
	}
	if hooked.Load() != 1 {
		t.Errorf("before-full hook ran %d times", hooked.Load())
	}
	// Files are written right after the snapshot is published
	c.waitFor(t, "saved files", func() bool {
		_, err := os.Stat(p.Hourly)
		_, ok := LoadAnchor(p.Anchor, f.Fingerprint())
		return ok && err == nil
	})
	a, ok := LoadAnchor(p.Anchor, f.Fingerprint())
	if !ok || a.Month.TotalTokens != 100 {
		t.Fatalf("anchor %+v %v", a, ok)
	}
	if tl := s.Timeline(); len(tl.Samples) != 1 || tl.Samples[0].TotalTokens != 10 {
		t.Errorf("timeline %+v", tl)
	}
	if f.overlap.Load() {
		t.Error("scans overlapped")
	}
}

func TestWarmStartFromAnchor(t *testing.T) {
	f := newFake()
	p := testPaths(t)
	today := usage.NewPeriod()
	today.TotalTokens = 42
	a := Anchor{DayKey: usage.DayKey(time.Now()), Fingerprint: f.Fingerprint(), Today: today, Month: today, AllTime: today, CollectedAt: time.Now()}
	if err := SaveAnchor(p.Anchor, a); err != nil {
		t.Fatal(err)
	}
	if got := todayTokens(New(f, p)); got != 42 {
		t.Errorf("warm start today %d", got)
	}
	// Another configuration or another day: no warm start
	a.Fingerprint = "other"
	_ = SaveAnchor(p.Anchor, a)
	if _, ok := New(f, p).Snapshot(); ok {
		t.Error("anchor of another configuration used")
	}
	a.Fingerprint, a.DayKey = f.Fingerprint(), "2000-01-01"
	_ = SaveAnchor(p.Anchor, a)
	if _, ok := New(f, p).Snapshot(); ok {
		t.Error("yesterday's anchor used")
	}
}

func TestAnchorReadsSwiftFile(t *testing.T) {
	p := testPaths(t)
	// Shape the Swift releases wrote: sorted keys, whole-second ISO 8601, an old slice lacking fields, no byPair
	data := `{"allTime":{"byClient":{"claude":{"costUsd":2,"tokens":20}},"byModel":{},"cacheReadTokens":0,"cacheWriteTokens":0,
		"costUsd":2,"inputTokens":20,"messages":1,"outputTokens":0,"totalTokens":20},
		"collectedAt":"2026-10-21T19:26:42Z","dayKey":"2026-10-21","fingerprint":"f",
		"month":{"totalTokens":5},"today":{"totalTokens":1}}`
	if err := os.WriteFile(p.Anchor, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	a, ok := LoadAnchor(p.Anchor, "f")
	if !ok || a.AllTime.ByClient["claude"].Tokens != 20 || a.Month.TotalTokens != 5 || a.Today.ByPair == nil {
		t.Fatalf("anchor %+v %v", a, ok)
	}
	if !a.CollectedAt.Equal(time.Date(2026, 10, 21, 19, 26, 42, 0, time.UTC)) {
		t.Errorf("collectedAt %v", a.CollectedAt)
	}
	a.CollectedAt = time.Date(2026, 10, 21, 19, 26, 42, 123456789, time.FixedZone("x", 3600))
	if err := SaveAnchor(p.Anchor, a); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(p.Anchor)
	if !strings.Contains(string(raw), `"collectedAt":"2026-10-21T18:26:42Z"`) {
		t.Errorf("collectedAt not whole-second UTC: %s", raw)
	}
}

func TestWatchTickDerivesWideWindows(t *testing.T) {
	f := newFake()
	s := New(f, testPaths(t))
	s.minWait = time.Millisecond
	s.SetLiveInterval(time.Millisecond)
	c := watch(s)
	s.Start(context.Background())
	defer s.Stop()
	c.waitFor(t, "full tick", func() bool { return todayTokens(s) == 10 })

	f.set(tokscale.Today, 25) // 15 new tokens today
	s.Poke()
	c.waitFor(t, "watch tick", func() bool { return todayTokens(s) == 25 })
	snap, _ := s.Snapshot()
	if snap.Month.TotalTokens != 115 || snap.AllTime.TotalTokens != 1015 {
		t.Errorf("month %d all %d", snap.Month.TotalTokens, snap.AllTime.TotalTokens)
	}
	if got := f.callList()[3:]; !slices.Equal(got, []tokscale.Scan{tokscale.Today}) {
		t.Errorf("watch tick ran %v", got)
	}
	if len(s.Timeline().Samples) != 2 {
		t.Errorf("timeline %+v", s.Timeline())
	}
}

func TestWatchTicksAreThrottled(t *testing.T) {
	f := newFake()
	s := New(f, testPaths(t))
	s.minWait = time.Millisecond
	s.SetLiveInterval(300 * time.Millisecond)
	c := watch(s)
	s.Start(context.Background())
	defer s.Stop()
	c.waitFor(t, "full tick", func() bool { return len(f.callList()) == 3 && todayTokens(s) == 10 })
	start := time.Now()
	for range 50 {
		s.Poke()
	}
	c.waitFor(t, "watch tick", func() bool { return len(f.callList()) == 4 })
	if el := time.Since(start); el < 200*time.Millisecond {
		t.Errorf("watch tick after %v, throttle not honoured", el)
	}
	time.Sleep(100 * time.Millisecond)
	if n := len(f.callList()); n != 4 {
		t.Errorf("%d scans for one burst of pokes", n)
	}
}

func TestPausedStoreCatchesUpOnResume(t *testing.T) {
	f := newFake()
	s := New(f, testPaths(t))
	s.minWait = time.Millisecond
	s.SetLiveInterval(time.Millisecond)
	c := watch(s)
	s.SetLive(false)
	s.Start(context.Background())
	defer s.Stop()
	c.waitFor(t, "full tick", func() bool { return todayTokens(s) == 10 })
	f.set(tokscale.Today, 11)
	s.Poke()
	time.Sleep(50 * time.Millisecond)
	if n := len(f.callList()); n != 3 {
		t.Fatalf("paused store scanned: %d", n)
	}
	s.SetLive(true)
	c.waitFor(t, "catch-up tick", func() bool { return todayTokens(s) == 11 })
}

func TestManualRefreshAndErrors(t *testing.T) {
	f := newFake()
	s := New(f, testPaths(t))
	c := watch(s)
	s.RequestFull() // before Start: ignored
	s.Start(context.Background())
	defer s.Stop()
	c.waitFor(t, "full tick", func() bool { return todayTokens(s) == 10 })
	f.mu.Lock()
	f.fail = errors.New("boom")
	f.mu.Unlock()
	s.RequestFull()
	c.waitFor(t, "error", func() bool { return s.LastError() != nil })
	if todayTokens(s) != 10 {
		t.Error("failed tick replaced the snapshot")
	}
	f.mu.Lock()
	f.fail = nil
	f.mu.Unlock()
	f.set(tokscale.Today, 12)
	s.RequestFull()
	c.waitFor(t, "recovery", func() bool { return s.LastError() == nil && todayTokens(s) == 12 })
}

func TestStopCancelsRunningScan(t *testing.T) {
	f := newFake()
	f.block = make(chan struct{})
	s := New(f, testPaths(t))
	s.Start(context.Background())
	deadline := time.Now().Add(5 * time.Second)
	for !s.IsCollecting() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	done := make(chan struct{})
	go func() { s.Stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop did not return")
	}
	if s.LastError() != nil {
		t.Errorf("cancellation reported as error: %v", s.LastError())
	}
	s.Stop() // idempotent
}

func TestConcurrentUse(t *testing.T) {
	f := newFake()
	s := New(f, testPaths(t))
	s.minWait = time.Millisecond
	s.SetLiveInterval(time.Millisecond)
	s.SetOnChange(func() { _, _ = s.Snapshot() })
	s.Start(context.Background())
	var wg sync.WaitGroup
	for i := range 8 {
		wg.Go(func() {
			for j := range 20 {
				switch (i + j) % 6 {
				case 0:
					s.Poke()
				case 1:
					s.RequestFull()
				case 2:
					s.SetLive(j%2 == 0)
				case 3:
					_ = s.Timeline()
					_ = s.Hourly()
				case 4:
					_ = s.History().Daily()
				case 5:
					_, _ = s.Snapshot()
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
	wg.Wait()
	s.Stop()
	if f.overlap.Load() {
		t.Error("scans overlapped")
	}
}

func TestTimelineBuckets(t *testing.T) {
	loc := time.Local
	day := time.Date(2026, 10, 21, 0, 0, 0, 0, loc)
	at := func(h, m int) time.Time { return day.Add(time.Duration(h)*time.Hour + time.Duration(m)*time.Minute) }
	var tl Timeline
	tl.Record(100, at(9, 10))
	tl.Record(150, at(9, 40))
	tl.Record(120, at(10, 5)) // logs cleaned up: no negative bucket
	tl.Record(200, at(10, 50))
	half := tl.HalfHourBuckets(at(11, 0))
	if half[18] != 100 || half[19] != 50 || half[20] != 0 || half[21] != 50 {
		t.Errorf("half-hour buckets %v", half[18:22])
	}
	hourly := tl.HourlyBuckets(at(11, 0))
	if hourly[9] != 150 || hourly[10] != 50 {
		t.Errorf("hourly %v", hourly[9:11])
	}
	if got := tl.HalfHourBuckets(at(11, 0).AddDate(0, 0, 1)); slices.Max(got) != 0 {
		t.Error("stale timeline produced buckets")
	}
	tl.Record(5, at(9, 0).AddDate(0, 0, 1))
	if len(tl.Samples) != 1 || tl.DayKey != "2026-10-22" {
		t.Errorf("new day did not reset: %+v", tl)
	}

	var h HourlyHistory
	for i := range 20 {
		d := day.AddDate(0, 0, -i)
		h.Set(usage.DayKey(d), half, usage.DayKey(day))
	}
	if len(h.Days) != hourlyKeepDays {
		t.Errorf("kept %d days", len(h.Days))
	}
	if got := h.HourTotals("2026-10-21"); got[9] != 150 || got[10] != 50 {
		t.Errorf("hour totals %v", got)
	}
	roll := h.RollingHourly(26, at(10, 15))
	if len(roll) != 26 || roll[25] != 50 || roll[24] != 150 || roll[0] != 150 {
		t.Errorf("rolling %v", roll)
	}
}
