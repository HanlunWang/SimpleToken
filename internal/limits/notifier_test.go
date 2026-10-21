package limits

import (
	"path/filepath"
	"testing"
	"time"
)

func TestNotifierDedupe(t *testing.T) {
	path := filepath.Join(t.TempDir(), "limit-notified.json")
	reset := time.Date(2026, 10, 21, 15, 0, 0, 0, time.UTC)
	snap := func(used float64, at time.Time) Snapshot {
		return Snapshot{Provider: Claude, Windows: []Window{
			NewWindow(Session, used, ptr(at), 0, ""),
			NewWindow(Model, 99, nil, 0, "extra"), // titled extras never alert
		}}
	}
	thresholds := []float64{80, 50}
	n := NewNotifier(path)

	if got := n.Check([]Snapshot{snap(40, reset)}, thresholds, nil); len(got) != 0 {
		t.Fatalf("below thresholds: %+v", got)
	}
	got := n.Check([]Snapshot{snap(55, reset)}, thresholds, nil)
	if len(got) != 1 || got[0].Threshold != 50 || got[0].Provider != Claude || got[0].Window.Kind != Session {
		t.Fatalf("first crossing: %+v", got)
	}
	if got := n.Check([]Snapshot{snap(60, reset)}, thresholds, nil); len(got) != 0 {
		t.Fatalf("same threshold, same period: %+v", got)
	}
	// Probe jitter within the hour is the same period.
	if got := n.Check([]Snapshot{snap(60, reset.Add(20*time.Second))}, thresholds, nil); len(got) != 0 {
		t.Fatalf("jittered reset: %+v", got)
	}
	if got := n.Check([]Snapshot{snap(85, reset)}, thresholds, nil); len(got) != 1 || got[0].Threshold != 80 {
		t.Fatalf("higher threshold: %+v", got)
	}

	// A relaunch (a new notifier on the same file) does not repeat it.
	n2 := NewNotifier(path)
	if got := n2.Check([]Snapshot{snap(90, reset)}, thresholds, nil); len(got) != 0 {
		t.Fatalf("after relaunch: %+v", got)
	}
	// The next period fires again, highest threshold only.
	next := reset.Add(5 * time.Hour)
	got = n2.Check([]Snapshot{snap(90, next)}, thresholds, nil)
	if len(got) != 1 || got[0].Threshold != 80 {
		t.Fatalf("next period: %+v", got)
	}
	// …and the lower threshold of that period was recorded with it.
	if got := n2.Check([]Snapshot{snap(55, next)}, thresholds, nil); len(got) != 0 {
		t.Fatalf("lower threshold after higher: %+v", got)
	}

	// Hidden providers are skipped; no thresholds means nothing.
	codex := Snapshot{Provider: Codex, Windows: []Window{NewWindow(Weekly, 95, ptr(reset), 0, "")}}
	if got := n2.Check([]Snapshot{codex}, thresholds, map[Provider]bool{Codex: true}); len(got) != 0 {
		t.Fatalf("hidden: %+v", got)
	}
	if got := n2.Check([]Snapshot{codex}, nil, nil); len(got) != 0 {
		t.Fatalf("no thresholds: %+v", got)
	}
	if got := n2.Check([]Snapshot{codex}, thresholds, nil); len(got) != 1 || got[0].Provider != Codex {
		t.Fatalf("codex visible: %+v", got)
	}
}

func TestNotifierBoundsRecord(t *testing.T) {
	n := NewNotifier("")
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := range 150 {
		s := Snapshot{Provider: Claude, Windows: []Window{NewWindow(Session, 100, ptr(base.Add(time.Duration(i)*5*time.Hour)), 0, "")}}
		n.Check([]Snapshot{s}, []float64{50, 80}, nil)
	}
	if len(n.order) != maxNotifiedRecords || len(n.notified) != maxNotifiedRecords {
		t.Fatalf("record size %d / %d", len(n.order), len(n.notified))
	}
	// The newest period is still known.
	last := Snapshot{Provider: Claude, Windows: []Window{NewWindow(Session, 100, ptr(base.Add(149*5*time.Hour)), 0, "")}}
	if got := n.Check([]Snapshot{last}, []float64{50, 80}, nil); len(got) != 0 {
		t.Fatalf("newest period repeated: %+v", got)
	}
}
