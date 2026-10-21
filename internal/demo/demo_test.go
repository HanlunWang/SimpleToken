package demo

import (
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
)

func TestRNGMatchesSwift(t *testing.T) {
	// First values of the Swift DemoData generator seeded with 42
	r := rng{42}
	for _, want := range []float64{0.5682303266439076, 0.2254634289477513, 0.41283831882951183} {
		if got := r.next(); got != want {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

var today = time.Date(2026, 10, 21, 15, 40, 0, 0, time.Local)

func TestArchiveIsDeterministic(t *testing.T) {
	a, b := Archive(today), Archive(today)
	if !reflect.DeepEqual(a, b) {
		t.Fatal("not deterministic")
	}
	last := a[len(a)-1]
	if last.Date != format.DayKey(today) || len(last.Observations) != len(mix) {
		t.Fatalf("last day %+v", last)
	}
	var total int64
	for _, o := range last.Observations {
		total += o.Tokens
		if o.Messages < 1 || o.Cost <= 0 {
			t.Errorf("observation %+v", o)
		}
	}
	if total < 60e6 || total > 140e6 { // 96 M × shares × 0.7…1.3
		t.Errorf("today total %d", total)
	}
	if len(a) < 150 || len(a) > 240 || a[0].Date >= a[1].Date {
		t.Errorf("%d days", len(a))
	}
}

func TestSnapshotAgreesWithArchive(t *testing.T) {
	archive := Archive(today)
	snap := Snapshot(archive, today)
	days := analytics.Summaries(AnalyticsDays(archive), snap.DayKey, analytics.Filter{}, 0)
	var all int64
	for _, d := range days {
		all += d.Tokens
	}
	if snap.AllTime.TotalTokens != all || snap.Today.TotalTokens != days[len(days)-1].Tokens {
		t.Fatalf("all %d vs %d", snap.AllTime.TotalTokens, all)
	}
	p := snap.Today
	if p.InputTokens+p.OutputTokens+p.CacheReadTokens+p.CacheWriteTokens != p.TotalTokens {
		t.Error("composition does not add up")
	}
	if snap.Month.TotalTokens < snap.Today.TotalTokens || snap.AllTime.TotalTokens < snap.Month.TotalTokens {
		t.Error("periods not nested")
	}
	if len(p.ByPair) != len(mix) || p.ByClient["claude"].Tokens == 0 {
		t.Errorf("slices %v", p.ByClient)
	}
}

func TestIntradayCoversClaudeOnly(t *testing.T) {
	archive := Archive(today)
	snap := Intraday(archive, today)
	if len(snap.ByModel) != min(90, len(archive)) {
		t.Fatalf("%d days", len(snap.ByModel))
	}
	todayKey := format.DayKey(today)
	models := snap.ModelBuckets(todayKey, nil)
	if len(models) != 3 {
		t.Fatalf("models %v", len(models))
	}
	nowSlot := today.Hour()*2 + 1 // 15:40
	var claude int64
	for _, o := range archive[len(archive)-1].Observations {
		if o.Client == "claude" {
			claude += o.Tokens
		}
	}
	got := int64(0)
	for _, b := range models {
		for i, v := range b {
			if i > nowSlot && v != 0 {
				t.Fatalf("bucket %d after now", i)
			}
			got += v
		}
	}
	if math.Abs(float64(got-claude)) > 48*3 { // integer truncation only
		t.Errorf("intraday %d vs claude %d", got, claude)
	}
}

func TestLimits(t *testing.T) {
	claude, codex, cursor := Limits(today)
	if claude.Provider != limits.Claude || len(claude.Windows) != 3 || claude.AccountLabel != "Max 20x" {
		t.Errorf("claude %+v", claude)
	}
	if w, _ := claude.Primary(); w.Kind != limits.Session || w.UsedPercent != 38 || w.Span() != 5*time.Hour {
		t.Errorf("claude primary %+v", w)
	}
	if codex.AccountLabel != "Pro" || cursor.Windows[0].UsedPercent != 44 || !cursor.UpdatedAt.Equal(today.Add(-40*time.Second)) {
		t.Error("codex / cursor")
	}
}
