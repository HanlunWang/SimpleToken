package analytics

import (
	"math"
	"os"
	"reflect"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

func day(date string, tokens int64, cost float64) DaySummary {
	return DaySummary{Date: date, Tokens: tokens, Cost: cost, Messages: tokens / 100,
		ByModel: map[string]int64{"m": tokens}, CostByModel: map[string]float64{"m": cost}, ByClient: map[string]int64{"claude": tokens}}
}

func TestRangeStarts(t *testing.T) {
	cases := map[Range]string{RangeDay: "2026-09-28", RangeWeek: "2026-09-22", RangeMonth: "2026-08-30",
		RangeYTD: "2026-01-01", RangeAll: "2025-05-05"}
	for r, want := range cases {
		if got := StartDay(r, "2026-09-28", "2025-05-05"); got != want {
			t.Errorf("%s: %s, want %s", r, got, want)
		}
	}
	if got := StartDay(RangeAll, "2026-09-28", "2027-01-01"); got != "2026-09-28" {
		t.Errorf("ALL never starts after today: %s", got)
	}
}

func TestWeekReportFillsGapsAndComparesPreviousWeek(t *testing.T) {
	history := []DaySummary{day("2026-09-20", 50, 0), day("2026-09-22", 100, 0), day("2026-09-24", 300, 0), day("2026-09-28", 10, 0)}
	r := BuildReport(RangeWeek, MetricTokens, history, nil, "2026-09-28")
	if len(r.Days) != 7 { // 9/22…9/28, missing days filled with zero
		t.Fatalf("days = %d", len(r.Days))
	}
	if r.Total != 410 || r.PreviousTotal == nil || *r.PreviousTotal != 50 { // previous: 9/15…9/21
		t.Fatalf("total %v previous %v", r.Total, r.PreviousTotal)
	}
	if r.Current[len(r.Current)-1].Position != 1 {
		t.Error("last position")
	}
	var cum []float64
	for _, p := range r.Current {
		cum = append(cum, p.Cumulative)
	}
	if !reflect.DeepEqual(cum, []float64{100, 100, 400, 400, 400, 400, 410}) {
		t.Errorf("cumulative = %v", cum)
	}
	if r.Stats.ActiveDays != 3 || r.Stats.Peak == nil || r.Stats.Peak.Date != "2026-09-24" {
		t.Errorf("stats = %+v", r.Stats)
	}
	if c, ok := r.ChangePercent(); !ok || c != 720 {
		t.Errorf("change = %v %v", c, ok)
	}
}

func TestLiveTodayOverridesArchive(t *testing.T) {
	live := day("2026-09-28", 999, 0)
	r := BuildReport(RangeDay, MetricTokens, []DaySummary{day("2026-09-28", 10, 0)}, &live, "2026-09-28")
	if r.Total != 999 {
		t.Fatalf("total = %v", r.Total)
	}
}

func TestLongRangesBucketWeekly(t *testing.T) {
	r := BuildReport(RangeYear, MetricTokens, []DaySummary{day("2026-09-28", 1, 0)}, nil, "2026-09-28")
	if !r.WeeklyBuckets || len(r.Buckets) != 53 { // 365 days → 52 full weeks + 1 day
		t.Fatalf("weekly %v buckets %d", r.WeeklyBuckets, len(r.Buckets))
	}
	short := BuildReport(RangeMonth, MetricTokens, nil, nil, "2026-09-28")
	if short.WeeklyBuckets || len(short.Buckets) != 30 {
		t.Fatalf("weekly %v buckets %d", short.WeeklyBuckets, len(short.Buckets))
	}
	if short.Stats.Peak != nil {
		t.Error("no peak without usage")
	}
}

func TestStreakCountsBackFromToday(t *testing.T) {
	history := []DaySummary{day("2026-09-25", 5, 0), day("2026-09-26", 5, 0), day("2026-09-27", 5, 0), day("2026-09-28", 5, 0), day("2026-09-23", 5, 0)}
	if s := BuildReport(RangeMonth, MetricTokens, history, nil, "2026-09-28").Stats.Streak; s != 4 {
		t.Fatalf("streak = %d", s)
	}
}

func TestYTDComparesSameSpanLastYear(t *testing.T) {
	history := []DaySummary{day("2025-03-01", 40, 0), day("2025-10-01", 999, 0), day("2026-02-01", 60, 0)}
	r := BuildReport(RangeYTD, MetricTokens, history, nil, "2026-09-28")
	if r.PreviousTotal == nil || *r.PreviousTotal != 40 || r.Total != 60 { // 2025-01-01…2025-09-28, October excluded
		t.Fatalf("total %v previous %v", r.Total, r.PreviousTotal)
	}
	// Feb 29 last year clamps to Feb 28, as Calendar does
	leap := BuildReport(RangeYTD, MetricTokens, []DaySummary{day("2027-02-28", 1, 0), day("2027-03-01", 5, 0)}, nil, "2028-02-29")
	if *leap.PreviousTotal != 1 {
		t.Fatalf("leap previous = %v", *leap.PreviousTotal)
	}
}

func TestAllHasNoPreviousPeriod(t *testing.T) {
	r := BuildReport(RangeAll, MetricTokens, []DaySummary{day("2026-09-01", 5, 0)}, nil, "2026-09-28")
	if r.PreviousDays != nil || r.PreviousTotal != nil || len(r.Days) != 28 {
		t.Fatalf("previous %v days %d", r.PreviousDays, len(r.Days))
	}
	if _, ok := r.ChangePercent(); ok {
		t.Fatal("no change for ALL")
	}
}

func TestMetricsAndShares(t *testing.T) {
	d := DaySummary{Date: "2026-09-28", Tokens: 300, Cost: 3, Messages: 30,
		ByModel: map[string]int64{"a": 200, "b": 100}, CostByModel: map[string]float64{"a": 1, "b": 2},
		ByClient: map[string]int64{"claude": 250, "codex": 50}}
	cost := BuildReport(RangeDay, MetricCost, []DaySummary{d}, nil, "2026-09-28")
	if cost.Total != 3 || cost.Buckets[0].ByModel["b"] != 2 {
		t.Errorf("cost report %v %v", cost.Total, cost.Buckets[0].ByModel)
	}
	msgs := BuildReport(RangeDay, MetricMessages, []DaySummary{d}, nil, "2026-09-28")
	if msgs.Buckets[0].ByModel["a"] != 20 || msgs.Buckets[0].Total() != 30 { // split by token share
		t.Errorf("messages buckets %v", msgs.Buckets[0].ByModel)
	}
	if msgs.Models[0].Key != "a" || msgs.Models[0].Cost != 1 || msgs.Clients[0].Key != "claude" || msgs.Clients[0].Cost != 0 {
		t.Errorf("shares %v %v", msgs.Models, msgs.Clients)
	}
	if math.Abs(msgs.Stats.CostPerMillion-10000) > 1e-9 {
		t.Errorf("cost per million %v", msgs.Stats.CostPerMillion)
	}
}

func TestMonthCostProjectsToMonthEnd(t *testing.T) {
	history := []DaySummary{day("2026-08-15", 1, 70), day("2026-09-01", 1, 10), day("2026-09-02", 1, 20)}
	m := BuildMonthCost(history, nil, "2026-09-02")
	if m.Days[len(m.Days)-1].Cumulative != 30 || m.DaysInMonth != 30 {
		t.Fatalf("%+v", m)
	}
	if math.Abs(m.Projected-450) > 0.001 { // daily average 15 × 30
		t.Errorf("projected %v", m.Projected)
	}
	if m.LastMonthTotal != 70 {
		t.Errorf("last month %v", m.LastMonthTotal)
	}
	if mar := BuildMonthCost(nil, nil, "2026-03-31"); mar.DaysInMonth != 31 {
		t.Errorf("march days %d", mar.DaysInMonth)
	}
}

// ── filter ──

func period(t *testing.T) usage.Period {
	t.Helper()
	data, err := os.ReadFile("testdata/report.json")
	if err != nil {
		t.Fatal(err)
	}
	r, err := usage.DecodeReport(data)
	if err != nil {
		t.Fatal(err)
	}
	return r.Aggregate()
}

func TestFilterExcludesClientsAndModelsExactly(t *testing.T) {
	p := period(t)
	if p.TotalTokens != 240 {
		t.Fatalf("total = %d", p.TotalTokens)
	}
	noCodex := NewFilter(nil, []string{"codex"}).Apply(p)
	if _, ok := noCodex.ByModel["gpt-5.3-codex"]; noCodex.TotalTokens != 140 || ok || noCodex.CacheReadTokens != 100 ||
		math.Abs(noCodex.CostUSD-2) > 1e-9 {
		t.Errorf("no codex = %+v", noCodex)
	}
	noFable := NewFilter([]string{"claude-fable-5"}, nil).Apply(p)
	if noFable.TotalTokens != 235 || noFable.ByClient["claude"].Tokens != 135 || noFable.Messages != 5 {
		t.Errorf("no fable = %+v", noFable)
	}
}

func TestEmptyFilterIsIdentity(t *testing.T) {
	p := period(t)
	if !reflect.DeepEqual(Filter{}.Apply(p), p) || !NewFilter(nil, nil).IsEmpty() {
		t.Fatal("not identity")
	}
	if !NewFilter([]string{"a"}, nil).Equal(Filter{ExcludedModels: map[string]bool{"a": true, "b": false}}) {
		t.Fatal("equal ignores false entries")
	}
}

func TestFilterApproximatesWithoutPairs(t *testing.T) {
	p := period(t)
	p.ByPair = nil
	out := NewFilter(nil, []string{"codex"}).Apply(p)
	if out.TotalTokens != 140 || out.ByClient["codex"].Tokens != 0 {
		t.Errorf("approximate = %+v", out)
	}
	if _, ok := p.ByClient["codex"]; !ok {
		t.Error("input modified")
	}
}

func TestSummariesHonourFilter(t *testing.T) {
	days := []Day{
		{Date: "2026-09-28", Rows: []Row{
			{Client: "claude", Model: "opus", Tokens: 100, Cost: 1, Messages: 1},
			{Client: "codex", Model: "gpt", Tokens: 50, Cost: 2, Messages: 1},
		}},
		{Date: "2026-09-27", ActiveTimeMs: 5, Rows: []Row{{Client: "Claude Code", Model: "opus", Tokens: 7}}},
		{Date: "2026-09-29", Rows: []Row{{Client: "claude", Model: "opus", Tokens: 1}}}, // future: dropped
	}
	all := Summaries(days, "2026-09-28", Filter{}, 0)
	if len(all) != 2 || all[0].Date != "2026-09-27" || all[1].Tokens != 150 || all[0].ByClient["claude"] != 7 || all[0].ActiveTimeMs != 5 {
		t.Fatalf("all = %+v", all)
	}
	filtered := Summaries(days, "2026-09-28", NewFilter(nil, []string{"codex"}), 0)
	if _, ok := filtered[1].ByModel["gpt"]; filtered[1].Tokens != 100 || ok {
		t.Errorf("filtered = %+v", filtered[1])
	}
	if capped := Summaries(days, "2026-09-28", Filter{}, 1); len(capped) != 1 || capped[0].Date != "2026-09-28" {
		t.Errorf("capped = %+v", capped)
	}
	// A filtered live day agrees with the archive
	live := LiveDay(NewFilter(nil, []string{"codex"}).Apply(period(t)), "2026-09-28")
	if live.Tokens != 140 || live.ByModel["claude-opus-5-5"] != 135 || live.CostByModel["claude-fable-5"] != 0.5 {
		t.Errorf("live = %+v", live)
	}
}

// ── treemap ──

func TestTreemapAreasAndBounds(t *testing.T) {
	values := []float64{6, 6, 4, 3, 2, 2, 1, 0, -1}
	rect := Rect{X: 10, Y: 20, W: 600, H: 400}
	tiles := Treemap(values, rect)
	total := 24.0
	for i, v := range values {
		r := tiles[i]
		want := max(0, v) / total * rect.W * rect.H
		if math.Abs(r.W*r.H-want) > 1e-6 {
			t.Errorf("tile %d area %v, want %v", i, r.W*r.H, want)
		}
		if v > 0 && (r.X < rect.X-1e-9 || r.Y < rect.Y-1e-9 || r.X+r.W > rect.X+rect.W+1e-6 || r.Y+r.H > rect.Y+rect.H+1e-6) {
			t.Errorf("tile %d out of bounds: %+v", i, r)
		}
	}
	// The first row of the classic example (Bruls et al.) splits 6, 6 along the short side
	if tiles[0].W != tiles[1].W || tiles[0].X != rect.X || tiles[1].Y != tiles[0].Y+tiles[0].H {
		t.Errorf("first row: %+v %+v", tiles[0], tiles[1])
	}
	if got := Treemap([]float64{1}, Rect{W: 0, H: 10}); got[0] != (Rect{}) {
		t.Error("empty rect")
	}
}
