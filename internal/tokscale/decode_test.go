package tokscale

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestDecodesRealTodayOutput(t *testing.T) {
	report, err := usage.DecodeReport(fixture(t, "tokscale-today"))
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Entries) == 0 {
		t.Fatal("no entries")
	}
	period := report.Aggregate()
	// totalTokens = input + output + cacheRead + cacheWrite (without reasoning)
	var manual int64
	for _, e := range report.Entries {
		manual += e.Input + e.Output + e.CacheRead + e.CacheWrite
	}
	if period.TotalTokens != manual {
		t.Errorf("total %d, want %d", period.TotalTokens, manual)
	}
	// Client folding: every claude* row becomes claude
	if _, ok := period.ByClient["claude"]; !ok {
		t.Errorf("no claude client in %v", period.ByClient)
	}
	// Cost comes from tokscale itself, not an estimate of ours
	if period.CostUSD <= 0 {
		t.Errorf("cost %v", period.CostUSD)
	}
	if len(period.ByModel) == 0 {
		t.Error("no models")
	}
}

func TestReasoningIsExcludedFromTotals(t *testing.T) {
	r, err := usage.DecodeReport([]byte(`{"entries":[{"client":"claude","model":"m","input":10,"output":5,"cacheRead":100,"cacheWrite":0,"reasoning":2,"messageCount":1,"cost":0.5}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := r.Aggregate().TotalTokens; got != 115 { // 10+5+100; reasoning's 2 is not added
		t.Errorf("total %d, want 115", got)
	}
}

func TestEmptyEntriesFallsBackToTopLevelTotals(t *testing.T) {
	r, err := usage.DecodeReport([]byte(`{"entries":[],"totalInput":7,"totalOutput":3,"totalCacheRead":90,"totalCacheWrite":0,"totalMessages":2,"totalCost":1.25}`))
	if err != nil {
		t.Fatal(err)
	}
	p := r.Aggregate()
	if p.TotalTokens != 100 || p.Messages != 2 || len(p.ByModel) != 0 {
		t.Errorf("got total %d messages %d models %v", p.TotalTokens, p.Messages, p.ByModel)
	}
}

func TestDecodesRealGraphOutput(t *testing.T) {
	g, err := usage.DecodeGraph(fixture(t, "tokscale-graph"))
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Contributions) == 0 {
		t.Fatal("no days")
	}
	last := g.Contributions[len(g.Contributions)-1]
	if len(last.Date) != 10 {
		t.Errorf("date %q", last.Date)
	}
	if last.Totals.Tokens <= 0 {
		t.Errorf("day tokens %d", last.Totals.Tokens)
	}
	// clients[].tokens is a breakdown object; the folded value must be positive
	if len(last.Clients) == 0 || last.Clients[0].CollapsedTokens() <= 0 {
		t.Errorf("clients %+v", last.Clients)
	}
}

func TestExtractJSONSkipsGarbagePrefix(t *testing.T) {
	r, err := usage.DecodeReport(ExtractJSON([]byte("warning: blah\n{\"totalCost\": 1}")))
	if err != nil {
		t.Fatal(err)
	}
	if r.TotalCost != 1 {
		t.Errorf("cost %v", r.TotalCost)
	}
	if got := string(ExtractJSON([]byte(`{"a":1}`))); got != `{"a":1}` {
		t.Errorf("clean input changed: %q", got)
	}
}
