package gui

import (
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/intraday"
	"github.com/HanlunWang/SimpleToken/internal/limits"
	"github.com/HanlunWang/SimpleToken/internal/settings"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// data is everything the views read, copied from the stores on the main thread whenever one of them changes.
// Views never touch the stores directly.
type data struct {
	History     []analytics.DaySummary // filtered daily totals, oldest first (today excluded)
	Rows        []analytics.Day        // raw tool × model rows per day (for the flow and the usage map)
	Live        *analytics.DaySummary  // today so far (filtered)
	TodayKey    string
	Snapshot    usage.Snapshot    // today / month / all time (unfiltered; filter applied on read)
	Intra       intraday.Snapshot // Claude Code tokens per half hour per model, last 90 days
	Limits      []limits.Entry
	UpdatedAt   time.Time
	Refreshing  bool
	Collected   bool // a scan has finished at least once
	CursorError string
}

// model memoizes what views derive from data (reports per range × metric, colour slots), keyed by a version
// that bumps on every data or filter change.
type model struct {
	d        data
	s        settings.Settings
	version  int
	reports  map[string]analytics.Report
	rank     []string // models by the last 30 days, colour slots follow it (never the selected range)
	monthArr analytics.MonthCost
	now      func() time.Time
}

func newModel(s settings.Settings) *model {
	return &model{s: s, reports: map[string]analytics.Report{}, now: time.Now}
}

// setData replaces the data and drops every memoized value.
func (m *model) setData(d data) {
	m.d = d
	m.invalidate()
}

func (m *model) invalidate() {
	m.version++
	m.reports = map[string]analytics.Report{}
	m.rank = nil
	m.monthArr = analytics.MonthCost{}
}

func (m *model) report(r analytics.Range, metric analytics.Metric) analytics.Report {
	key := string(r) + "|" + string(metric)
	if rep, ok := m.reports[key]; ok {
		return rep
	}
	rep := analytics.BuildReport(r, metric, m.d.History, m.d.Live, m.d.TodayKey)
	m.reports[key] = rep
	return rep
}

func (m *model) current() analytics.Report {
	return m.report(analytics.Range(m.s.Range), analytics.Metric(m.s.Metric))
}

func (m *model) monthCost() analytics.MonthCost {
	if m.monthArr.DaysInMonth == 0 {
		m.monthArr = analytics.BuildMonthCost(m.d.History, m.d.Live, m.d.TodayKey)
	}
	return m.monthArr
}

// ranking is the models of the last 30 days by tokens; colour slots follow it.
func (m *model) ranking() []string {
	if m.rank != nil {
		return m.rank
	}
	rep := m.report(analytics.RangeMonth, analytics.MetricTokens)
	m.rank = make([]string, 0, len(rep.Models))
	for _, s := range rep.Models {
		m.rank = append(m.rank, s.Key)
	}
	return m.rank
}

// days returns the last n daily summaries including today (filled with empty days).
func (m *model) days(n int) []analytics.DaySummary {
	rep := m.report(analytics.RangeAll, analytics.MetricTokens)
	all := rep.Days
	if len(all) > n {
		return all[len(all)-n:]
	}
	return all
}

// pairs is tool × model tokens over the days of a report (for the flow and the usage map).
func (m *model) pairs(rep analytics.Report) map[[2]string]float64 {
	in := map[string]bool{}
	for _, d := range rep.Days {
		in[d.Date] = true
	}
	f := analytics.NewFilter(m.s.ExcludedModels, m.s.ExcludedClients)
	out := map[[2]string]float64{}
	for _, d := range m.d.Rows {
		if !in[d.Date] {
			continue
		}
		for _, r := range d.Rows {
			if f.Includes(r.Client, r.Model) {
				out[[2]string{r.Client, r.Model}] += metricOfRow(r, rep.Metric)
			}
		}
	}
	if m.d.Live != nil && in[m.d.TodayKey] {
		for k, s := range f.Apply(m.d.Snapshot.Today).ByPair {
			c, md := usage.SplitPair(k)
			out[[2]string{c, md}] += metricOfSlice(s, rep.Metric)
		}
	}
	return out
}

func metricOfRow(r analytics.Row, metric analytics.Metric) float64 {
	switch metric {
	case analytics.MetricCost:
		return r.Cost
	case analytics.MetricMessages:
		return float64(r.Messages)
	}
	return float64(r.Tokens)
}

func metricOfSlice(s usage.Slice, metric analytics.Metric) float64 {
	switch metric {
	case analytics.MetricCost:
		return s.CostUSD
	case analytics.MetricMessages:
		return float64(s.Messages)
	}
	return float64(s.Tokens)
}

// today is today's period with the usage filter applied.
func (m *model) today() usage.Period {
	return analytics.NewFilter(m.s.ExcludedModels, m.s.ExcludedClients).Apply(m.d.Snapshot.Today)
}

// ── Vendors and colours ──

// vendorOf maps a model id to its vendor: anthropic, openai, google, xai or other.
func vendorOf(model string) string {
	m := strings.ToLower(model)
	switch {
	case strings.Contains(m, "claude"), strings.Contains(m, "opus"), strings.Contains(m, "sonnet"), strings.Contains(m, "haiku"), strings.Contains(m, "fable"):
		return "anthropic"
	case strings.Contains(m, "gpt"), strings.Contains(m, "codex"), strings.HasPrefix(m, "o1"), strings.HasPrefix(m, "o3"), strings.HasPrefix(m, "o4"):
		return "openai"
	case strings.Contains(m, "gemini"):
		return "google"
	case strings.Contains(m, "grok"):
		return "xai"
	}
	return "other"
}

// vendorLogo is the logo file for a vendor or a tool id.
func vendorLogo(id string) string {
	switch id {
	case "anthropic", "claude":
		return "claude"
	case "openai":
		return "openai"
	case "codex":
		return "codex"
	case "google", "gemini":
		return "gemini"
	case "xai", "grok", "grokbot":
		return "grok"
	case "cursor":
		return "cursor"
	case "copilot":
		return "githubcopilot"
	case "opencode":
		return "opencode"
	}
	return ""
}

// vendorTint is the small vendor mark colour (logos, bands). Mono marks use the secondary ink.
func (m *model) vendorTint(p palette, vendor string) ui.Color {
	if m.s.VendorMarks == "mono" {
		return p.T2
	}
	switch vendor {
	case "anthropic", "claude":
		return p.Vendor.Anthropic
	case "openai", "codex":
		return p.Vendor.OpenAI
	case "google", "gemini":
		return p.Vendor.Google2
	case "xai", "grok", "grokbot", "cursor":
		return p.Vendor.XAI
	}
	return p.T3
}

// modelColor is a series colour: the ink ladder by 30-day rank, or the vendor ladder, the rest "Other".
func (m *model) modelColor(p palette, model string) ui.Color {
	rank := slices.Index(m.ranking(), model)
	sep := max(2, min(8, m.s.SeparateModels))
	if c, ok := m.s.ModelColorOverrides[model]; ok && c != "" {
		return ui.Hex(c)
	}
	if rank < 0 || rank >= sep {
		return pick(m.s.SeriesColors == "vendor", p.Vendor.Other, p.Ink[3])
	}
	if m.s.SeriesColors != "vendor" {
		return p.Ink[min(rank, 3)]
	}
	// Vendor ladder: the n-th model of a vendor (by rank) takes the n-th step.
	v := vendorOf(model)
	step := 0
	for _, o := range m.ranking()[:rank] {
		if vendorOf(o) == v {
			step++
		}
	}
	switch v {
	case "anthropic":
		return []ui.Color{p.Vendor.Anthropic, p.Vendor.Anthropic2, p.Vendor.Anthropic3}[min(step, 2)]
	case "openai":
		return []ui.Color{p.Vendor.OpenAI, p.Vendor.OpenAI2}[min(step, 1)]
	case "google":
		return []ui.Color{p.Vendor.Google, p.Vendor.Google2}[min(step, 1)]
	case "xai":
		return []ui.Color{p.Vendor.XAI, p.Vendor.XAI2}[min(step, 1)]
	}
	return p.Vendor.Other
}

// toolOrder is the fixed order of tools; their ink steps follow it.
var toolOrder = []string{"claude", "codex", "cursor", "grokbot", "gemini", "copilot", "opencode", "grok", "kiro"}

func (m *model) toolColor(p palette, tool string) ui.Color {
	if c, ok := m.s.ToolColorOverrides[tool]; ok && c != "" {
		return ui.Hex(c)
	}
	if m.s.SeriesColors == "vendor" {
		switch tool {
		case "claude":
			return p.Vendor.Anthropic
		case "codex":
			return p.Vendor.OpenAI
		case "cursor":
			return p.Vendor.XAI2
		case "grokbot", "grok":
			return p.Vendor.XAI
		case "gemini":
			return p.Vendor.Google
		}
		return p.Vendor.Other
	}
	i := slices.Index(toolOrder, tool)
	if i < 0 {
		i = 3
	}
	return p.Ink[min(i, 3)]
}

var toolNames = map[string]string{
	"claude": "Claude Code", "codex": "Codex", "copilot": "Copilot", "opencode": "OpenCode", "gemini": "Gemini",
	"cursor": "Cursor", "grokbot": "Grok Bot", "grok": "Grok Build", "kiro": "Kiro",
}

func toolName(id string) string {
	if n, ok := toolNames[id]; ok {
		return n
	}
	return id
}

// modelName is a model's alias or id.
func (m *model) modelName(id string) string {
	if a := m.s.ModelAliases[id]; a != "" {
		return a
	}
	return id
}

// ── Numbers ──

var fmtr = format.English

func (m *model) num(v float64) string { return fmtr.Tokens(v, m.s.ExactNumbers) }
func (m *model) metricText(metric analytics.Metric, v float64) string {
	return fmtr.Metric(v, string(metric), m.s.ExactNumbers)
}

// splitNum splits a short number into value and unit ("2.73", "B") for the dot face.
func splitNum(s string) (string, string) {
	i := strings.LastIndexAny(s, "0123456789")
	if i < 0 || i == len(s)-1 {
		return s, ""
	}
	return strings.TrimSpace(s[:i+1]), strings.TrimSpace(s[i+1:])
}

// sortedKeys returns map keys by value, largest first.
func sortedKeys[V int64 | float64](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}

// half is Claude Code tokens per half hour of a day (48 slots), with excluded models left out.
func (m *model) half(dayKey string) []float64 {
	ex := map[string]bool{}
	for _, x := range m.s.ExcludedModels {
		ex[x] = true
	}
	out := toF(m.d.Intra.Buckets(dayKey, ex))
	if len(out) < intraday.SlotsPerDay {
		out = append(out, make([]float64, intraday.SlotsPerDay-len(out))...)
	}
	return out
}

func (m *model) todayHalf() []float64 { return m.half(m.d.TodayKey) }
func (m *model) yesterdayHalf() []float64 {
	return m.half(format.DayKey(m.now().AddDate(0, 0, -1)))
}
