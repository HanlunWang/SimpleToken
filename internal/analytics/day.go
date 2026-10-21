// Package analytics derives everything the dashboard shows for a time range from per-day history: cumulative
// curves against the previous period, model and tool shares, daily or weekly bars, streaks and peaks, the month's
// cost projection, the usage filter, and the squarified treemap layout. It is UI-free.
package analytics

import (
	"sort"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Day is one archived day as analytics needs it: the day's tool × model rows, unfiltered.
//
// Mapping from the daily history archive (daily-history-archive.json, schema version 1): each archive day
// becomes one Day with Date = day.date and ActiveTimeMs = day.activeTimeMs (0 when absent); each observation
// becomes one Row{Client: obs.client, Model: obs.modelId, Tokens: obs.tokens, Cost: obs.cost,
// Messages: obs.messages}. providerId and reasoningTokens are not needed. Clients may be raw tokscale names:
// Summaries normalises them with usage.NormalizeClient, as the Swift dailySummaries did.
type Day struct {
	Date         string
	ActiveTimeMs float64
	Rows         []Row
}

// Row is one tool × model observation of a day.
type Row struct {
	Client   string
	Model    string
	Tokens   int64
	Cost     float64
	Messages int64
}

// DaySummary is one day after the usage filter: the input of every report.
type DaySummary struct {
	Date         string
	Tokens       int64
	Cost         float64
	Messages     int64
	ActiveTimeMs float64
	ByModel      map[string]int64
	CostByModel  map[string]float64
	ByClient     map[string]int64
}

// EmptyDay is a day without usage (gaps in a range are filled with it).
func EmptyDay(date string) DaySummary {
	return DaySummary{Date: date, ByModel: map[string]int64{}, CostByModel: map[string]float64{}, ByClient: map[string]int64{}}
}

// Summaries folds archived days into daily summaries, oldest first: days after todayKey are dropped, and only the
// last capDays days are kept when capDays > 0 (0 = all history; the ALL range needs it). Models / tools the
// filter excludes count toward no field.
func Summaries(days []Day, todayKey string, filter Filter, capDays int) []DaySummary {
	list := make([]Day, 0, len(days))
	for _, d := range days {
		if d.Date <= todayKey {
			list = append(list, d)
		}
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].Date < list[j].Date })
	if capDays > 0 && len(list) > capDays {
		list = list[len(list)-capDays:]
	}
	out := make([]DaySummary, 0, len(list))
	for _, d := range list {
		s := EmptyDay(d.Date)
		s.ActiveTimeMs = d.ActiveTimeMs
		for _, r := range d.Rows {
			client := usage.NormalizeClient(r.Client, r.Model)
			if !filter.Includes(client, r.Model) {
				continue
			}
			s.Tokens += r.Tokens
			s.Cost += r.Cost
			s.Messages += r.Messages
			s.ByModel[r.Model] += r.Tokens
			s.CostByModel[r.Model] += r.Cost
			s.ByClient[client] += r.Tokens
		}
		out = append(out, s)
	}
	return out
}

// LiveDay builds a daily summary from the live today period; it replaces the older today of the archive. Pass
// the period through Filter.Apply first so the live day honours the filter like the archived ones.
func LiveDay(p usage.Period, dayKey string) DaySummary {
	s := EmptyDay(dayKey)
	s.Tokens, s.Cost, s.Messages = p.TotalTokens, p.CostUSD, p.Messages
	for m, v := range p.ByModel {
		s.ByModel[m] = v.Tokens
		s.CostByModel[m] = v.CostUSD
	}
	for c, v := range p.ByClient {
		s.ByClient[c] = v.Tokens
	}
	return s
}
