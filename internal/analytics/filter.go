package analytics

import (
	"maps"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Filter holds the models / tools switched off in settings: they enter no statistic (totals, charts and
// distributions all exclude them). Tool names are normalised (usage.NormalizeClient).
type Filter struct {
	ExcludedModels  map[string]bool
	ExcludedClients map[string]bool
}

// NewFilter builds a filter from lists of excluded models and tools.
func NewFilter(models, clients []string) Filter {
	f := Filter{ExcludedModels: map[string]bool{}, ExcludedClients: map[string]bool{}}
	for _, m := range models {
		f.ExcludedModels[m] = true
	}
	for _, c := range clients {
		f.ExcludedClients[c] = true
	}
	return f
}

// IsEmpty reports whether nothing is excluded.
func (f Filter) IsEmpty() bool { return count(f.ExcludedModels) == 0 && count(f.ExcludedClients) == 0 }

func count(m map[string]bool) int {
	n := 0
	for _, v := range m {
		if v {
			n++
		}
	}
	return n
}

// Equal compares the excluded sets.
func (f Filter) Equal(o Filter) bool {
	return sameSet(f.ExcludedModels, o.ExcludedModels) && sameSet(f.ExcludedClients, o.ExcludedClients)
}

func sameSet(a, b map[string]bool) bool {
	if count(a) != count(b) {
		return false
	}
	for k, v := range a {
		if v && !b[k] {
			return false
		}
	}
	return true
}

// Includes reports whether a tool × model slice counts.
func (f Filter) Includes(client, model string) bool {
	return !f.ExcludedClients[client] && !f.ExcludedModels[model]
}

// Apply recomputes a period under the filter. Exact when the tool × model detail (ByPair) exists; old anchors
// without it (the seconds before the first full scan after launch) fall back to subtracting per tool and per
// model. The input is never modified.
func (f Filter) Apply(p usage.Period) usage.Period {
	if f.IsEmpty() {
		return p
	}
	if len(p.ByPair) == 0 {
		return f.approximate(p)
	}
	out := usage.NewPeriod()
	for key, s := range p.ByPair {
		client, model := usage.SplitPair(key)
		if !f.Includes(client, model) {
			continue
		}
		out.ByPair[key] = s
		addSlice(out.ByClient, client, s)
		if model != "unknown" {
			addSlice(out.ByModel, model, s)
		}
		out.TotalTokens += s.Tokens
		out.CostUSD += s.CostUSD
		out.Messages += s.Messages
		out.InputTokens += s.Input
		out.OutputTokens += s.Output
		out.CacheReadTokens += s.CacheRead
		out.CacheWriteTokens += s.CacheWrite
	}
	return out
}

func (f Filter) approximate(p usage.Period) usage.Period {
	out := p
	out.ByClient = maps.Clone(p.ByClient)
	out.ByModel = maps.Clone(p.ByModel)
	out.ByPair = maps.Clone(p.ByPair)
	if out.ByClient == nil {
		out.ByClient = map[string]usage.Slice{}
	}
	if out.ByModel == nil {
		out.ByModel = map[string]usage.Slice{}
	}
	if out.ByPair == nil {
		out.ByPair = map[string]usage.Slice{}
	}
	var removed usage.Slice
	for c, on := range f.ExcludedClients {
		if s, ok := out.ByClient[c]; on && ok {
			removed.Add(s)
			delete(out.ByClient, c)
		}
	}
	for m, on := range f.ExcludedModels {
		if s, ok := out.ByModel[m]; on && ok {
			removed.Add(s)
			delete(out.ByModel, m)
		}
	}
	out.TotalTokens = max(0, out.TotalTokens-removed.Tokens)
	out.CostUSD = max(0, out.CostUSD-removed.CostUSD)
	out.Messages = max(0, out.Messages-removed.Messages)
	out.InputTokens = max(0, out.InputTokens-removed.Input)
	out.OutputTokens = max(0, out.OutputTokens-removed.Output)
	out.CacheReadTokens = max(0, out.CacheReadTokens-removed.CacheRead)
	out.CacheWriteTokens = max(0, out.CacheWriteTokens-removed.CacheWrite)
	return out
}

func addSlice(m map[string]usage.Slice, k string, s usage.Slice) {
	cur := m[k]
	cur.Add(s)
	m[k] = cur
}
