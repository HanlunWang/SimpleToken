// Package usage holds the usage model shared by every collector and view: one period's totals with
// per-model, per-tool and tool × model slices, plus the tokscale output it is aggregated from.
package usage

import (
	"encoding/json"
	"strings"
	"time"
)

// Slice is one row of a breakdown (a model, a tool, or a tool × model pair).
type Slice struct {
	Tokens     int64   `json:"tokens"`
	CostUSD    float64 `json:"costUsd"`
	Messages   int64   `json:"messages"`
	Input      int64   `json:"input"`
	Output     int64   `json:"output"`
	CacheRead  int64   `json:"cacheRead"`
	CacheWrite int64   `json:"cacheWrite"`
}

// Add accumulates o into s.
func (s *Slice) Add(o Slice) {
	s.Tokens += o.Tokens
	s.CostUSD += o.CostUSD
	s.Messages += o.Messages
	s.Input += o.Input
	s.Output += o.Output
	s.CacheRead += o.CacheRead
	s.CacheWrite += o.CacheWrite
}

// Period is the usage of one period (today / this month / all time).
type Period struct {
	TotalTokens      int64            `json:"totalTokens"`
	CostUSD          float64          `json:"costUsd"`
	Messages         int64            `json:"messages"`
	InputTokens      int64            `json:"inputTokens"`
	OutputTokens     int64            `json:"outputTokens"`
	CacheReadTokens  int64            `json:"cacheReadTokens"`
	CacheWriteTokens int64            `json:"cacheWriteTokens"`
	ByModel          map[string]Slice `json:"byModel"`
	ByClient         map[string]Slice `json:"byClient"`
	// ByPair is tool × model (key = PairKey), for exact recomputation when models or tools are excluded.
	ByPair map[string]Slice `json:"byPair"`
}

// NewPeriod returns an empty period with its maps allocated.
func NewPeriod() Period {
	return Period{ByModel: map[string]Slice{}, ByClient: map[string]Slice{}, ByPair: map[string]Slice{}}
}

// Snapshot is one collection of all three periods. CollectedAt is captured before scanning (a single clock).
type Snapshot struct {
	Today       Period    `json:"today"`
	Month       Period    `json:"month"`
	AllTime     Period    `json:"allTime"`
	CollectedAt time.Time `json:"collectedAt"`
	DayKey      string    `json:"dayKey"`
}

const pairSep = "\x1f"

// PairKey joins a client and a model into a ByPair key.
func PairKey(client, model string) string { return client + pairSep + model }

// SplitPair is the inverse of PairKey.
func SplitPair(key string) (client, model string) {
	c, m, _ := strings.Cut(key, pairSep)
	return c, m
}

// NormalizeClient folds tokscale client names: anything containing "claude" is claude. Grok Bot is a Cursor app
// billed through the Cursor account, so tokscale reports it as cursor; its grok-bot-* models make it grokbot.
func NormalizeClient(raw, model string) string {
	name := strings.ToLower(raw)
	switch {
	case name == "":
		return "unknown"
	case strings.Contains(name, "claude"):
		return "claude"
	case name == "cursor" && strings.HasPrefix(strings.ToLower(model), "grok-bot"):
		return "grokbot"
	}
	return name
}

// Delta derives a wide window from a fresh narrow scan: max(0, base + fresh − anchor). For append-only logs this
// is exact (fresh − anchor is the increase since the anchor); it clamps at zero when logs were cleaned up.
func Delta(base, fresh, anchor Period) Period {
	r := NewPeriod()
	r.TotalTokens = clampI(base.TotalTokens + fresh.TotalTokens - anchor.TotalTokens)
	r.CostUSD = clampF(base.CostUSD + fresh.CostUSD - anchor.CostUSD)
	r.Messages = clampI(base.Messages + fresh.Messages - anchor.Messages)
	r.InputTokens = clampI(base.InputTokens + fresh.InputTokens - anchor.InputTokens)
	r.OutputTokens = clampI(base.OutputTokens + fresh.OutputTokens - anchor.OutputTokens)
	r.CacheReadTokens = clampI(base.CacheReadTokens + fresh.CacheReadTokens - anchor.CacheReadTokens)
	r.CacheWriteTokens = clampI(base.CacheWriteTokens + fresh.CacheWriteTokens - anchor.CacheWriteTokens)
	r.ByModel = deltaSlices(base.ByModel, fresh.ByModel, anchor.ByModel)
	r.ByClient = deltaSlices(base.ByClient, fresh.ByClient, anchor.ByClient)
	r.ByPair = deltaSlices(base.ByPair, fresh.ByPair, anchor.ByPair)
	return r
}

func deltaSlices(base, fresh, anchor map[string]Slice) map[string]Slice {
	out := map[string]Slice{}
	keys := map[string]struct{}{}
	for _, m := range []map[string]Slice{base, fresh, anchor} {
		for k := range m {
			keys[k] = struct{}{}
		}
	}
	for k := range keys {
		b, f, a := base[k], fresh[k], anchor[k]
		s := Slice{
			Tokens:     clampI(b.Tokens + f.Tokens - a.Tokens),
			CostUSD:    clampF(b.CostUSD + f.CostUSD - a.CostUSD),
			Messages:   clampI(b.Messages + f.Messages - a.Messages),
			Input:      clampI(b.Input + f.Input - a.Input),
			Output:     clampI(b.Output + f.Output - a.Output),
			CacheRead:  clampI(b.CacheRead + f.CacheRead - a.CacheRead),
			CacheWrite: clampI(b.CacheWrite + f.CacheWrite - a.CacheWrite),
		}
		if s.Tokens > 0 || s.CostUSD > 0 {
			out[k] = s
		}
	}
	return out
}

func clampI(v int64) int64 {
	if v < 0 {
		return 0
	}
	return v
}

func clampF(v float64) float64 {
	if v < 0 {
		return 0
	}
	return v
}

// ── tokscale output ──

// Report is `tokscale --json` output. Decoding is lenient: unknown fields are ignored, missing ones are zero.
type Report struct {
	Entries         []Entry `json:"entries"`
	TotalInput      int64   `json:"totalInput"`
	TotalOutput     int64   `json:"totalOutput"`
	TotalCacheRead  int64   `json:"totalCacheRead"`
	TotalCacheWrite int64   `json:"totalCacheWrite"`
	TotalMessages   int64   `json:"totalMessages"`
	TotalCost       float64 `json:"totalCost"`
}

// Entry is one row of a Report.
type Entry struct {
	Client       string  `json:"client"`
	SessionID    string  `json:"sessionId"`
	Model        string  `json:"model"`
	Provider     string  `json:"provider"`
	Input        int64   `json:"input"`
	Output       int64   `json:"output"`
	CacheRead    int64   `json:"cacheRead"`
	CacheWrite   int64   `json:"cacheWrite"`
	Reasoning    int64   `json:"reasoning"`
	MessageCount int64   `json:"messageCount"`
	Cost         float64 `json:"cost"`
}

// TotalTokens is input + output + cache read + cache write. Never add reasoning: tokscale already folds it
// into output, so adding it double-counts.
func (e Entry) TotalTokens() int64 { return e.Input + e.Output + e.CacheRead + e.CacheWrite }

// DecodeReport parses tokscale --json output.
func DecodeReport(data []byte) (Report, error) {
	var r Report
	err := json.Unmarshal(data, &r)
	return r, err
}

// Aggregate folds the rows into a Period. With rows it splits by model and tool; empty output falls back to the
// top-level totals (no split).
func (r Report) Aggregate() Period {
	p := NewPeriod()
	if len(r.Entries) == 0 {
		p.InputTokens, p.OutputTokens = r.TotalInput, r.TotalOutput
		p.CacheReadTokens, p.CacheWriteTokens = r.TotalCacheRead, r.TotalCacheWrite
		p.TotalTokens = p.InputTokens + p.OutputTokens + p.CacheReadTokens + p.CacheWriteTokens
		p.Messages, p.CostUSD = r.TotalMessages, r.TotalCost
		return p
	}
	for _, e := range r.Entries {
		tokens := e.TotalTokens()
		p.TotalTokens += tokens
		p.CostUSD += e.Cost
		p.Messages += e.MessageCount
		p.InputTokens += e.Input
		p.OutputTokens += e.Output
		p.CacheReadTokens += e.CacheRead
		p.CacheWriteTokens += e.CacheWrite
		client := NormalizeClient(e.Client, e.Model)
		s := Slice{Tokens: tokens, CostUSD: e.Cost, Messages: e.MessageCount, Input: e.Input, Output: e.Output, CacheRead: e.CacheRead, CacheWrite: e.CacheWrite}
		addTo(p.ByClient, client, s)
		model := e.Model
		if model == "" {
			model = "unknown"
		} else {
			addTo(p.ByModel, model, s)
		}
		addTo(p.ByPair, PairKey(client, model), s)
	}
	return p
}

func addTo(m map[string]Slice, k string, s Slice) {
	cur := m[k]
	cur.Add(s)
	m[k] = cur
}

// Graph is `tokscale graph --json` output: the per-day history source.
type Graph struct {
	Contributions []GraphDay `json:"contributions"`
}

// GraphDay is one day of a Graph.
type GraphDay struct {
	Date         string        `json:"date"`
	Totals       GraphTotals   `json:"totals"`
	ActiveTimeMs float64       `json:"activeTimeMs"`
	Clients      []GraphClient `json:"clients"`
}

// GraphTotals are a day's totals.
type GraphTotals struct {
	Tokens   int64   `json:"tokens"`
	Cost     float64 `json:"cost"`
	Messages int64   `json:"messages"`
}

// GraphClient is one client × model row of a day.
type GraphClient struct {
	Client     string         `json:"client"`
	ModelID    string         `json:"modelId"`
	ProviderID string         `json:"providerId"`
	Tokens     TokenBreakdown `json:"tokens"`
	Cost       float64        `json:"cost"`
	Messages   int64          `json:"messages"`
}

// TokenBreakdown splits a row's tokens.
type TokenBreakdown struct {
	Input      int64 `json:"input"`
	Output     int64 `json:"output"`
	CacheRead  int64 `json:"cacheRead"`
	CacheWrite int64 `json:"cacheWrite"`
	Reasoning  int64 `json:"reasoning"`
}

// CollapsedTokens is input + output + cache read + cache write, without reasoning.
func (c GraphClient) CollapsedTokens() int64 {
	t := c.Tokens
	return t.Input + t.Output + t.CacheRead + t.CacheWrite
}

// DecodeGraph parses tokscale graph --json output.
func DecodeGraph(data []byte) (Graph, error) {
	var g Graph
	err := json.Unmarshal(data, &g)
	return g, err
}

// DayKey is the local calendar day of t as "YYYY-MM-DD", the key of every per-day map and file.
func DayKey(t time.Time) string { return t.Format("2006-01-02") }
