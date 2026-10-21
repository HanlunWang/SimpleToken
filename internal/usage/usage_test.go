package usage

import (
	"math"
	"testing"
	"time"
)

func period(tokens int64, cost float64, models map[string]int64) Period {
	p := NewPeriod()
	p.TotalTokens, p.CostUSD = tokens, cost
	for m, t := range models {
		p.ByModel[m] = Slice{Tokens: t}
	}
	return p
}

func TestAppendOnlyDeltaIsIdentity(t *testing.T) {
	// Append-only logs: base + (fresh - anchor) always equals the true wide-window value
	r := Delta(period(100, 10, nil), period(45, 4.5, nil), period(30, 3, nil))
	if r.TotalTokens != 115 || math.Abs(r.CostUSD-11.5) > 0.0001 {
		t.Errorf("got %d %v", r.TotalTokens, r.CostUSD)
	}
}

func TestNegativeClampProtectsWiderWindows(t *testing.T) {
	// Logs cleaned up: fresh < anchor; the wide window undercounts rather than go negative
	r := Delta(period(20, 2, nil), period(0, 0, nil), period(30, 3, nil))
	if r.TotalTokens != 0 || r.CostUSD != 0 {
		t.Errorf("got %d %v", r.TotalTokens, r.CostUSD)
	}
}

func TestSliceUnionMergesAllKeys(t *testing.T) {
	anchor := period(10, 0, map[string]int64{"opus": 10})
	base := period(50, 0, map[string]int64{"opus": 40, "sonnet": 10})
	fresh := period(25, 0, map[string]int64{"opus": 15, "fable": 10})
	r := Delta(base, fresh, anchor)
	if r.ByModel["opus"].Tokens != 45 || r.ByModel["sonnet"].Tokens != 10 || r.ByModel["fable"].Tokens != 10 {
		t.Errorf("by model %v", r.ByModel)
	}
}

func TestZeroSlicesArePruned(t *testing.T) {
	r := Delta(period(10, 0, map[string]int64{"opus": 10}), period(0, 0, nil), period(10, 0, map[string]int64{"opus": 10}))
	if _, ok := r.ByModel["opus"]; ok {
		t.Errorf("zero slice kept: %v", r.ByModel)
	}
}

func TestDeltaToleratesNilMaps(t *testing.T) {
	// Periods decoded from old anchors may lack byPair
	var empty Period
	r := Delta(empty, period(5, 1, map[string]int64{"m": 5}), empty)
	if r.TotalTokens != 5 || r.ByModel["m"].Tokens != 5 || r.ByPair == nil {
		t.Errorf("got %+v", r)
	}
}

func TestPairKeyRoundTrip(t *testing.T) {
	c, m := SplitPair(PairKey("claude", "claude-opus-5"))
	if c != "claude" || m != "claude-opus-5" {
		t.Errorf("got %q %q", c, m)
	}
}

func TestNormalizeClient(t *testing.T) {
	cases := []struct{ raw, model, want string }{
		{"", "m", "unknown"},
		{"Claude-Code", "m", "claude"},
		{"cursor", "Grok-Bot-1", "grokbot"},
		{"cursor", "gpt-5", "cursor"},
		{"Codex", "gpt-5", "codex"},
	}
	for _, c := range cases {
		if got := NormalizeClient(c.raw, c.model); got != c.want {
			t.Errorf("NormalizeClient(%q, %q) = %q, want %q", c.raw, c.model, got, c.want)
		}
	}
}

func TestDayKeyIsLocalDate(t *testing.T) {
	if got := DayKey(time.Date(2026, 3, 4, 23, 59, 0, 0, time.Local)); got != "2026-03-04" {
		t.Errorf("got %s", got)
	}
}
