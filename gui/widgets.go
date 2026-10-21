package gui

import (
	"math"
	"slices"
	"sort"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
)

// Widgets: each card has its allowed sizes (S 1×1, M 2×1, L 2×2, W 4×2) and a distinct layout per size.
// Anatomy: a header (▪ CAPTION + note), the defining number in the dot face, one visual, a facts line.

type cardSize string

const (
	sizeS cardSize = "S"
	sizeM cardSize = "M"
	sizeL cardSize = "L"
	sizeW cardSize = "W"
)

func (s cardSize) span() (int, int) {
	switch s {
	case sizeM:
		return 2, 1
	case sizeL:
		return 2, 2
	case sizeW:
		return 4, 2
	}
	return 1, 1
}

type cardDef struct {
	Title string
	Sizes []cardSize
	Def   cardSize
	Stat  bool
}

var cardDefs = map[string]cardDef{
	"hero":            {"Main chart", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"stat.average":    {"Daily average", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.peak":       {"Peak day", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.active":     {"Active days", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.perMillion": {"Per million tokens", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.totalCost":  {"Total cost", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.messages":   {"Message count", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.topModel":   {"Top model", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.weekday":    {"Busiest weekday", []cardSize{sizeS, sizeM}, sizeS, true},
	"limits":          {"Limits", []cardSize{sizeS, sizeM, sizeL}, sizeL, false},
	"models":          {"Models", []cardSize{sizeS, sizeM, sizeL}, sizeL, false},
	"map":             {"Usage map", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"flow":            {"Flow", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"usage":           {"Usage chart", []cardSize{sizeM, sizeL, sizeW}, sizeW, false},
	"calendar":        {"Calendar", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"punchcard":       {"Time of day", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"tools":           {"Tools", []cardSize{sizeS, sizeM, sizeL}, sizeM, false},
	"composition":     {"Token breakdown", []cardSize{sizeS, sizeM, sizeL}, sizeM, false},
	"cost":            {"This month's cost", []cardSize{sizeS, sizeM, sizeL, sizeW}, sizeW, false},
}

// Per-card accents (Settings: card colour). Ink and signal follow the palette; the others are the validated
// accents of 0.1.x.
var accentOptions = [][2]string{{"ink", "Ink"}, {"sig", "Signal"}, {"blue", "Blue"}, {"green", "Green"}, {"rose", "Rose"}, {"terra", "Terracotta"}}

func (a *ctrl) accent(p palette, id string) ui.Color {
	switch a.m.s.CardAccents[id] {
	case "sig":
		return p.Sig
	case "blue":
		return ui.Hex("#6f9fd8")
	case "green":
		return ui.Hex("#5fb07f")
	case "rose":
		return ui.Hex("#c47f9f")
	case "terra":
		return ui.Hex("#c17755")
	}
	return p.T1
}

func (a *ctrl) cardSize(id string) cardSize {
	def := cardDefs[id]
	if s := cardSize(a.m.s.CardSizes[id]); slices.Contains(def.Sizes, s) {
		return s
	}
	return def.Def
}

// cardNote is the faint note beside a card's title.
func (a *ctrl) cardNote(id string, rep analytics.Report) string {
	switch id {
	case "hero", "map":
		return fmtr.L(rep.Range.Label())
	case "limits":
		return L("Marker = even pace")
	case "models":
		return L("%lld models", len(rep.Models))
	case "flow":
		return L("%@ · %lld tools", fmtr.L(rep.Range.Label()), len(rep.Clients))
	case "usage":
		return pick(rep.WeeklyBuckets, L("Weekly"), L("Daily"))
	case "punchcard":
		return "Claude Code"
	case "tools":
		return L("%lld tools", len(rep.Clients))
	case "cost":
		return L("Month to date")
	}
	return ""
}

// ── Shared anatomy ──

// facts is the bottom row of large cards: value over a mono caption, hairline separated.
func (p palette) facts(c *ui.Context, items [][2]string) {
	ui.Row(c.Key("facts")).FillWidth().Margin(10, 0, 0).Padding(9, 0, 0).Children(func() {
		ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
		for i, it := range items {
			ui.Column(c.Key(i)).Grow(1).Basis(0).MinWidth(0).Gap(3).Padding(0, 0, 0, pick(i > 0, float32(12), 0)).Children(func() {
				if i > 0 {
					ui.Box(c).Absolute().Left(0).Top(0).Width(1).FillHeight().Background(p.L2)
				}
				ui.Text(c, it[0]).Font(monoFont).FontSize(13).FontWeight(500).TextColor(p.T1).SingleLine().Ellipsis("…")
				ui.Text(c, upper(it[1])).Font(monoFont).FontSize(9.5).LetterSpacing(0.7).TextColor(p.T3).SingleLine().Ellipsis("…")
			})
		}
	})
}

// metricNum is a metric's defining number: money, messages, or tokens split into value and unit.
func (a *ctrl) metricNum(c *ui.Context, p palette, key string, metric analytics.Metric, v float64, size float32) {
	switch metric {
	case analytics.MetricCost:
		p.money(c, key, v, size)
	case analytics.MetricMessages:
		p.bigNum(c, key, format.Grouped(int64(math.Round(v))), L("msgs"), size, p.T1)
	default:
		if a.m.s.ExactNumbers {
			p.bigNum(c, key, format.Grouped(int64(math.Round(v))), "", size*0.62, p.T1)
			return
		}
		val, unit := splitNum(fmtr.Short(v))
		p.bigNum(c, key, val, unit, size, p.T1)
	}
}

func (p palette) empty(c *ui.Context, text string) {
	ui.Column(c.Key("empty")).Grow(1).FillWidth().AlignItems(ui.Center).Justify(ui.Center).Gap(8).Children(func() {
		ui.Box(c).Size(30, 20).Draw(func(pt *ui.Painter, r ui.Rect) {
			for i := range 7 {
				for j := range 5 {
					if (i == 0 || i == 6 || j == 0 || j == 4) && (i+j)%2 == 0 {
						pt.Fill(ui.Rect{X: r.X + float32(i)*4.5, Y: r.Y + float32(j)*4.5, W: 3, H: 3}, p.DotOff, 1.5)
					}
				}
			}
		})
		p.mono(c, text, 11, p.T3)
	})
}

// dayTip is the shared tooltip of a day: tokens, cost, messages, then its top models.
func (a *ctrl) dayTip(p palette, d analytics.DaySummary) (string, []tipRow) {
	rows := []tipRow{
		{Label: L("Tokens"), Value: a.m.num(float64(d.Tokens))},
		{Label: L("Cost"), Value: format.Money(d.Cost)},
		{Label: L("Messages"), Value: format.Grouped(d.Messages)},
	}
	keys := sortedKeys(d.ByModel)
	if len(keys) > 0 {
		rows = append(rows, tipRow{})
	}
	for _, k := range keys[:min(4, len(keys))] {
		v := vendorOf(k)
		rows = append(rows, tipRow{Color: a.m.modelColor(p, k), Logo: vendorLogo(v), LogoC: a.m.vendorTint(p, v), Label: a.m.modelName(k), Value: shortNum(float64(d.ByModel[k])), Dim: true})
	}
	return upper(format.LongDate(d.Date)), rows
}

func dayLabel(rep analytics.Report) func(int) string {
	return func(i int) string {
		if i < 0 || i >= len(rep.Days) {
			return ""
		}
		return format.ShortDate(rep.Days[i].Date)
	}
}

func metricValues(rep analytics.Report) []float64 {
	out := make([]float64, len(rep.Days))
	for i, d := range rep.Days {
		out[i] = rep.Metric.Value(d)
	}
	return out
}

// ── Main chart ──

func (a *ctrl) heroCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	acc := a.accent(p, "hero")
	one := rep.Range == analytics.RangeDay
	prev := 0.0
	if rep.PreviousTotal != nil {
		prev = *rep.PreviousTotal
	}
	ui.Row(c.Key("num")).FillWidth().Gap(12).AlignItems(ui.End).Children(func() {
		a.metricNum(c, p, "n", rep.Metric, rep.Total, pick(size == sizeM, float32(30), 40))
		if m.s.HeroShowPrevious && prev > 0 {
			label := L("vs previous period %@", m.metricText(rep.Metric, prev))
			if one {
				label = L("vs. yesterday")
			}
			a.delta(c, p, rep.Total, prev, label)
		}
		if size == sizeW {
			ui.Box(c).Grow(1)
			ui.Row(c).Gap(14).AlignItems(ui.Center).Children(func() {
				ui.Box(c).Size(14, 2).Background(acc)
				p.mono(c, L("This period"), 10.5, p.T3)
				ui.Box(c).Size(14, 2).Draw(func(pt *ui.Painter, r ui.Rect) { dashH(pt, r.X, r.X+r.W, r.Y+1, p.T3, 3, 2) })
				p.mono(c, L("Previous period"), 10.5, p.T3)
			})
		}
	})
	ui.Box(c).Height(12)
	if one {
		a.intradayArea(c, p, size != sizeM, acc)
	} else {
		var compare []float64
		if m.s.HeroShowPrevious {
			compare = make([]float64, len(rep.PreviousDays))
			for i, d := range rep.PreviousDays {
				compare[i] = rep.Metric.Value(d)
			}
		}
		p.areaChart(c, "area", areaOpts{
			Values: metricValues(rep), Compare: compare, Axes: size != sizeM, Columns: size != sizeM, Color: acc,
			Labels: pick(size != sizeM, dayLabel(rep), nil), Tick: a.tick(rep.Metric),
			Tip: func(i int, cum float64) (string, []tipRow) {
				t, rows := a.dayTip(p, rep.Days[i])
				return t, append(rows, tipRow{}, tipRow{Label: L("Cumulative"), Value: m.metricText(rep.Metric, cum)})
			},
		})
	}
	if size != sizeM {
		st := rep.Stats
		peak := [2]string{"—", L("Peak")}
		if st.Peak != nil {
			peak = [2]string{m.metricText(rep.Metric, rep.Metric.Value(*st.Peak)), L("Peak · %@", format.ShortDate(st.Peak.Date))}
		}
		last := [2]string{format.Money(st.TotalCost), L("Cost")}
		if rep.Metric == analytics.MetricCost {
			last = [2]string{m.num(float64(sumTokens(rep))), L("Tokens")}
		}
		p.facts(c, [][2]string{{m.metricText(rep.Metric, st.AveragePerDay), L("Daily avg")}, peak, {itoa(st.ActiveDays) + " / " + itoa(st.TotalDays), L("Active days")}, last})
	}
}

func sumTokens(rep analytics.Report) int64 {
	var t int64
	for _, d := range rep.Days {
		t += d.Tokens
	}
	return t
}

func (a *ctrl) tick(metric analytics.Metric) func(float64) string {
	return func(v float64) string {
		if metric == analytics.MetricCost {
			return "$" + shortNum(v)
		}
		return shortNum(v)
	}
}

// intradayArea is today's cumulative half-hour curve against yesterday's (Claude Code).
func (a *ctrl) intradayArea(c *ui.Context, p palette, axes bool, col ui.Color) {
	m := a.m
	now := m.now()
	slot := now.Hour()*2 + now.Minute()/30
	today := m.todayHalf()[:slot+1]
	p.areaChart(c, "intraday", areaOpts{
		Values: today, Compare: m.yesterdayHalf(), ProjectTo: 48, Axes: axes, Columns: false, Color: col, Tick: shortNum,
		Labels: func(i int) string {
			switch i {
			case 0:
				return "0h"
			case 47:
				return "24h"
			}
			return "12"
		},
		Tip: func(i int, cum float64) (string, []tipRow) {
			return pad2(i/2) + ":" + pick(i%2 == 1, "30", "00"), []tipRow{{Color: col, Label: L("Today"), Value: shortNum(cum)}}
		},
	})
}

// ── Stat tiles ──

func (a *ctrl) statCard(c *ui.Context, p palette, id string, size cardSize, rep0 analytics.Report) {
	m := a.m
	rep := rep0
	if rep.Range == analytics.RangeDay {
		rep = m.report(analytics.RangeWeek, rep0.Metric)
	}
	acc := a.accent(p, id)
	vals := metricValues(rep)
	last30 := vals[max(0, len(vals)-30):]
	numSize := pick(size == sizeS, float32(28), 32)
	chartH := pick(size == sizeS, float32(36), 54)
	var num, chart func()
	sub, deltaLabel := "", ""
	var deltaNow, deltaPrev float64
	switch id {
	case "stat.average":
		num = func() { a.metricNum(c, p, "n", rep.Metric, rep.Stats.AveragePerDay, numSize) }
		sub = L("Active-day avg %@", m.metricText(rep.Metric, rep.Stats.AveragePerActiveDay))
		chart = func() {
			p.sparkBars(c, "c", last30, sparkOpts{Emph: len(last30) - 1, Rule: rep.Stats.AveragePerDay, Height: chartH, Color: acc})
		}
		if rep.PreviousTotal != nil && len(rep.Days) > 0 {
			deltaNow, deltaPrev, deltaLabel = rep.Stats.AveragePerDay, *rep.PreviousTotal/float64(len(rep.Days)), L("vs previous period")
		}
	case "stat.peak":
		days := slices.Clone(rep.Days)
		sort.SliceStable(days, func(i, j int) bool { return rep.Metric.Value(days[i]) > rep.Metric.Value(days[j]) })
		top := days[:min(3, len(days))]
		if len(top) == 0 {
			p.empty(c, L("No usage in this range"))
			return
		}
		pv := rep.Metric.Value(top[0])
		num = func() { a.metricNum(c, p, "n", rep.Metric, pv, numSize) }
		sub = L("%@ · %@× daily avg", format.ShortDate(top[0].Date), ftoa(pv/math.Max(1e-9, rep.Stats.AveragePerDay), 1))
		chart = func() {
			ui.Column(c.Key("peaks")).FillWidth().Gap(4).Children(func() {
				for i, d := range top {
					v := rep.Metric.Value(d)
					ui.Row(c.Key(i)).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
						ui.Text(c, format.ShortDate(d.Date)).Font(monoFont).FontSize(10).TextColor(p.T4).Width(44).SingleLine()
						ui.Box(c).Grow(1).Height(4).Radius(2).Background(p.L2).Draw(func(pt *ui.Painter, r ui.Rect) {
							pt.Fill(ui.Rect{X: r.X, Y: r.Y, W: r.W * float32(v/pv), H: r.H}, pick(i == 0, acc, p.T3), 2)
						})
						ui.Text(c, shortNum(v)).Font(monoFont).FontSize(10.5).TextColor(p.T2).Width(40).TextAlign(ui.End).SingleLine()
					})
				}
			})
		}
	case "stat.active":
		num = func() {
			p.bigNum(c, "n", itoa(rep.Stats.ActiveDays)+"/"+itoa(rep.Stats.TotalDays), "", numSize-2, p.T1)
		}
		sub = L("Streak %lld d · longest %lld d", rep.Stats.Streak, longestStreak(rep.Days))
		chart = func() { a.dayStrip(c, p, acc, pick(size == sizeS, 21, 22)) }
	case "stat.perMillion":
		num = func() { p.money(c, "n", rep.Stats.CostPerMillion, numSize) }
		sub = L("Total %@", format.Money(rep.Stats.TotalCost))
		rates := make([]float64, 0, 30)
		for _, d := range rep.Days[max(0, len(rep.Days)-30):] {
			if d.Tokens > 0 {
				rates = append(rates, d.Cost/(float64(d.Tokens)/1e6))
			}
		}
		chart = func() { p.sparkLine(c, "c", rates, chartH, acc, true, true) }
	case "stat.totalCost":
		num = func() { p.money(c, "n", rep.Stats.TotalCost, numSize-2) }
		sub = L("Daily avg %@", format.Money(rep.Stats.TotalCost/math.Max(1, float64(len(rep.Days)))))
		costs := make([]float64, 0, 30)
		for _, d := range rep.Days[max(0, len(rep.Days)-30):] {
			costs = append(costs, d.Cost)
		}
		chart = func() { p.sparkBars(c, "c", costs, sparkOpts{Emph: len(costs) - 1, Height: chartH, Color: acc}) }
	case "stat.messages":
		var msgs int64
		series := make([]float64, 0, 30)
		var toks int64
		for _, d := range rep.Days {
			msgs += d.Messages
			toks += d.Tokens
		}
		for _, d := range rep.Days[max(0, len(rep.Days)-30):] {
			series = append(series, float64(d.Messages))
		}
		num = func() { p.bigNum(c, "n", format.Grouped(msgs), "", numSize-2, p.T1) }
		sub = L("%@ tokens / message", shortNum(float64(toks)/math.Max(1, float64(msgs))))
		chart = func() { p.sparkLine(c, "c", series, chartH, acc, true, true) }
	case "stat.topModel":
		if len(rep.Models) == 0 {
			p.empty(c, L("No usage in this range"))
			return
		}
		total := 0.0
		for _, s := range rep.Models {
			total += float64(s.Tokens)
		}
		top := rep.Models[0]
		num = func() {
			ui.Row(c.Key("n")).Gap(8).AlignItems(ui.Center).Children(func() {
				v := vendorOf(top.Key)
				logo(c, vendorLogo(v), 20, m.vendorTint(p, v))
				ui.Text(c, m.modelName(top.Key)).Font(monoFont).FontSize(pick(size == sizeS, float32(16), 19)).FontWeight(500).TextColor(p.T1).SingleLine().Ellipsis("…")
			})
		}
		sub = L("%@ share · %lld models", itoa(int(math.Round(float64(top.Tokens)/total*100)))+"%", len(rep.Models))
		chart = func() {
			parts := []part{}
			for _, s := range rep.Models[:min(6, len(rep.Models))] {
				parts = append(parts, part{ID: s.Key, V: float64(s.Tokens), Color: m.modelColor(p, s.Key)})
			}
			p.segmentBar(c, "seg", parts, 7, "")
		}
	case "stat.weekday":
		var sums, cnt [7]float64
		for _, d := range rep.Days {
			if t, ok := format.DateFromKey(d.Date); ok {
				w := format.WeekdayIndex(t)
				sums[w] += rep.Metric.Value(d)
				cnt[w]++
			}
		}
		avg := make([]float64, 7)
		best := 0
		for i := range 7 {
			avg[i] = sums[i] / math.Max(1, cnt[i])
			if avg[i] > avg[best] {
				best = i
			}
		}
		num = func() { p.bigNum(c, "n", L(format.WeekdaysFromMonday[best]), "", numSize, p.T1) }
		sub = L("%@ · avg per day", m.metricText(rep.Metric, avg[best]))
		chart = func() {
			p.sparkBars(c, "c", avg, sparkOpts{Emph: best, Height: chartH - 10, Color: p.T3, Labels: format.WeekdayInitialsFromMonday})
		}
	}
	if size == sizeS {
		ui.Column(c.Key("top")).FillWidth().Gap(6).Children(func() {
			num()
			p.mono(c, sub, 10.5, p.T3).Ellipsis("…")
		})
		ui.Box(c).Grow(1)
		chart()
		return
	}
	ui.Row(c.Key("m")).FillWidth().Grow(1).Gap(18).AlignItems(ui.End).Children(func() {
		ui.Column(c.Key("l")).Grow(1).Basis(0).FillHeight().Justify(ui.SpaceBetween).Children(func() {
			num()
			ui.Column(c).Gap(6).Children(func() {
				p.mono(c, sub, 10.5, p.T3)
				if deltaPrev > 0 {
					a.delta(c, p, deltaNow, deltaPrev, deltaLabel)
				} else {
					p.mono(c, fmtr.L(rep.Range.Label()), 10.5, p.T4)
				}
			})
		})
		ui.Column(c.Key("r")).Grow(1.15).Basis(0).Children(chart)
	})
}

func longestStreak(days []analytics.DaySummary) int {
	best, run := 0, 0
	for _, d := range days {
		if d.Tokens > 0 {
			run++
			best = max(best, run)
		} else {
			run = 0
		}
	}
	return best
}

// dayStrip is the active-days dot grid: weekly columns of the last weeks, today in the signal colour.
func (a *ctrl) dayStrip(c *ui.Context, p palette, col ui.Color, weeks int) {
	days := a.m.days(weeks * 7)
	ui.Box(c.Key("strip")).FillWidth().Height(7*6 + 6*3).Draw(func(pt *ui.Painter, r ui.Rect) {
		const d, g = 6, 3
		for i, day := range days {
			x := r.X + float32(i/7)*(d+g)
			y := r.Y + float32(i%7)*(d+g)
			dot := ui.Rect{X: x, Y: y, W: d, H: d}
			switch {
			case i == len(days)-1:
				pt.Shadow(dot, d/2, 0, 0, 4, 0, p.glow())
				pt.Fill(dot, p.Sig, d/2)
			case day.Tokens > 0:
				pt.Fill(dot, col, d/2)
			default:
				pt.Fill(dot, p.DotOff, d/2)
			}
		}
	})
}

// ── Limits ──

func (a *ctrl) limitsCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	var shown []limits.Entry
	for _, e := range m.d.Limits {
		if !slices.Contains(m.s.HiddenLimitProviders, string(e.Provider)) {
			shown = append(shown, e)
		}
	}
	if len(shown) == 0 {
		p.empty(c, L("All providers hidden"))
		return
	}
	windows := func(e limits.Entry) []limits.Window {
		if e.Snapshot == nil {
			return nil
		}
		return slices.DeleteFunc(slices.Clone(e.Snapshot.Windows), func(w limits.Window) bool {
			return w.Kind == limits.Model && !m.s.LimitShowModelBuckets
		})
	}
	switch size {
	case sizeS:
		e := shown[0]
		ws := windows(e)
		if len(ws) == 0 {
			p.empty(c, a.statusText(e))
			return
		}
		ws = ws[:min(2, len(ws))]
		items := []ringItem{}
		for _, w := range ws {
			used, pace, hot, _ := a.limitView(w)
			items = append(items, ringItem{Used: used, Pace: pace, Hot: hot})
		}
		ui.Row(c.Key("s")).Grow(1).FillWidth().Gap(12).AlignItems(ui.Center).Children(func() {
			p.rings(c, "rings", items, 86, 7)
			ui.Column(c).Gap(8).Children(func() {
				for i, w := range ws {
					used, _, hot, reset := a.limitView(w)
					ui.Column(c.Key(i)).Gap(1).Children(func() {
						ui.Row(c).AlignItems(ui.End).Gap(2).Children(func() {
							ui.Text(c, itoa(int(used+0.5))).Font(dotFont).FontSize(20).TextColor(pick(hot, p.Sig, p.T1)).SingleLine()
							p.mono(c, "% "+pick(w.Kind == limits.Session, "5h", L("wk")), 10, p.T3)
						})
						if reset != "" {
							p.mono(c, "↻ "+reset, 9.5, p.T4)
						}
					})
				}
			})
		})
	case sizeM:
		ui.Column(c.Key("m")).FillWidth().Gap(7).Children(func() {
			n := 0
			for _, e := range shown {
				for _, w := range windows(e) {
					if n >= 5 {
						return
					}
					n++
					used, pace, hot, reset := a.limitView(w)
					ui.Row(c.Key(string(e.Provider) + w.ID())).FillWidth().Gap(9).AlignItems(ui.Center).Children(func() {
						logo(c, vendorLogo(string(e.Provider)), 14, m.vendorTint(p, string(e.Provider)))
						ui.Text(c, e.Provider.DisplayName()+" "+windowLabel(w)).Font(monoFont).FontSize(11).TextColor(p.T2).Width(104).SingleLine().Ellipsis("…")
						p.paceMeter(c, "pm", used, pace, hot, 22, m.s.LimitShowPace)
						ui.Text(c, itoa(int(used+0.5))+"%").Font(monoFont).FontSize(12).TextColor(pick(hot, p.Sig, p.T1)).Width(36).TextAlign(ui.End).SingleLine()
						ui.Text(c, reset).Font(monoFont).FontSize(10).TextColor(p.T4).Width(50).TextAlign(ui.End).SingleLine()
					})
				}
			}
		})
	default:
		var next *limits.Window
		var behind float64
		haveBehind := false
		ui.Column(c.Key("l")).FillWidth().Grow(1).Justify(ui.SpaceBetween).Children(func() {
			for _, e := range shown {
				ui.Row(c.Key(string(e.Provider))).FillWidth().Gap(10).AlignItems(ui.Center).Padding(0, 0, 4).Children(func() {
					ui.Column(c.Key("id")).Width(104).Gap(4).Children(func() {
						ui.Row(c).Gap(7).AlignItems(ui.Center).Children(func() {
							logo(c, vendorLogo(string(e.Provider)), 16, m.vendorTint(p, string(e.Provider)))
							ui.Text(c, e.Provider.DisplayName()).FontSize(12.5).FontWeight(500).TextColor(p.T1).SingleLine()
						})
						if e.Snapshot != nil {
							p.mono(c, e.Snapshot.AccountLabel, 10, p.T3).Ellipsis("…")
						}
						p.mono(c, a.statusText(e), 9.5, p.T4).Ellipsis("…")
					})
					ui.Row(c.Key("g")).Grow(1).Justify(ui.SpaceAround).Children(func() {
						ws := windows(e)
						if len(ws) == 0 {
							p.mono(c, a.statusText(e), 11, p.T3)
						}
						for i, w := range ws[:min(3, len(ws))] {
							used, pace, hot, reset := a.limitView(w)
							sub := ""
							if reset != "" {
								sub = "↻ " + reset
							}
							p.dotGauge(c, itoa(i), used, pace, hot, 70, upper(windowLabel(w)), sub, m.s.LimitShowPace)
							if w.ResetsAt != nil && (next == nil || w.ResetsAt.Before(*next.ResetsAt)) {
								ww := w
								next = &ww
							}
							if w.Kind == limits.Weekly && !haveBehind {
								behind, haveBehind = pace*100-w.UsedPercent, true
							}
						}
					})
				})
			}
		})
		nextText, paceText := "—", "—"
		if next != nil {
			nextText = format.Clock(*next.ResetsAt)
		}
		if haveBehind {
			paceText = pick(behind >= 0, L("%@ behind", ftoa(math.Abs(behind), 0)+"%"), L("%@ ahead", ftoa(math.Abs(behind), 0)+"%"))
		}
		n := 0
		for _, e := range shown {
			n += len(windows(e))
		}
		p.facts(c, [][2]string{{nextText, L("Next reset")}, {paceText, L("Even pace")}, {itoa(n), L("Windows")}})
	}
}

// ── Models ──

func (a *ctrl) modelsCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	byCost := m.s.ModelsMetric == "cost"
	vals := map[string]float64{}
	for _, s := range rep.Models {
		vals[s.Key] = pick(byCost, s.Cost, float64(s.Tokens))
	}
	keys := sortedKeys(vals)
	if len(keys) == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	total := 0.0
	for _, v := range vals {
		total += v
	}
	pct := func(v float64) string { return itoa(int(math.Round(v/total*100))) + "%" }
	parts := make([]part, len(keys))
	for i, k := range keys {
		parts[i] = part{ID: k, V: vals[k], Color: m.modelColor(p, k)}
		if m.s.SeriesColors != "vendor" && m.s.VendorMarks != "mono" {
			parts[i].Band = m.vendorTint(p, vendorOf(k))
		}
	}
	if size == sizeS {
		ui.Column(c.Key("s")).FillWidth().Gap(6).Children(func() {
			p.bigNum(c, "n", itoa(int(math.Round(vals[keys[0]]/total*100))), "%", 28, p.T1)
			ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				logo(c, vendorLogo(vendorOf(keys[0])), 12, m.vendorTint(p, vendorOf(keys[0])))
				p.mono(c, m.modelName(keys[0]), 11, p.T2).Ellipsis("…")
			})
		})
		ui.Box(c).Grow(1)
		p.segmentBar(c, "seg", parts, 7, "")
		ui.Box(c).Height(6)
		p.mono(c, L("%lld models", len(keys)), 10, p.T4)
		return
	}
	focus := a.w.focus["models"]
	if size == sizeL {
		ui.Row(c.Key("n")).FillWidth().Gap(10).AlignItems(ui.End).Margin(0, 0, 10).Children(func() {
			a.metricNum(c, p, "t", pick(byCost, analytics.MetricCost, analytics.MetricTokens), total, 34)
			p.mono(c, L("%@ · Colored by last 30 days' usage", fmtr.L(rep.Range.Label())), 10.5, p.T3).Ellipsis("…")
		})
	}
	var hover string
	ui.Row(c.Key("body")).FillWidth().Grow(1).Gap(16).AlignItems(ui.Center).Children(func() {
		dsize := pick(size == sizeM, float32(100), 136)
		_, hover = p.donut(c, "donut", parts, dsize, pick(size == sizeM, float32(9), 11), &focus, func(h string) {
			cur := keys[0]
			if focus != "" {
				cur = focus
			}
			if h != "" {
				cur = h
			}
			ui.Row(c).AlignItems(ui.End).Children(func() {
				ui.Text(c, itoa(int(math.Round(vals[cur]/total*100)))).Font(dotFont).FontSize(pick(size == sizeM, float32(20), 26)).TextColor(p.T1).SingleLine()
				p.mono(c, "%", 10, p.T3)
			})
			p.mono(c, m.modelName(cur), 9.5, p.T3).MaxWidth(dsize - 30).Ellipsis("…")
		})
		ui.Column(c.Key("rows")).Grow(1).Basis(0).MinWidth(0).Gap(1).Children(func() {
			n := pick(size == sizeM, 4, 6)
			for _, k := range keys[:min(n, len(keys))] {
				v := vendorOf(k)
				dim := (focus != "" && focus != k) || (hover != "" && hover != k)
				ui.Row(c.Key(k)).FillWidth().Height(24).Gap(8).AlignItems(ui.Center).Opacity(pick(dim, float32(0.35), 1)).Children(func() {
					swatch(c, m.modelColor(p, k), 7)
					logo(c, vendorLogo(v), 11, m.vendorTint(p, v))
					ui.Text(c, m.modelName(k)).Font(monoFont).FontSize(11.5).TextColor(p.T1).SingleLine().Grow(1).MinWidth(0).Ellipsis("…")
					if size == sizeL && m.s.ModelsShowSparklines {
						series := make([]float64, 0, 14)
						for _, d := range rep.Days[max(0, len(rep.Days)-14):] {
							series = append(series, float64(d.ByModel[k]))
						}
						ui.Box(c).Width(64).Children(func() { p.sparkLine(c, "sp", series, 14, m.modelColor(p, k), false, false) })
					}
					ui.Text(c, pick(byCost, format.Money(vals[k]), shortNum(vals[k]))).Font(monoFont).FontSize(11).TextColor(p.T2).Width(48).TextAlign(ui.End).SingleLine()
					ui.Text(c, pct(vals[k])).Font(monoFont).FontSize(11).TextColor(p.T4).Width(34).TextAlign(ui.End).SingleLine()
				})
			}
		})
	})
	a.w.focus["models"] = focus
	if size == sizeL {
		p.facts(c, [][2]string{{itoa(len(keys)), L("Models")}, {pct(vals[keys[0]]), L("Top share")}, {format.Money(rep.Stats.CostPerMillion), L("Per 1M tokens")}})
	}
}

// ── Usage map and flow ──

func (a *ctrl) mapCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	groups := map[string]*tmGroup{}
	total := 0.0
	for _, s := range rep.Models {
		v := vendorOf(s.Key)
		g := groups[v]
		if g == nil {
			g = &tmGroup{ID: v, Logo: vendorLogo(v)}
			if m.s.SeriesColors != "vendor" && m.s.VendorMarks != "mono" {
				g.Band = m.vendorTint(p, v)
			}
			groups[v] = g
		}
		g.Items = append(g.Items, part{ID: s.Key, V: float64(s.Tokens), Color: m.modelColor(p, s.Key)})
		total += float64(s.Tokens)
	}
	if total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	var gs []tmGroup
	for _, g := range groups {
		gs = append(gs, *g)
	}
	sort.Slice(gs, func(i, j int) bool { return gs[i].ID < gs[j].ID })
	p.treemap(c, "map", gs, func(cl tmCell) (string, []tipRow) {
		v := vendorOf(cl.ID)
		return upper(vendorName(v)), []tipRow{
			{Color: cl.Color, Logo: vendorLogo(v), LogoC: m.vendorTint(p, v), Label: m.modelName(cl.ID), Value: m.num(cl.V)},
			{Label: L("Share"), Value: ftoa(cl.V/total*100, 1) + "%"},
		}
	})
	if size != sizeM {
		top := rep.Models[0]
		p.facts(c, [][2]string{{itoa(len(rep.Models)), L("Models")}, {itoa(len(groups)), L("Vendors")}, {itoa(int(math.Round(float64(top.Tokens)/total*100))) + "%", m.modelName(top.Key)}})
	}
}

func vendorName(v string) string {
	switch v {
	case "anthropic":
		return "Anthropic"
	case "openai":
		return "OpenAI"
	case "google":
		return "Google"
	case "xai":
		return "xAI"
	}
	return L("Other")
}

func (a *ctrl) flowCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	pairs := m.pairs(rep)
	total := 0.0
	toolV := map[string]float64{}
	modelV := map[string]float64{}
	for k, v := range pairs {
		total += v
		toolV[k[0]] += v
		modelV[k[1]] += v
	}
	if total == 0 {
		p.empty(c, L("No tool and model breakdown in this range"))
		return
	}
	top := []string{}
	for _, md := range m.ranking() {
		if modelV[md] > 0 && len(top) < 5 {
			top = append(top, md)
		}
	}
	var flows []flow
	merged := map[[2]string]float64{}
	for k, v := range pairs {
		to := k[1]
		if !slices.Contains(top, to) {
			to = "other"
		}
		merged[[2]string{k[0], to}] += v
	}
	for k, v := range merged {
		flows = append(flows, flow{From: k[0], To: k[1], V: v})
	}
	var left []sankeyNode
	for _, t := range sortedKeys(toolV) {
		left = append(left, sankeyNode{ID: t, Label: toolName(t), Color: p.T1})
	}
	var right []sankeyNode
	hasOther := false
	for _, f := range flows {
		hasOther = hasOther || f.To == "other"
	}
	for _, md := range top {
		col := m.modelColor(p, md)
		if m.s.SeriesColors != "vendor" && m.s.VendorMarks != "mono" {
			col = m.vendorTint(p, vendorOf(md))
		}
		right = append(right, sankeyNode{ID: md, Label: m.modelName(md), Color: col})
	}
	if hasOther {
		right = append(right, sankeyNode{ID: "other", Label: L("Other"), Color: p.T3})
	}
	linkCol := func(to string) ui.Color {
		if to == "other" {
			return pick(m.s.SeriesColors == "vendor", p.Vendor.Other, p.Ink[3])
		}
		return m.modelColor(p, to)
	}
	p.sankey(c, "flow", left, right, flows, linkCol, func(f flow) (string, []tipRow) {
		return upper(toolName(f.From) + " → " + pick(f.To == "other", L("Other"), m.modelName(f.To))), []tipRow{
			{Color: linkCol(f.To), Label: L("Tokens"), Value: m.num(f.V)},
			{Label: L("Share"), Value: ftoa(f.V/total*100, 1) + "%"},
		}
	})
	if size != sizeM {
		var big flow
		for _, f := range flows {
			if f.V > big.V {
				big = f
			}
		}
		p.facts(c, [][2]string{{itoa(len(toolV)), L("Tools")}, {itoa(len(modelV)), L("Models")}, {itoa(int(math.Round(big.V/total*100))) + "%", toolName(big.From) + " → " + pick(big.To == "other", L("Other"), m.modelName(big.To))}})
	}
}

// ── Usage chart ──

func (a *ctrl) usageCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	stack := m.s.UsageStack
	acc := a.accent(p, "usage")
	focus := a.w.focus["usage"]
	var keys []seriesKey
	rank := m.ranking()
	sep := max(2, min(8, m.s.SeparateModels))
	switch stack {
	case "tool":
		for _, s := range rep.Clients {
			keys = append(keys, seriesKey{ID: s.Key, Color: m.toolColor(p, s.Key)})
		}
	case "none":
		keys = []seriesKey{{ID: "all", Color: acc}}
	default:
		for _, md := range rank[:min(sep, len(rank))] {
			keys = append(keys, seriesKey{ID: md, Color: m.modelColor(p, md)})
		}
		keys = append(keys, seriesKey{ID: "other", Color: pick(m.s.SeriesColors == "vendor", p.Vendor.Other, p.Ink[3])})
	}
	days := rep.Days
	if rep.Range == analytics.RangeDay {
		days = m.days(7)
	}
	type bucket struct {
		label string
		days  []analytics.DaySummary
	}
	var buckets []bucket
	if rep.WeeklyBuckets {
		for i := 0; i < len(days); i += 7 {
			buckets = append(buckets, bucket{format.ShortDate(days[i].Date), days[i:min(len(days), i+7)]})
		}
	} else {
		for _, d := range days {
			buckets = append(buckets, bucket{format.ShortDate(d.Date), []analytics.DaySummary{d}})
		}
	}
	value := func(bi, ki int) float64 {
		v := 0.0
		for _, d := range buckets[bi].days {
			f := 1.0
			if rep.Metric != analytics.MetricTokens && d.Tokens > 0 {
				f = rep.Metric.Value(d) / float64(d.Tokens)
			}
			switch k := keys[ki].ID; {
			case k == "all":
				v += rep.Metric.Value(d)
			case stack == "tool":
				v += float64(d.ByClient[k]) * f
			case k == "other":
				for md, t := range d.ByModel {
					if i := slices.Index(rank, md); i < 0 || i >= sep {
						v += float64(t) * f
					}
				}
			default:
				v += float64(d.ByModel[k]) * f
			}
		}
		return v
	}
	if size != sizeM {
		ui.Row(c.Key("n")).FillWidth().Gap(14).AlignItems(ui.End).Margin(0, 0, 10).Children(func() {
			a.metricNum(c, p, "t", rep.Metric, rep.Total, 30)
			busy := "—"
			if rep.Stats.Peak != nil {
				busy = format.ShortDate(rep.Stats.Peak.Date)
			}
			p.mono(c, L("Busiest %@", busy)+" · "+L("daily avg %@", m.metricText(rep.Metric, rep.Stats.AveragePerDay)), 10.5, p.T3).Ellipsis("…")
		})
	}
	legend := func(column bool) {
		var box ui.Element
		if column {
			box = ui.Column(c.Key("legend")).Width(168).Gap(2)
		} else {
			box = ui.Row(c.Key("legend")).FillWidth().Wrap().Gap(6).Margin(8, 0, 0)
		}
		box.Children(func() {
			for _, k := range keys {
				name := k.ID
				switch {
				case k.ID == "other":
					name = L("Other")
				case stack == "tool":
					name = toolName(k.ID)
				default:
					name = m.modelName(k.ID)
				}
				it := ui.Row(c.Key(k.ID)).Height(22).Padding(0, 6).Radius(3).Gap(6).AlignItems(ui.Center).Label(name)
				it.Background(it.AnimateColor("bg", pick(it.Hovered(), p.L1, ui.Transparent), animHover))
				it.Opacity(pick(focus != "" && focus != k.ID, float32(0.4), 1))
				it.Children(func() {
					swatch(c, k.Color, 7)
					if stack == "model" && k.ID != "other" {
						v := vendorOf(k.ID)
						logo(c, vendorLogo(v), 11, m.vendorTint(p, v))
					} else if stack == "tool" {
						logo(c, vendorLogo(k.ID), 11, m.vendorTint(p, k.ID))
					}
					p.mono(c, name, 10.5, p.T2)
				})
				if it.Clicked() {
					focus = pick(focus == k.ID, "", k.ID)
				}
			}
		})
	}
	ui.Row(c.Key("body")).FillWidth().Grow(1).Gap(18).Children(func() {
		ui.Column(c.Key("chart")).Grow(1).FillHeight().Children(func() {
			p.barChart(c, "bars", barOpts{
				Buckets: len(buckets), Keys: keys, Value: value, Focus: focus, AvgLine: m.s.UsageShowAverage, Axes: size != sizeM,
				Label: func(i int) string { return buckets[i].label }, Tick: a.tick(rep.Metric),
				Tip: func(i int) (string, []tipRow) {
					if !rep.WeeklyBuckets {
						return a.dayTip(p, buckets[i].days[0])
					}
					rows := []tipRow{}
					for ki, k := range keys {
						rows = append(rows, tipRow{Color: k.Color, Label: pick(k.ID == "other", L("Other"), k.ID), Value: m.metricText(rep.Metric, value(i, ki))})
					}
					return upper(L("Week of %@", buckets[i].label)), rows
				},
			})
		})
		if size == sizeW && stack != "none" {
			legend(true)
		}
	})
	if size == sizeL && stack != "none" {
		legend(false)
	}
	a.w.focus["usage"] = focus
}

// ── Calendar and time of day ──

func (a *ctrl) calendarCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	weeks := m.s.CalendarWeeks
	if weeks <= 0 {
		weeks = map[cardSize]int{sizeM: 26, sizeL: 26, sizeW: 53}[size]
	}
	metric := analytics.Metric(m.s.CalendarMetric)
	days := m.days(weeks*7 - (6 - int(m.now().Weekday())))
	cells := make([]calCell, len(days))
	active, longest, run := 0, 0, 0
	var peak analytics.DaySummary
	for i, d := range days {
		t, _ := format.DateFromKey(d.Date)
		cells[i] = calCell{Date: t, V: metric.Value(d)}
		if d.Tokens > 0 {
			active++
			run++
			longest = max(longest, run)
		} else {
			run = 0
		}
		if metric.Value(d) > metric.Value(peak) {
			peak = d
		}
	}
	col := p.T1
	if m.s.CardAccents["calendar"] != "" {
		col = a.accent(p, "calendar")
	}
	grid := func() {
		p.calendarDots(c, "cal", cells, col, func(i int) (string, []tipRow) { return a.dayTip(p, days[i]) })
	}
	factsL := [][2]string{{L("%lld d", longest), L("Longest streak")}, {m.metricText(metric, metric.Value(peak)), L("Peak · %@", format.ShortDate(peak.Date))}}
	switch size {
	case sizeM:
		grid()
	case sizeW:
		ui.Row(c.Key("w")).FillWidth().Grow(1).Gap(20).Children(func() {
			ui.Column(c.Key("side")).Width(170).FillHeight().Justify(ui.SpaceBetween).Children(func() {
				ui.Column(c).Gap(6).Children(func() {
					p.bigNum(c, "n", itoa(active), L("days"), 34, p.T1)
					p.mono(c, L("Active out of %lld", len(days)), 10.5, p.T3)
				})
				ui.Column(c).Gap(10).Children(func() {
					for _, f := range factsL {
						ui.Column(c.Key(f[1])).Gap(2).Children(func() {
							ui.Text(c, f[0]).Font(monoFont).FontSize(13).TextColor(p.T1).SingleLine()
							ui.Text(c, upper(f[1])).Font(monoFont).FontSize(9.5).LetterSpacing(0.7).TextColor(p.T3).SingleLine()
						})
					}
					p.heatScale(c, col)
				})
			})
			ui.Column(c.Key("g")).Grow(1).FillHeight().Children(grid)
		})
	default:
		ui.Row(c.Key("n")).FillWidth().Gap(8).AlignItems(ui.End).Margin(0, 0, 10).Children(func() {
			p.bigNum(c, "n", itoa(active), L("days"), 30, p.T1)
			p.mono(c, L("Active out of %lld", len(days)), 10.5, p.T3)
			ui.Box(c).Grow(1)
			p.heatScale(c, col)
		})
		grid()
		p.facts(c, factsL)
	}
}

func (a *ctrl) punchCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	n := max(7, m.s.PunchcardDays)
	ex := map[string]bool{}
	for _, x := range m.s.ExcludedModels {
		ex[x] = true
	}
	pc := m.d.Intra.Punchcard(n, m.d.TodayKey, ex)
	var grid [7][24]float64
	var hours [24]float64
	var wd [7]float64
	total := 0.0
	for w := range 7 {
		for h := range 24 {
			v := float64(pc.Grid[w][h])
			grid[w][h] = v
			hours[h] += v
			wd[w] += v
			total += v
		}
	}
	if total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	best, bestW := 0, 0
	for h := range 24 {
		if hours[h] > hours[best] {
			best = h
		}
	}
	for w := range 7 {
		if wd[w] > wd[bestW] {
			bestW = w
		}
	}
	night := 0.0
	for _, h := range []int{22, 23, 0, 1, 2, 3, 4, 5, 6} {
		night += hours[h]
	}
	col := p.T1
	if m.s.CardAccents["punchcard"] != "" {
		col = a.accent(p, "punchcard")
	}
	if size != sizeM {
		ui.Row(c.Key("n")).FillWidth().Gap(8).AlignItems(ui.End).Margin(0, 0, 10).Children(func() {
			p.bigNum(c, "n", pad2(best)+":00", "", 30, p.T1)
			p.mono(c, L("Busiest hour")+" · Claude Code · "+L("%lld days", n), 10.5, p.T3).Ellipsis("…")
		})
	}
	p.punchcard(c, "pc", grid, col, func(w, h int) (string, []tipRow) {
		return upper(L(format.WeekdaysFromMonday[w])) + " " + pad2(h) + ":00", []tipRow{{Label: "Claude Code", Value: shortNum(grid[w][h])}}
	})
	if size != sizeM {
		p.facts(c, [][2]string{{L(format.WeekdaysFromMonday[bestW]), L("Busiest weekday")}, {itoa(int(math.Round(night/total*100))) + "%", L("10 PM – 7 AM")}, {itoa(int(math.Round((wd[5]+wd[6])/total*100))) + "%", L("Weekends")}})
	}
}

// ── Tools ──

func (a *ctrl) toolsCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	if len(rep.Clients) == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	total := 0.0
	for _, s := range rep.Clients {
		total += float64(s.Tokens)
	}
	parts := make([]part, len(rep.Clients))
	for i, s := range rep.Clients {
		parts[i] = part{ID: s.Key, V: float64(s.Tokens), Color: m.toolColor(p, s.Key)}
	}
	top := rep.Clients[0]
	if size == sizeS {
		ui.Column(c.Key("s")).Gap(6).Children(func() {
			p.bigNum(c, "n", itoa(int(math.Round(float64(top.Tokens)/total*100))), "%", 28, p.T1)
			ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				logo(c, vendorLogo(top.Key), 12, m.vendorTint(p, top.Key))
				p.mono(c, toolName(top.Key), 11, p.T2)
			})
		})
		ui.Box(c).Grow(1)
		p.segmentBar(c, "seg", parts, 7, "")
		ui.Box(c).Height(6)
		p.mono(c, L("+%lld more tools", len(rep.Clients)-1), 10, p.T4)
		return
	}
	if size == sizeL {
		ui.Box(c.Key("n")).Margin(0, 0, 10).Children(func() { a.metricNum(c, p, "t", analytics.MetricTokens, total, 30) })
	}
	_, hover := p.segmentBar(c, "seg", parts, 6, "")
	ui.Column(c.Key("rows")).FillWidth().Gap(1).Margin(8, 0, 0).Children(func() {
		for _, s := range rep.Clients[:min(pick(size == sizeM, 3, 5), len(rep.Clients))] {
			v := float64(s.Tokens)
			ui.Row(c.Key(s.Key)).FillWidth().Height(24).Gap(8).AlignItems(ui.Center).Opacity(pick(hover != "" && hover != s.Key, float32(0.35), 1)).Children(func() {
				logo(c, vendorLogo(s.Key), 14, m.vendorTint(p, s.Key))
				ui.Text(c, toolName(s.Key)).Font(monoFont).FontSize(11.5).TextColor(p.T1).SingleLine().Grow(1).MinWidth(0)
				ui.Box(c).Width(90).Height(4).Radius(2).Background(p.L2).Draw(func(pt *ui.Painter, r ui.Rect) {
					pt.Fill(ui.Rect{X: r.X, Y: r.Y, W: r.W * float32(v/float64(top.Tokens)), H: r.H}, m.toolColor(p, s.Key), 2)
				})
				ui.Text(c, shortNum(v)).Font(monoFont).FontSize(11).TextColor(p.T2).Width(50).TextAlign(ui.End).SingleLine()
				ui.Text(c, itoa(int(math.Round(v/total*100)))+"%").Font(monoFont).FontSize(11).TextColor(p.T4).Width(36).TextAlign(ui.End).SingleLine()
			})
		}
	})
	if size == sizeL {
		ui.Box(c).Height(8)
		keys := make([]seriesKey, len(rep.Clients))
		for i, s := range rep.Clients {
			keys[i] = seriesKey{ID: s.Key, Color: m.toolColor(p, s.Key)}
		}
		p.barChart(c, "bars", barOpts{Buckets: len(rep.Days), Keys: keys, Tick: shortNum,
			Value: func(b, k int) float64 { return float64(rep.Days[b].ByClient[keys[k].ID]) },
			Tip:   func(i int) (string, []tipRow) { return a.dayTip(p, rep.Days[i]) }})
		p.facts(c, [][2]string{{toolName(top.Key), L("Top tool")}, {itoa(int(math.Round(float64(top.Tokens)/total*100))) + "%", L("Share")}, {itoa(rep.Stats.ActiveDays), L("Days with usage")}})
	}
}

// ── Token breakdown ──

var compKeys = [][3]string{
	{"cacheRead", "Cache read", "Re-sent context billed at the cache rate"},
	{"cacheWrite", "Cache write", "Context stored for later turns"},
	{"input", "Input", "New prompt tokens"},
	{"output", "Output", "What the model wrote"},
}

func (a *ctrl) compositionCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	f := analytics.NewFilter(m.s.ExcludedModels, m.s.ExcludedClients)
	period := m.s.CompositionPeriod
	if period == "auto" || period == "" {
		switch rep.Range {
		case analytics.RangeDay:
			period = "today"
		case analytics.RangeWeek, analytics.RangeMonth:
			period = "month"
		default:
			period = "allTime"
		}
	}
	src := m.d.Snapshot.Today
	switch period {
	case "month":
		src = m.d.Snapshot.Month
	case "allTime":
		src = m.d.Snapshot.AllTime
	}
	src = f.Apply(src)
	vals := [4]float64{float64(src.CacheReadTokens), float64(src.CacheWriteTokens), float64(src.InputTokens), float64(src.OutputTokens)}
	cols := [4]ui.Color{p.Ink[2], p.Ink[3], p.Ink[1], p.Ink[0]}
	if m.s.SeriesColors == "vendor" {
		cols = [4]ui.Color{ui.Hex("#5497d9"), ui.Hex("#3862a7"), ui.Hex("#d07758"), ui.Hex("#9c4438")}
	}
	total := vals[0] + vals[1] + vals[2] + vals[3]
	if total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	hit := vals[0] / math.Max(1, vals[0]+vals[1]+vals[2])
	parts := make([]part, 4)
	for i, k := range compKeys {
		parts[i] = part{ID: k[0], V: vals[i], Color: cols[i]}
	}
	donut := func(dsize, thick float32) string {
		_, h := p.donut(c, "donut", parts, dsize, thick, nil, func(h string) {
			v, label := hit*100, L("hit rate")
			for i, k := range compKeys {
				if k[0] == h {
					v, label = vals[i]/total*100, L(k[1])
				}
			}
			ui.Row(c).AlignItems(ui.End).Children(func() {
				ui.Text(c, itoa(int(math.Round(v)))).Font(dotFont).FontSize(pick(size == sizeL, float32(24), 19)).TextColor(p.T1).SingleLine()
				p.mono(c, "%", 9.5, p.T3)
			})
			p.mono(c, label, 9, p.T3)
		})
		return h
	}
	if size == sizeS {
		ui.Column(c.Key("s")).Grow(1).FillWidth().AlignItems(ui.Center).Justify(ui.Center).Children(func() { donut(104, 9) })
		return
	}
	if size == sizeL {
		ui.Row(c.Key("n")).FillWidth().Gap(10).AlignItems(ui.End).Margin(0, 0, 10).Children(func() {
			a.metricNum(c, p, "t", analytics.MetricTokens, total, 30)
			p.mono(c, L("%@ from cache", itoa(int(math.Round(vals[0]/total*100)))+"%"), 10.5, p.T3)
		})
	}
	ui.Row(c.Key("body")).FillWidth().Grow(1).Gap(16).AlignItems(ui.Center).Children(func() {
		hover := donut(pick(size == sizeL, float32(128), 96), pick(size == sizeL, float32(11), 9))
		ui.Column(c.Key("rows")).Grow(1).Basis(0).MinWidth(0).Gap(pick(size == sizeL, float32(8), 2)).Children(func() {
			for i, k := range compKeys {
				ui.Column(c.Key(k[0])).FillWidth().Gap(2).Opacity(pick(hover != "" && hover != k[0], float32(0.4), 1)).Children(func() {
					ui.Row(c).FillWidth().Height(20).Gap(8).AlignItems(ui.Center).Children(func() {
						swatch(c, cols[i], 8)
						ui.Text(c, L(k[1])).Font(monoFont).FontSize(11).TextColor(p.T1).Grow(1).SingleLine()
						ui.Text(c, shortNum(vals[i])).Font(monoFont).FontSize(11).TextColor(p.T2).Width(50).TextAlign(ui.End).SingleLine()
						ui.Text(c, itoa(int(math.Round(vals[i]/total*100)))+"%").Font(monoFont).FontSize(11).TextColor(p.T4).Width(34).TextAlign(ui.End).SingleLine()
					})
					if size == sizeL {
						ui.Text(c, L(k[2])).FontSize(10.5).TextColor(p.T4).Padding(0, 0, 0, 16).SingleLine().Ellipsis("…")
					}
				})
			}
		})
	})
	if size == sizeL {
		p.facts(c, [][2]string{{itoa(int(math.Round(hit*100))) + "%", L("Hit rate")}, {shortNum(vals[0]), L("From cache")}, {shortNum(vals[3]), L("Output")}})
	}
}

// ── This month's cost ──

func (a *ctrl) costCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	mc := m.monthCost()
	acc := a.accent(p, "cost")
	spent := 0.0
	vals := make([]float64, len(mc.Days))
	for i, d := range mc.Days {
		vals[i] = d.Cost
		spent = d.Cumulative
	}
	head := func(numSize float32) {
		ui.Column(c.Key("head")).Gap(6).Children(func() {
			p.money(c, "spent", spent, numSize)
			p.mono(c, L("Projected %@", format.Money(mc.Projected)), 10.5, p.T3)
		})
	}
	if size == sizeS {
		head(26)
		ui.Box(c).Grow(1)
		p.sparkLine(c, "c", cumulative(vals), 36, acc, true, true)
		return
	}
	// Last month's curve, spread over this month's days for comparison.
	var compare []float64
	if m.s.CostShowLastMonth && mc.LastMonthTotal > 0 {
		compare = make([]float64, mc.DaysInMonth)
		for i := range compare {
			compare[i] = mc.LastMonthTotal / float64(mc.DaysInMonth)
		}
	}
	chart := func() {
		p.areaChart(c, "area", areaOpts{
			Values: vals, Compare: compare, ProjectTo: pick(m.s.CostShowProjection, mc.DaysInMonth, 0), Axes: size != sizeM,
			Columns: m.s.CostShowDailyBars, Color: acc, Tick: func(v float64) string { return "$" + shortNum(v) },
			Labels: pick(size != sizeM, func(i int) string {
				if i < len(mc.Days) {
					return format.ShortDate(mc.Days[i].Date)
				}
				return ""
			}, nil),
			Tip: func(i int, cum float64) (string, []tipRow) {
				return upper(format.LongDate(mc.Days[i].Date)), []tipRow{{Label: L("Cost"), Value: format.Money(mc.Days[i].Cost)}, {Label: L("Month to date"), Value: format.Money(cum)}}
			},
		})
	}
	peak := 0.0
	for _, v := range vals {
		peak = math.Max(peak, v)
	}
	facts := [][2]string{{format.Money(mc.Projected), L("Projected")}, {format.Money(mc.LastMonthTotal), L("Last month")}, {format.Money(spent / math.Max(1, float64(len(vals)))), L("Daily avg")}, {format.Money(peak), L("Peak")}}
	switch size {
	case sizeM:
		ui.Row(c.Key("m")).FillWidth().Grow(1).Gap(16).Children(func() {
			ui.Column(c.Key("l")).Grow(1).Basis(0).FillHeight().Justify(ui.SpaceBetween).Children(func() {
				head(30)
				if n := len(mc.Days); n > 0 && mc.LastMonthTotal > 0 {
					a.delta(c, p, spent, mc.LastMonthTotal/float64(mc.DaysInMonth)*float64(n), L("vs last month"))
				}
			})
			ui.Column(c.Key("r")).Grow(1.4).Basis(0).FillHeight().Children(chart)
		})
	case sizeW:
		ui.Row(c.Key("w")).FillWidth().Grow(1).Gap(22).Children(func() {
			ui.Column(c.Key("side")).Width(190).FillHeight().Justify(ui.SpaceBetween).Children(func() {
				head(34)
				ui.Column(c).Gap(10).Children(func() {
					for _, f := range facts {
						ui.Column(c.Key(f[1])).Gap(2).Children(func() {
							ui.Text(c, f[0]).Font(monoFont).FontSize(13).TextColor(p.T1).SingleLine()
							ui.Text(c, upper(f[1])).Font(monoFont).FontSize(9.5).LetterSpacing(0.7).TextColor(p.T3).SingleLine()
						})
					}
				})
			})
			ui.Column(c.Key("chart")).Grow(1).FillHeight().Children(chart)
		})
	default:
		head(34)
		ui.Box(c).Height(10)
		ui.Column(c.Key("chart")).FillWidth().Grow(1).Children(chart)
		p.facts(c, facts)
	}
}
