// Package demo is synthetic usage for screenshots and demos, turned on with SIMPLETOKEN_DEMO=1. The collectors
// do not run then, so no real logs are read and nothing is written. Every number comes from small deterministic
// generators, so every screenshot shows the same data.
package demo

import (
	"math"
	"os"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/intraday"
	"github.com/HanlunWang/SimpleToken/internal/limits"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Enabled reports whether demo mode is on (SIMPLETOKEN_DEMO=1). The Swift app also honoured a demoMode user
// default; that switch belongs to the settings layer.
func Enabled() bool { return os.Getenv("SIMPLETOKEN_DEMO") == "1" }

type mixRow struct {
	client, model, provider string
	share, perMillion       float64 // share of the day's tokens, cost per million tokens
}

var mix = []mixRow{
	{"claude", "claude-opus-5", "anthropic", 0.46, 0.92},
	{"claude", "claude-sonnet-5", "anthropic", 0.27, 0.41},
	{"claude", "claude-haiku-5", "anthropic", 0.06, 0.12},
	{"codex", "gpt-5.3-codex", "openai", 0.14, 0.55},
	{"gemini", "gemini-3-pro", "google", 0.05, 0.48},
	{"copilot", "gpt-5-mini", "openai", 0.02, 0.20},
}

// rng is a 64-bit LCG (the Swift DemoData generator, bit for bit).
type rng struct{ state uint64 }

func (r *rng) next() float64 {
	r.state = r.state*6364136223846793005 + 1442695040888963407
	return float64(r.state>>11) / float64(uint64(1)<<53)
}

// Observation is one tool × model row of a demo day; it maps one to one onto a daily-history-archive observation
// (client, modelId, providerId, tokens, cost, messages; no reasoning tokens).
type Observation struct {
	Client     string
	ModelID    string
	ProviderID string
	Tokens     int64
	Cost       float64
	Messages   int64
}

// Day is one demo day (no active time), observations in a fixed order.
type Day struct {
	Date         string
	Observations []Observation
}

type dayTotal struct {
	key    string
	tokens float64
}

// dailyTokens are the day totals of the last `days` days, oldest first: a slow upward trend, quieter weekends,
// the odd day off, and 96 M today.
func dailyTokens(days int, today time.Time) []dayTotal {
	r := rng{42}
	out := make([]dayTotal, 0, days)
	for offset := days - 1; offset >= 0; offset-- {
		d := today.Local().AddDate(0, 0, -offset)
		wd := d.Weekday()
		weekend := wd == time.Sunday || wd == time.Saturday
		trend := 0.45 + 0.55*float64(days-offset)/float64(days)
		base := 150e6
		if weekend {
			base = 38e6
		}
		tokens := base * trend * (0.55 + r.next()*0.9)
		off := 0.04
		if weekend {
			off = 0.35
		}
		if r.next() < off {
			tokens = 0
		}
		if offset == 0 {
			tokens = 96e6
		}
		out = append(out, dayTotal{format.DayKey(d), tokens})
	}
	return out
}

// Archive is 240 days of demo history, oldest first (days off are absent).
func Archive(today time.Time) []Day {
	r := rng{7}
	var out []Day
	for _, dt := range dailyTokens(240, today) {
		if dt.tokens <= 0 {
			continue
		}
		day := Day{Date: dt.key}
		for _, m := range mix {
			tokens := int64(dt.tokens * m.share * (0.7 + r.next()*0.6))
			if tokens <= 0 {
				continue
			}
			day.Observations = append(day.Observations, Observation{
				Client: m.client, ModelID: m.model, ProviderID: m.provider, Tokens: tokens,
				Cost: float64(tokens) / 1e6 * m.perMillion, Messages: max(1, tokens/280_000),
			})
		}
		out = append(out, day)
	}
	return out
}

// AnalyticsDays converts the demo archive into analytics input.
func AnalyticsDays(archive []Day) []analytics.Day {
	out := make([]analytics.Day, 0, len(archive))
	for _, d := range archive {
		ad := analytics.Day{Date: d.Date}
		for _, o := range d.Observations {
			ad.Rows = append(ad.Rows, analytics.Row{Client: o.Client, Model: o.ModelID, Tokens: o.Tokens, Cost: o.Cost, Messages: o.Messages})
		}
		out = append(out, ad)
	}
	return out
}

// Snapshot is today / this month / all time derived from the same archive, so every widget agrees. Token
// composition is a fixed split: 93 % cache read, 3.5 % cache write, 1.2 % output, the rest input.
func Snapshot(archive []Day, today time.Time) usage.Snapshot {
	todayKey := format.DayKey(today)
	monthPrefix := todayKey[:7]
	period := func(include func(string) bool) usage.Period {
		p := usage.NewPeriod()
		for _, d := range archive {
			if !include(d.Date) {
				continue
			}
			for _, o := range d.Observations {
				cacheRead := int64(float64(o.Tokens) * 0.93)
				cacheWrite := int64(float64(o.Tokens) * 0.035)
				output := int64(float64(o.Tokens) * 0.012)
				input := o.Tokens - cacheRead - cacheWrite - output
				s := usage.Slice{Tokens: o.Tokens, CostUSD: o.Cost, Messages: o.Messages, Input: input, Output: output, CacheRead: cacheRead, CacheWrite: cacheWrite}
				p.TotalTokens += o.Tokens
				p.CostUSD += o.Cost
				p.Messages += o.Messages
				p.InputTokens += input
				p.OutputTokens += output
				p.CacheReadTokens += cacheRead
				p.CacheWriteTokens += cacheWrite
				add(p.ByModel, o.ModelID, s)
				add(p.ByClient, o.Client, s)
				add(p.ByPair, usage.PairKey(o.Client, o.ModelID), s)
			}
		}
		return p
	}
	return usage.Snapshot{
		Today:       period(func(k string) bool { return k == todayKey }),
		Month:       period(func(k string) bool { return len(k) >= 7 && k[:7] == monthPrefix }),
		AllTime:     period(func(string) bool { return true }),
		CollectedAt: today,
		DayKey:      todayKey,
	}
}

func add(m map[string]usage.Slice, k string, s usage.Slice) {
	cur := m[k]
	cur.Add(s)
	m[k] = cur
}

// Limits are the demo plan limits, updated 40 seconds ago.
func Limits(now time.Time) (claude, codex, cursor limits.Snapshot) {
	at := func(d time.Duration) *time.Time { t := now.Add(d); return &t }
	hours := func(h float64) time.Duration { return time.Duration(h * float64(time.Hour)) }
	days := func(d float64) time.Duration { return time.Duration(d * 24 * float64(time.Hour)) }
	updated := now.Add(-40 * time.Second)
	claude = limits.Snapshot{Provider: limits.Claude, Windows: []limits.Window{
		limits.NewWindow(limits.Session, 38, at(hours(2.4)), 300, ""),
		limits.NewWindow(limits.Weekly, 57, at(days(2.6)), 0, ""),
		limits.NewWindow(limits.Fable, 21, at(days(2.6)), 0, ""),
	}, AccountLabel: "Max 20x", UpdatedAt: updated}
	codex = limits.Snapshot{Provider: limits.Codex, Windows: []limits.Window{
		limits.NewWindow(limits.Session, 12, at(hours(3.1)), 300, ""),
		limits.NewWindow(limits.Weekly, 26, at(days(4.2)), 0, ""),
	}, AccountLabel: "Pro", UpdatedAt: updated}
	cursor = limits.Snapshot{Provider: limits.Cursor, Windows: []limits.Window{
		limits.NewWindow(limits.Weekly, 44, at(days(3.3)), 0, ""),
	}, AccountLabel: "X Pass Premium", UpdatedAt: updated}
	return claude, codex, cursor
}

// Intraday is half-hour buckets for the Claude models over the last 90 days of the archive: weekday office
// hours plus some evenings, today only up to the current half hour.
func Intraday(archive []Day, today time.Time) intraday.Snapshot {
	snap := intraday.NewSnapshot()
	r := rng{99}
	local := today.Local()
	nowSlot := local.Hour() * 2
	if local.Minute() >= 30 {
		nowSlot++
	}
	todayKey := format.DayKey(today)
	profile := make([]float64, intraday.SlotsPerDay)
	for slot := range profile {
		h := float64(slot) / 2
		morning := math.Exp(-math.Pow((h-10.5)/1.6, 2))
		afternoon := 1.2 * math.Exp(-math.Pow((h-15)/2.0, 2))
		evening := 0.45 * math.Exp(-math.Pow((h-21.5)/1.3, 2))
		profile[slot] = morning + afternoon + evening
	}
	start := max(0, len(archive)-90) // the archive is sorted oldest first
	for _, d := range archive[start:] {
		byModel := map[string][]int64{}
		for _, o := range d.Observations {
			if o.Client != "claude" {
				continue
			}
			lastSlot := intraday.SlotsPerDay - 1
			if d.Date == todayKey {
				lastSlot = nowSlot
			}
			weights := make([]float64, intraday.SlotsPerDay)
			sum := 0.0
			for i, w := range profile {
				if i <= lastSlot {
					weights[i] = w * (0.4 + r.next()*1.2)
				}
				sum += weights[i]
			}
			sum = max(1e-9, sum)
			buckets := make([]int64, intraday.SlotsPerDay)
			for i, w := range weights {
				buckets[i] = int64(float64(o.Tokens) * w / sum)
			}
			byModel[o.ModelID] = buckets
		}
		snap.ByModel[d.Date] = byModel
	}
	return snap
}
