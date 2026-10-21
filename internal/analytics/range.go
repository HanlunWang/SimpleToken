package analytics

import (
	"sort"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

// Range is the global time range. The raw values are the ones the Swift app persisted.
type Range string

const (
	RangeDay     Range = "1D"
	RangeWeek    Range = "1W"
	RangeMonth   Range = "1M"
	RangeQuarter Range = "3M"
	RangeHalf    Range = "6M"
	RangeYTD     Range = "YTD"
	RangeYear    Range = "1Y"
	RangeAll     Range = "ALL"
)

// Ranges lists every range in picker order.
var Ranges = []Range{RangeDay, RangeWeek, RangeMonth, RangeQuarter, RangeHalf, RangeYTD, RangeYear, RangeAll}

// Label is the range's translatable name.
func (r Range) Label() format.Text {
	switch r {
	case RangeDay:
		return format.T("Today")
	case RangeWeek:
		return format.T("Last 7 days")
	case RangeMonth:
		return format.T("Last 30 days")
	case RangeQuarter:
		return format.T("Last 3 months")
	case RangeHalf:
		return format.T("Last 6 months")
	case RangeYTD:
		return format.T("Year to date")
	case RangeYear:
		return format.T("Last 12 months")
	}
	return format.T("All time")
}

// Metric is the switchable main metric. The raw values match format.Metric* and the Swift app's.
type Metric string

const (
	MetricTokens   Metric = "tokens"
	MetricCost     Metric = "cost"
	MetricMessages Metric = "messages"
)

// Metrics lists every metric in picker order.
var Metrics = []Metric{MetricTokens, MetricCost, MetricMessages}

// Label is the metric's name ("Tokens" is not translated).
func (m Metric) Label() format.Text {
	switch m {
	case MetricCost:
		return format.T("Cost")
	case MetricMessages:
		return format.T("Messages")
	}
	return format.T("Tokens")
}

// Value is the metric's value for a day.
func (m Metric) Value(d DaySummary) float64 {
	switch m {
	case MetricCost:
		return d.Cost
	case MetricMessages:
		return float64(d.Messages)
	}
	return float64(d.Tokens)
}

// CumulativePoint is one day on a cumulative curve.
type CumulativePoint struct {
	Index int
	Date  string
	// Position is the horizontal position in 0…1 (aligns this period with the previous one).
	Position   float64
	Cumulative float64
	Value      float64
}

// Share is a model's or tool's part of the range.
type Share struct {
	Key    string
	Tokens int64
	Cost   float64
}

// Bucket is one bar: a day, or a week above 120 days.
type Bucket struct {
	Start string
	Label string
	// ByModel is the metric value per model id.
	ByModel map[string]float64
}

// Total is the bar's height.
func (b Bucket) Total() float64 {
	t := 0.0
	for _, v := range b.ByModel {
		t += v
	}
	return t
}

// Stats are the stat tiles.
type Stats struct {
	AveragePerDay       float64
	AveragePerActiveDay float64
	// Peak is the day with the most tokens; nil when the range has no usage.
	Peak           *DaySummary
	ActiveDays     int
	TotalDays      int
	Streak         int
	CostPerMillion float64
	TotalCost      float64
}

// Report is everything for one time range: every card reads from it so they all agree.
type Report struct {
	Range  Range
	Metric Metric
	// Days are the consecutive days of the range (missing days count as zero).
	Days []DaySummary
	// PreviousDays is the previous period; nil for ALL.
	PreviousDays  []DaySummary
	Current       []CumulativePoint
	Previous      []CumulativePoint
	Total         float64
	PreviousTotal *float64
	Models        []Share
	Clients       []Share
	Buckets       []Bucket
	WeeklyBuckets bool
	Stats         Stats
}

// ChangePercent is the change from the previous period in percent; ok is false without a previous period or
// when it was zero.
func (r Report) ChangePercent() (float64, bool) {
	if r.PreviousTotal == nil || *r.PreviousTotal <= 0 {
		return 0, false
	}
	return (r.Total - *r.PreviousTotal) / *r.PreviousTotal * 100, true
}

// date is local noon of a day key (now for a malformed key).
func date(key string) time.Time {
	if t, ok := format.DateFromKey(key); ok {
		return t
	}
	return time.Now()
}

func addDays(t time.Time, n int) time.Time { return t.AddDate(0, 0, n) }

// addMonths adds months and clamps the day to the target month's length, as Calendar.date(byAdding:) does
// (Mar 31 − 1 month = Feb 28/29, not Mar 3).
func addMonths(t time.Time, n int) time.Time {
	y, m, d := t.Date()
	first := time.Date(y, m+time.Month(n), 1, t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), t.Location())
	if last := daysIn(first); d > last {
		d = last
	}
	return time.Date(first.Year(), first.Month(), d, t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), t.Location())
}

func daysIn(t time.Time) int {
	return time.Date(t.Year(), t.Month()+1, 0, 12, 0, 0, 0, t.Location()).Day()
}

// StartDay is the first day of a range (inclusive). 1D = today; ALL = the earliest recorded day.
func StartDay(r Range, todayKey, firstKey string) string {
	today := date(todayKey)
	back := func(n int) string { return format.DayKey(addDays(today, -n)) }
	switch r {
	case RangeDay:
		return todayKey
	case RangeWeek:
		return back(6)
	case RangeMonth:
		return back(29)
	case RangeQuarter:
		return back(89)
	case RangeHalf:
		return back(181)
	case RangeYTD:
		return todayKey[:min(4, len(todayKey))] + "-01-01"
	case RangeYear:
		return back(364)
	}
	return min(firstKey, todayKey)
}

// continuous lists the days from start to end (both included), filling missing days with zero.
func continuous(start, end string, byDate map[string]DaySummary) []DaySummary {
	if start > end {
		return nil
	}
	var out []DaySummary
	endDate := date(end)
	for cursor := date(start); !cursor.After(endDate); cursor = addDays(cursor, 1) {
		key := format.DayKey(cursor)
		if d, ok := byDate[key]; ok {
			out = append(out, d)
		} else {
			out = append(out, EmptyDay(key))
		}
	}
	return out
}

func index(history []DaySummary, liveToday *DaySummary, todayKey string) map[string]DaySummary {
	byDate := make(map[string]DaySummary, len(history)+1)
	for _, d := range history {
		if _, dup := byDate[d.Date]; !dup {
			byDate[d.Date] = d
		}
	}
	if liveToday != nil {
		byDate[todayKey] = *liveToday
	}
	return byDate
}

// BuildReport builds the report of a range. history holds the (filtered) daily summaries; liveToday, when not
// nil, replaces today (it is newer than the archive).
func BuildReport(r Range, metric Metric, history []DaySummary, liveToday *DaySummary, todayKey string) Report {
	byDate := index(history, liveToday, todayKey)
	firstKey := todayKey
	for k := range byDate {
		if k < firstKey {
			firstKey = k
		}
	}
	start := StartDay(r, todayKey, firstKey)
	days := continuous(start, todayKey, byDate)

	// Previous period: the adjacent one of equal length; YTD uses the same span last year; ALL has none
	var previousDays []DaySummary
	switch r {
	case RangeAll:
	case RangeYTD:
		pEnd := format.DayKey(addMonths(date(todayKey), -12))
		previousDays = continuous(pEnd[:4]+"-01-01", pEnd, byDate)
	default:
		pEndDate := addDays(date(start), -1)
		pEnd := format.DayKey(pEndDate)
		pStart := format.DayKey(addDays(pEndDate, -(len(days) - 1)))
		previousDays = continuous(pStart, pEnd, byDate)
	}

	cumulative := func(list []DaySummary) []CumulativePoint {
		out := make([]CumulativePoint, len(list))
		acc := 0.0
		n := max(1, len(list)-1)
		for i, d := range list {
			v := metric.Value(d)
			acc += v
			pos := 1.0
			if len(list) > 1 {
				pos = float64(i) / float64(n)
			}
			out[i] = CumulativePoint{Index: i, Date: d.Date, Position: pos, Cumulative: acc, Value: v}
		}
		return out
	}
	current := cumulative(days)
	var previous []CumulativePoint
	var previousTotal *float64
	if r != RangeAll {
		previous = cumulative(previousDays)
		if len(previous) > 0 {
			t := previous[len(previous)-1].Cumulative
			previousTotal = &t
		}
	}

	// Distribution: models and tools (tokens + cost)
	modelTokens, modelCost, clientTokens := map[string]int64{}, map[string]float64{}, map[string]int64{}
	for _, d := range days {
		for m, t := range d.ByModel {
			modelTokens[m] += t
		}
		for m, c := range d.CostByModel {
			modelCost[m] += c
		}
		for c, t := range d.ByClient {
			clientTokens[c] += t
		}
	}
	models := shares(modelTokens, modelCost)
	clients := shares(clientTokens, nil)

	// Bar buckets: weekly beyond 120 days, otherwise daily
	weekly := len(days) > 120
	size := 1
	if weekly {
		size = 7
	}
	var buckets []Bucket
	for i := 0; i < len(days); i += size {
		group := days[i:min(len(days), i+size)]
		byModel := map[string]float64{}
		for _, d := range group {
			dayTotal := float64(max(1, d.Tokens))
			for m, t := range d.ByModel {
				var v float64
				switch metric {
				case MetricCost:
					v = d.CostByModel[m]
				case MetricMessages:
					v = float64(d.Messages) * float64(t) / dayTotal // messages split by token share
				default:
					v = float64(t)
				}
				if v > 0 {
					byModel[m] += v
				}
			}
		}
		buckets = append(buckets, Bucket{Start: group[0].Date, Label: group[0].Date, ByModel: byModel})
	}

	// Stat tiles
	var totalTokens int64
	var totalCost float64
	active := 0
	var peak *DaySummary
	for i := range days {
		d := days[i]
		totalTokens += d.Tokens
		totalCost += d.Cost
		if d.Tokens > 0 {
			active++
		}
		if peak == nil || d.Tokens > peak.Tokens {
			peak = &days[i]
		}
	}
	if peak != nil && peak.Tokens <= 0 {
		peak = nil
	}
	if peak != nil {
		p := *peak
		peak = &p
	}
	streak := 0
	for cursor := date(todayKey); ; cursor = addDays(cursor, -1) {
		d, ok := byDate[format.DayKey(cursor)]
		if !ok || d.Tokens <= 0 {
			break
		}
		streak++
	}
	stats := Stats{Peak: peak, ActiveDays: active, TotalDays: len(days), Streak: streak, TotalCost: totalCost}
	if len(days) > 0 {
		stats.AveragePerDay = float64(totalTokens) / float64(len(days))
	}
	if active > 0 {
		stats.AveragePerActiveDay = float64(totalTokens) / float64(active)
	}
	if totalTokens > 0 {
		stats.CostPerMillion = totalCost / (float64(totalTokens) / 1e6)
	}

	total := 0.0
	if len(current) > 0 {
		total = current[len(current)-1].Cumulative
	}
	rep := Report{
		Range: r, Metric: metric, Days: days, Current: current, Total: total,
		Models: models, Clients: clients, Buckets: buckets, WeeklyBuckets: weekly, Stats: stats,
	}
	if r != RangeAll {
		rep.PreviousDays, rep.Previous, rep.PreviousTotal = previousDays, previous, previousTotal
		if rep.PreviousDays == nil {
			rep.PreviousDays = []DaySummary{}
		}
	}
	return rep
}

// shares lists the keys with tokens, biggest first (ties by key, for a stable order).
func shares(tokens map[string]int64, cost map[string]float64) []Share {
	out := make([]Share, 0, len(tokens))
	for k, t := range tokens {
		if t > 0 {
			out = append(out, Share{Key: k, Tokens: t, Cost: cost[k]})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Tokens != out[j].Tokens {
			return out[i].Tokens > out[j].Tokens
		}
		return out[i].Key < out[j].Key
	})
	return out
}

// MonthCostDay is one day of the month's cost curve.
type MonthCostDay struct {
	Date       string
	Cost       float64
	Cumulative float64
}

// MonthCost is this month's cost: cumulative by day, projected to month end from the daily average, plus last
// month's total.
type MonthCost struct {
	Days           []MonthCostDay
	DaysInMonth    int
	Projected      float64
	LastMonthTotal float64
}

// BuildMonthCost computes the month's cost card.
func BuildMonthCost(history []DaySummary, liveToday *DaySummary, todayKey string) MonthCost {
	byDate := index(history, liveToday, todayKey)
	today := date(todayKey)
	monthStart := todayKey[:min(7, len(todayKey))] + "-01"
	span := continuous(monthStart, todayKey, byDate)
	acc := 0.0
	days := make([]MonthCostDay, len(span))
	for i, d := range span {
		acc += d.Cost
		days[i] = MonthCostDay{Date: d.Date, Cost: d.Cost, Cumulative: acc}
	}
	inMonth := daysIn(today)
	average := 0.0
	if len(span) > 0 {
		average = acc / float64(len(span))
	}
	lastStart := format.DayKey(addMonths(date(monthStart), -1))
	lastEnd := format.DayKey(addDays(date(monthStart), -1))
	lastTotal := 0.0
	for _, d := range continuous(lastStart, lastEnd, byDate) {
		lastTotal += d.Cost
	}
	return MonthCost{Days: days, DaysInMonth: inMonth, Projected: acc + average*float64(inMonth-len(span)), LastMonthTotal: lastTotal}
}
