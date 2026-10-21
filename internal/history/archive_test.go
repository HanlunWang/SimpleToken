package history

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

type row struct {
	tokens   int64
	cost     float64
	messages int64
}

func graphDay(t *testing.T, date string, activeMs *float64, rows ...row) usage.Graph {
	t.Helper()
	var clients []string
	for _, r := range rows {
		clients = append(clients, fmt.Sprintf(`{"client":"claude","modelId":"m","providerId":"anthropic",
			"tokens":{"input":%d,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"cost":%v,"messages":%d}`,
			r.tokens, r.cost, r.messages))
	}
	active := ""
	if activeMs != nil {
		active = fmt.Sprintf(`"activeTimeMs": %v,`, *activeMs)
	}
	g, err := usage.DecodeGraph([]byte(fmt.Sprintf(`{"contributions":[{"date":%q, %s "clients":[%s]}]}`,
		date, active, strings.Join(clients, ","))))
	if err != nil {
		t.Fatal(err)
	}
	return g
}

func ptr[T any](v T) *T { return &v }

var key = ObservationKey("claude", "m")

func near(a, b float64) bool { return math.Abs(a-b) < 0.0001 }

func TestObservationKeyMatchesLegacyFormat(t *testing.T) {
	// Must match the old JSON.stringify([client, modelId]) byte for byte, or merges diverge
	if got := ObservationKey("claude", "claude-opus-5"); got != `["claude","claude-opus-5"]` {
		t.Errorf("got %s", got)
	}
	// The Swift encoder escaped '/' and quotes; keys it wrote must still match
	if got := ObservationKey("cursor", `a/b"c`); got != `["cursor","a\/b\"c"]` {
		t.Errorf("got %s", got)
	}
}

func TestDecodesLegacyArchiveShape(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.json")
	json := `{"version":1,"days":{"2026-08-21":{"date":"2026-08-21","activeTimeMs":33757056,
		"observations":{"[\"claude\",\"claude-opus-5\"]":
		{"client":"claude","modelId":"claude-opus-5","providerId":"anthropic",
		"tokens":17753838,"cost":15.9580485,"messages":31}}}}}`
	if err := os.WriteFile(path, []byte(json), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	daily := a.DailySummaries(0, "2026-08-21", nil)
	if len(daily) != 1 || daily[0].Tokens != 17753838 || daily[0].ActiveTimeMs != 33757056 {
		t.Fatalf("daily %+v", daily)
	}
}

func TestRejectsOtherVersions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.json")
	if err := os.WriteFile(path, []byte(`{"version":2,"days":{}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("version 2 loaded")
	}
}

func TestCollapsedTokensExcludeReasoning(t *testing.T) {
	g, err := usage.DecodeGraph([]byte(`{"contributions":[{"date":"2026-08-20","clients":[
		{"client":"claude","modelId":"m","tokens":{"input":10,"output":5,"cacheRead":100,"cacheWrite":0,"reasoning":7},
		"cost":1,"messages":1}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	c := g.Contributions[0].Clients[0]
	if c.CollapsedTokens() != 115 || c.Tokens.Reasoning != 7 {
		t.Errorf("collapsed %d reasoning %d", c.CollapsedTokens(), c.Tokens.Reasoning)
	}
	a := NewArchive()
	a.Merge(g, "2026-08-21")
	o := a.Days["2026-08-20"].Observations[key]
	if o.Tokens != 115 || o.ReasoningTokens == nil || *o.ReasoningTokens != 7 {
		t.Errorf("observation %+v", o)
	}
}

func TestDuplicatesWithinOneGraphAreSummed(t *testing.T) {
	a := NewArchive()
	a.Merge(graphDay(t, "2026-08-20", nil, row{300, 1.0, 3}, row{200, 0.5, 2}), "2026-08-21")
	o := a.Days["2026-08-20"].Observations[key]
	if o.Tokens != 500 || o.Messages != 5 || !near(o.Cost, 1.5) {
		t.Errorf("observation %+v", o)
	}
}

func TestCrossMergeReplacesLargerNeverSums(t *testing.T) {
	a := NewArchive()
	a.Merge(graphDay(t, "2026-08-20", ptr(100.0), row{500, 1.0, 5}), "2026-08-21")
	// A smaller observation neither rolls back nor adds up
	a.Merge(graphDay(t, "2026-08-20", ptr(50.0), row{300, 0.5, 3}), "2026-08-21")
	o := a.Days["2026-08-20"].Observations[key]
	if o.Tokens != 500 || !near(o.Cost, 1.0) {
		t.Errorf("observation %+v", o)
	}
	if got := a.Days["2026-08-20"].ActiveTimeMs; got == nil || *got != 100 {
		t.Errorf("activeTimeMs %v", got)
	}
	// Same tokens and messages: replace whole to pick up corrected pricing
	a.Merge(graphDay(t, "2026-08-20", nil, row{500, 2.0, 5}), "2026-08-21")
	if got := a.Days["2026-08-20"].Observations[key].Cost; !near(got, 2.0) {
		t.Errorf("cost %v", got)
	}
}

func TestFutureDaysArePruned(t *testing.T) {
	a := NewArchive()
	a.Merge(graphDay(t, "2026-08-20", nil, row{1, 0, 0}), "2026-08-21")
	a.Merge(graphDay(t, "2026-09-01", nil, row{1, 0, 0}), "2026-08-21")
	if _, ok := a.Days["2026-08-20"]; !ok {
		t.Error("past day missing")
	}
	if _, ok := a.Days["2026-09-01"]; ok {
		t.Error("future day kept")
	}
}

func TestGrokBotRowsBecomeTheirOwnTool(t *testing.T) {
	g, err := usage.DecodeGraph([]byte(`{"contributions":[{"date":"2026-08-20","clients":[
		{"client":"cursor","modelId":"grok-bot-1","tokens":{"input":10},"cost":0,"messages":1},
		{"client":"cursor","modelId":"gpt-5","tokens":{"input":20},"cost":0,"messages":1}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	a := NewArchive()
	a.Merge(g, "2026-08-21")
	d := a.DailySummaries(0, "2026-08-21", nil)[0]
	if d.ByClient["grokbot"] != 10 || d.ByClient["cursor"] != 20 {
		t.Errorf("by client %v", d.ByClient)
	}
}

type excludeModel string

func (e excludeModel) Includes(_, model string) bool { return model != string(e) }

func TestFilterAndCap(t *testing.T) {
	a := NewArchive()
	for _, d := range []string{"2026-08-18", "2026-08-19", "2026-08-20"} {
		a.Merge(graphDay(t, d, nil, row{10, 1, 1}), "2026-08-21")
	}
	if got := a.DailySummaries(2, "2026-08-21", nil); len(got) != 2 || got[0].Date != "2026-08-19" {
		t.Errorf("capped %+v", got)
	}
	for _, d := range a.DailySummaries(0, "2026-08-21", excludeModel("m")) {
		if d.Tokens != 0 || len(d.ByModel) != 0 {
			t.Errorf("excluded model counted: %+v", d)
		}
	}
	c := a.Catalog()
	if len(c.Models) != 1 || c.Models[0].Tokens != 30 || c.Models[0].LastSeen != "2026-08-20" || !c.Models[0].Clients["claude"] {
		t.Errorf("catalog %+v", c)
	}
}

func TestAbsorbIsIdempotentAndLargerWins(t *testing.T) {
	legacy := NewArchive()
	legacy.Merge(graphDay(t, "2026-08-19", ptr(70.0), row{100, 1, 1}), "2026-08-21")
	legacy.Merge(graphDay(t, "2026-08-20", nil, row{50, 1, 1}), "2026-08-21")
	legacy.Days["2026-09-01"] = Day{Date: "2026-09-01", Observations: map[string]Observation{key: {Client: "claude", ModelID: "m", Tokens: 9}}}

	a := NewArchive()
	a.Merge(graphDay(t, "2026-08-20", nil, row{80, 2, 2}), "2026-08-21")
	if !a.Absorb(legacy, "2026-08-21") {
		t.Fatal("first absorb changed nothing")
	}
	if a.Absorb(legacy, "2026-08-21") {
		t.Fatal("second absorb changed something")
	}
	if a.Days["2026-08-19"].Observations[key].Tokens != 100 || *a.Days["2026-08-19"].ActiveTimeMs != 70 {
		t.Errorf("legacy day %+v", a.Days["2026-08-19"])
	}
	if a.Days["2026-08-20"].Observations[key].Tokens != 80 {
		t.Errorf("smaller legacy observation won: %+v", a.Days["2026-08-20"])
	}
	if _, ok := a.Days["2026-09-01"]; ok {
		t.Error("future legacy day absorbed")
	}
}

func TestSaveRoundTripsAndOmitsAbsentFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "a.json")
	a := NewArchive()
	g, _ := usage.DecodeGraph([]byte(`{"contributions":[{"date":"2026-08-20","clients":[{"client":"codex","modelId":"gpt-5","tokens":{"input":3},"cost":0.5,"messages":1}]}]}`))
	a.Merge(g, "2026-08-21")
	if err := a.Save(path); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	want := `{"days":{"2026-08-20":{"date":"2026-08-20","observations":{"[\"codex\",\"gpt-5\"]":{"client":"codex","cost":0.5,"messages":1,"modelId":"gpt-5","tokens":3}}}},"version":1}`
	if string(data) != want {
		t.Errorf("saved\n%s\nwant\n%s", data, want)
	}
	b, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if b.Days["2026-08-20"].Observations[ObservationKey("codex", "gpt-5")].Tokens != 3 {
		t.Errorf("reloaded %+v", b)
	}
}

type fakeGraph struct {
	mu sync.Mutex
	g  usage.Graph
	n  int
}

func (f *fakeGraph) Graph(context.Context) (usage.Graph, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.n++
	return f.g, nil
}

func TestStoreLoadsAbsorbsAndRefreshes(t *testing.T) {
	dir := t.TempDir()
	path, legacyPath := filepath.Join(dir, "a.json"), filepath.Join(dir, "legacy.json")
	legacy := NewArchive()
	legacy.Days["2020-01-01"] = Day{Date: "2020-01-01", Observations: map[string]Observation{key: {Client: "claude", ModelID: "m", Tokens: 5, Messages: 1}}}
	if err := legacy.Save(legacyPath); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(legacyPath)

	src := &fakeGraph{g: graphDay(t, "2020-01-02", nil, row{7, 0.1, 1})}
	s := NewStore(src, path, legacyPath)
	if !s.ImportedFromLegacy() || len(s.Daily()) != 1 {
		t.Fatalf("imported %v daily %+v", s.ImportedFromLegacy(), s.Daily())
	}
	var mu sync.Mutex
	changes := 0
	s.SetOnChange(func() { mu.Lock(); changes++; mu.Unlock() })
	if err := s.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(s.Daily()) != 2 || s.Version() < 2 {
		t.Fatalf("daily %+v version %d", s.Daily(), s.Version())
	}
	s.SetFilter(excludeModel("m"))
	if s.Daily()[0].Tokens != 0 || len(s.Catalog().Models) != 1 {
		t.Fatalf("filter not applied: %+v", s.Daily())
	}
	mu.Lock()
	if changes != 2 {
		t.Errorf("%d change notifications", changes)
	}
	mu.Unlock()

	// The legacy file is never written; a second launch imports nothing new
	after, _ := os.ReadFile(legacyPath)
	if string(before) != string(after) {
		t.Error("legacy archive modified")
	}
	if s2 := NewStore(src, path, legacyPath); s2.ImportedFromLegacy() || len(s2.Daily()) != 2 {
		t.Errorf("relaunch imported %v daily %d", s2.ImportedFromLegacy(), len(s2.Daily()))
	}
	var raw map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &raw); err != nil || raw["version"] != 1.0 {
		t.Errorf("saved archive %s", data)
	}
}

func TestStoreStartStop(t *testing.T) {
	src := &fakeGraph{g: graphDay(t, "2020-01-02", nil, row{7, 0.1, 1})}
	s := NewStore(src, filepath.Join(t.TempDir(), "a.json"), "")
	done := make(chan struct{}, 1)
	s.SetOnChange(func() {
		select {
		case done <- struct{}{}:
		default:
		}
	})
	s.Start(context.Background())
	<-done
	go s.Daily()
	s.Stop()
	s.Stop()
	if src.n < 1 {
		t.Fatal("no refresh ran")
	}
}
