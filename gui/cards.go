package gui

import (
	"math"
	"slices"
	"sort"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
)

// Widgets (designs/simpletoken-v3 Main and Widgets boards): each card has its allowed sizes (S 1×1, M 2×1, L 2×2,
// W 4×1) and a layout of its own per size. Anatomy: the header (▪ CAPTION + note), the defining figure in
// Geist Regular, one visual, then facts or rows. Colour lives in the data: model and tool colours follow the
// entity, single-series cards take their accent, everything else is ink.

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
		return 4, 1
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
	"hero":            {"Tokens", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"stat.average":    {"Daily average", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.peak":       {"Peak day", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.active":     {"Active days", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.perMillion": {"Per million tokens", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.totalCost":  {"Total cost", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.messages":   {"Messages", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.topModel":   {"Top model", []cardSize{sizeS, sizeM}, sizeS, true},
	"stat.weekday":    {"Busiest weekday", []cardSize{sizeS, sizeM}, sizeS, true},
	"limits":          {"Limits", []cardSize{sizeS, sizeM, sizeL}, sizeL, false},
	"models":          {"Models", []cardSize{sizeS, sizeM, sizeL}, sizeL, false},
	"map":             {"Usage map", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"flow":            {"Flow", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"usage":           {"Daily usage", []cardSize{sizeM, sizeL, sizeW}, sizeW, false},
	"calendar":        {"Calendar", []cardSize{sizeM, sizeL, sizeW}, sizeW, false},
	"punchcard":       {"Time of day", []cardSize{sizeM, sizeL, sizeW}, sizeL, false},
	"tools":           {"Tools", []cardSize{sizeS, sizeM, sizeL}, sizeL, false},
	"composition":     {"Token breakdown", []cardSize{sizeS, sizeM, sizeL}, sizeM, false},
	"cost":            {"This month's cost", []cardSize{sizeS, sizeM, sizeL, sizeW}, sizeL, false},
}

// ── Accents ──

// accentOptions are the card accents (Settings, card backs); each but ink has a validated 4-step ramp.
var accentOptions = [][2]string{{"ink", "Ink"}, {"slate", "Slate"}, {"clay", "Clay"}, {"violet", "Violet"}, {"rose", "Rose"}}

// defaultAccents are the design's: the cards that draw one series. The rest caption with the signal square.
var defaultAccents = map[string]string{
	"hero": "violet", "limits": "clay", "stat.average": "slate", "stat.peak": "clay", "stat.active": "violet",
	"stat.perMillion": "rose", "stat.totalCost": "clay", "stat.messages": "slate", "stat.weekday": "violet",
	"calendar": "slate", "punchcard": "clay", "cost": "clay",
}

// cardAccented reports whether a card's caption square takes its accent.
func cardAccented(id string) bool { _, ok := defaultAccents[id]; return ok }

// accentName is a card's accent: the user's choice, else the design's. Names from the first v2 builds map over.
func (a *ctrl) accentName(id string) string {
	n := a.m.s.CardAccents[id]
	switch n {
	case "blue", "green":
		n = "slate"
	case "terra":
		n = "clay"
	case "sig":
		n = "ink"
	}
	if n == "" {
		n = defaultAccents[id]
	}
	return n
}

// accent is a card's single-series colour; with vendor colours off it is the ink.
func (a *ctrl) accent(p palette, id string) ui.Color {
	if a.m.s.SeriesColors == "ink" {
		return p.Ink[0]
	}
	switch a.accentName(id) {
	case "slate":
		return p.Accent.Slate
	case "clay":
		return p.Accent.Clay
	case "violet":
		return p.Accent.Violet
	case "rose":
		return p.Accent.Rose
	}
	return p.Ink[0]
}

// ramp is a card accent's sequential ramp, lowest value first (rose borrows clay's; ink is the ink ladder).
func (a *ctrl) ramp(p palette, id string) [4]ui.Color {
	if a.m.s.SeriesColors != "ink" {
		switch a.accentName(id) {
		case "slate":
			return p.Accent.SlateR
		case "clay", "rose":
			return p.Accent.ClayR
		case "violet":
			return p.Accent.VioletR
		}
	}
	return [4]ui.Color{p.Ink[3], p.Ink[2], p.Ink[1], p.Ink[0]}
}

func (a *ctrl) cardSize(id string) cardSize {
	def := cardDefs[id]
	s := cardSize(a.m.s.CardSizes[id])
	if s == sizeW && !slices.Contains(def.Sizes, sizeW) {
		s = def.Def
	}
	if slices.Contains(def.Sizes, s) {
		return s
	}
	return def.Def
}

// cardNote is the faint note at the right of a card's header.
func (a *ctrl) cardNote(id string, rep analytics.Report) string {
	m := a.m
	switch id {
	case "hero":
		return rangeSpan(rep) + " · " + L("cumulative")
	case "limits":
		if t := a.limitsOffline(); t != "" {
			return L("Offline · from %@", t)
		}
		if t := a.limitsProbed(); t != "" {
			return L("Probed %@", t)
		}
	case "stat.peak":
		if rep.Stats.Peak != nil {
			return fmtr.Weekday(dateOf(rep.Stats.Peak.Date)) + " " + fmtr.ShortDate(rep.Stats.Peak.Date)
		}
	case "stat.active":
		return L("Streak %@", itoa(rep.Stats.Streak)+L("d"))
	case "models":
		return L("%lld models · ranked by 30 days", len(rep.Models))
	case "map":
		return L("Vendor → model") + " · " + m.num(rep.Total)
	case "flow":
		return L("Tools → models")
	case "usage":
		if rep.Range == analytics.RangeDay {
			return pick(m.s.IntradayMinutes == 30, L("Every 30 min"), L("Hourly"))
		}
		return L("Stacked by model") + " · " + pick(rep.WeeklyBuckets, L("weekly"), L("daily"))
	case "calendar":
		return L("%lld weeks", calendarWeeks(m.s.CalendarWeeks, a.cardSize("calendar")))
	case "punchcard":
		return "Claude Code · " + L("last 4 weeks")
	case "tools":
		return L("%lld tools", len(rep.Clients))
	case "composition":
		return L("1 dot = 1%")
	case "cost":
		mc := m.monthCost()
		return L("Day %lld of %lld", len(mc.Days), mc.DaysInMonth)
	}
	return ""
}

// rangeSpan is "Oct 7 – Nov 5" for a report's days.
func rangeSpan(rep analytics.Report) string {
	if len(rep.Days) == 0 {
		return fmtr.L(rep.Range.Label())
	}
	first, last := rep.Days[0].Date, rep.Days[len(rep.Days)-1].Date
	if first == last {
		return fmtr.ShortDate(first)
	}
	return fmtr.ShortDate(first) + " – " + fmtr.ShortDate(last)
}

func dateOf(key string) time.Time {
	d, _ := format.DateFromKey(key)
	return d
}

// ── Shared anatomy ──

// figure is a card's defining figure: tokens short ("1.09B"), money ("$212.40") or a count, in the big face.
func (a *ctrl) figure(c *ui.Context, p palette, key string, metric analytics.Metric, v float64, size float32) ui.Element {
	return bigText(c.Key(key), a.figureText(metric, v), size, p.T1)
}

func (a *ctrl) figureText(metric analytics.Metric, v float64) string {
	switch metric {
	case analytics.MetricCost:
		return format.Money(v)
	case analytics.MetricMessages:
		return format.Grouped(int64(math.Round(v)))
	}
	if a.m.s.ExactNumbers {
		return format.Grouped(int64(math.Round(v)))
	}
	return fmtr.Short(v)
}

// deltaText is "▲ 9.7%" / "▼ 6.2%".
func deltaText(now, prev float64) string {
	if prev <= 0 {
		return ""
	}
	pct := (now - prev) / prev * 100
	return pick(pct >= 0, "▲ ", "▼ ") + ftoa(math.Abs(pct), 1) + "%"
}

// lbl is a card's small explanatory line (11 px, tertiary).
func (p palette) lbl(c *ui.Context, text string) ui.Element {
	return ui.Text(c, text).FontSize(11).TextColor(p.T3).SingleLine().Ellipsis("…")
}

// fact is a value over its label, inline (the calendar's and time of day's footers).
func (p palette) factInline(c *ui.Context, value, label string) {
	ui.Row(c.Key(label)).Gap(6).AlignItems(ui.Baseline).Shrink(0).Children(func() {
		ui.Text(c, value).Font(monoFont).FontSize(13).TextColor(p.T1).SingleLine()
		ui.Text(c, label).FontSize(11).TextColor(p.T3).SingleLine()
	})
}

// footRow is a card's bottom strip above a hairline.
func (p palette) footRow(c *ui.Context, fn func()) {
	ui.Row(c.Key("foot")).FillWidth().Wrap().Gap(22).AlignItems(ui.Center).Padding(10, 0, 0).Shrink(0).Children(func() {
		ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
		fn()
	})
}

// modelMark is a model's mark: its vendor's logo in the model's colour (a swatch for vendors without one), so the
// colour and the vendor read together wherever a model is named.
func (a *ctrl) modelMark(c *ui.Context, p palette, model string, size float32) ui.Element {
	col := a.m.modelColor(p, model)
	if l := vendorLogo(vendorOf(model)); l != "" && model != "other" {
		return logo(c, l, size, col)
	}
	return swatch(c, col, max(6, size*0.6))
}

// modelLabel is a model's mark and name in mono.
func (a *ctrl) modelLabel(c *ui.Context, p palette, model string, size float32, col ui.Color) ui.Element {
	name := pick(model == "other", L("Other"), a.m.modelName(model))
	return ui.Row(c.Key("ml" + model)).Gap(6).AlignItems(ui.Center).MinWidth(0).Children(func() {
		a.modelMark(c, p, model, size+1)
		ui.Text(c, name).Font(monoFont).FontSize(size).TextColor(col).SingleLine().MinWidth(0).Ellipsis("…")
	})
}

func (p palette) empty(c *ui.Context, text string) {
	ui.Column(c.Key("empty")).Grow(1).FillWidth().AlignItems(ui.Center).Justify(ui.Center).Gap(8).Children(func() {
		p.mono(c, text, 11, p.T3)
	})
}

// dayTip is the shared tooltip of a day: tokens, cost, messages, then its top models and tools.
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
		rows = append(rows, tipRow{Logo: vendorLogo(vendorOf(k)), LogoC: a.m.modelColor(p, k), Label: a.m.modelName(k), Value: shortNum(float64(d.ByModel[k])), Dim: true})
	}
	if tools := sortedKeys(d.ByClient); len(tools) > 1 {
		rows = append(rows, tipRow{})
		for _, k := range tools[:min(3, len(tools))] {
			rows = append(rows, tipRow{Logo: vendorLogo(k), LogoC: a.m.toolColor(p, k), Label: toolName(k), Value: shortNum(float64(d.ByClient[k])), Dim: true})
		}
	}
	return upper(fmtr.Weekday(dateOf(d.Date)) + " " + fmtr.ShortDate(d.Date)), rows
}

func metricValues(rep analytics.Report) []float64 {
	out := make([]float64, len(rep.Days))
	for i, d := range rep.Days {
		out[i] = rep.Metric.Value(d)
	}
	return out
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

// miniBars are a card's small daily columns (the stat cards, the tools rows): idle days a 2 px stub, emph lit.
func (p palette) miniBars(c *ui.Context, key string, vals []float64, height float32, col func(i int, v float64) ui.Color) ui.Element {
	box := ui.Box(c.Key(key)).FillWidth().Height(height).Shrink(0)
	maxV := 1e-9
	for _, v := range vals {
		maxV = math.Max(maxV, v)
	}
	grow := box.AnimateTo("grow", 1, animData)
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		n := len(vals)
		if n == 0 {
			return
		}
		const gap = 2
		bw := (r.W - float32(n-1)*gap) / float32(n)
		for i, v := range vals {
			x := r.X + float32(i)*(bw+gap)
			if v <= 0 {
				pt.Fill(ui.Rect{X: x, Y: r.Y + r.H - 2, W: bw, H: 2}, p.L3, 1)
				continue
			}
			h := max(r.H*0.08, float32(v/maxV)*r.H) * grow
			pt.Fill(ui.Rect{X: x, Y: r.Y + r.H - h, W: bw, H: h}, col(i, v), 1)
		}
	})
	return box
}

// ── Main chart ──

func (a *ctrl) heroCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	if rep.Range == analytics.RangeDay {
		a.todayCard(c, p, size)
		return
	}
	m := a.m
	r := a.ramp(p, "hero")
	line, cols := r[3], r[0]
	if !p.Dark {
		line, cols = r[3], r[0]
	}
	prev := 0.0
	if rep.PreviousTotal != nil {
		prev = *rep.PreviousTotal
	}
	ui.Row(c.Key("num")).FillWidth().Wrap().Gap(18).AlignItems(ui.End).Shrink(0).Children(func() {
		a.figure(c, p, "n", rep.Metric, rep.Total, pick(size == sizeM, float32(34), 52))
		if m.s.HeroShowPrevious && prev > 0 {
			ui.Column(c.Key("d")).Gap(4).Padding(0, 0, 4).Children(func() {
				p.mono(c, deltaText(rep.Total, prev), 12, p.T1)
				ui.Text(c, L("vs the previous %lld days (%@)", len(rep.Days), a.figureText(rep.Metric, prev))).FontSize(11).TextColor(p.T3).SingleLine()
			})
		}
		if size != sizeM {
			ui.Box(c).Grow(1)
			ui.Row(c.Key("legend")).Gap(14).AlignItems(ui.Center).Padding(0, 0, 6).Children(func() {
				legendItem(c, p, L("This period"), func(pt *ui.Painter, r ui.Rect) { pt.Fill(ui.Rect{X: r.X, Y: r.Y + r.H/2 - 1, W: 14, H: 2}, line, 1) })
				if m.s.HeroShowPrevious {
					legendItem(c, p, L("Previous"), func(pt *ui.Painter, r ui.Rect) { dashH(pt, r.X, r.X+14, r.Y+r.H/2, p.Ink[2], 3, 2) })
				}
				legendItem(c, p, L("Daily"), func(pt *ui.Painter, r ui.Rect) { pt.Fill(ui.Rect{X: r.X + 4, Y: r.Y, W: 6, H: r.H}, cols, 1) })
			})
		}
	})
	var compare []float64
	if m.s.HeroShowPrevious {
		compare = make([]float64, len(rep.PreviousDays))
		for i, d := range rep.PreviousDays {
			compare[i] = rep.Metric.Value(d)
		}
	}
	ui.Box(c).Height(pick(size == sizeM, float32(6), 10))
	p.areaChart(c, "area", areaOpts{
		Values: metricValues(rep), Compare: compare, Axes: size != sizeM, Columns: size != sizeM,
		Color: line, Area: alpha(r[2], 0.10), ColColor: cols,
		Labels: pick(size != sizeM, func(i int) string { return fmtr.ShortDate(rep.Days[i].Date) }, nil),
		Tick:   a.tick(rep.Metric), NowLabel: pick(size != sizeM, L("NOW"), ""),
		Tip: func(i int, cum float64) (string, []tipRow) {
			d := rep.Days[i]
			rows := []tipRow{{Label: L("So far"), Value: a.figureText(rep.Metric, cum)}}
			if i < len(compare) {
				rows = append(rows, tipRow{Label: L("Previous"), Value: a.figureText(rep.Metric, cumulative(compare)[i]), Dim: true})
			}
			rows = append(rows, tipRow{}, tipRow{Label: L("That day"), Value: a.figureText(rep.Metric, rep.Metric.Value(d))})
			return upper(fmtr.Weekday(dateOf(d.Date))+" "+fmtr.ShortDate(d.Date)) + " · " + L("DAY %lld", i+1), rows
		},
	})
}

func legendItem(c *ui.Context, p palette, label string, mark func(pt *ui.Painter, r ui.Rect)) {
	ui.Row(c.Key("lg" + label)).Gap(6).AlignItems(ui.Center).Shrink(0).Children(func() {
		ui.Box(c).Size(14, 10).Draw(mark)
		p.mono(c, label, 10.5, p.T3)
	})
}

// todayCard is the main chart at Today: cumulative tokens by half hour against yesterday's, with where today
// lands by midnight at this pace (Claude Code, from the intraday scanner).
func (a *ctrl) todayCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	r := a.ramp(p, "hero")
	now := m.now()
	slot := now.Hour()*2 + now.Minute()/30
	today := m.todayHalf()[:slot+1]
	yest := m.yesterdayHalf()
	sum := func(v []float64) float64 {
		t := 0.0
		for _, x := range v {
			t += x
		}
		return t
	}
	tot, ytot := sum(today), sum(yest)
	yBefore := sum(yest[:min(len(yest), slot+1)])
	proj := tot
	if yBefore > 0 {
		proj = tot / yBefore * ytot
	}
	ui.Row(c.Key("num")).FillWidth().Gap(16).AlignItems(ui.End).Shrink(0).Children(func() {
		bigText(c.Key("n"), fmtr.Short(tot), pick(size == sizeM, float32(34), 46), p.T1)
		ui.Column(c.Key("d")).Gap(4).Padding(0, 0, 3).Children(func() {
			if yBefore > 0 {
				ui.Row(c).Gap(6).Children(func() {
					p.mono(c, deltaText(tot, yBefore), 12, p.T1)
					p.mono(c, L("vs %@ at %@", fmtr.Weekday(now.AddDate(0, 0, -1)), format.Clock(now)), 12, p.T3)
				})
			}
			if size != sizeM && proj > tot {
				p.mono(c, L("at this pace ≈ %@ by midnight", shortNum(proj)), 11, p.T3)
			}
		})
	})
	ui.Box(c).Height(10)
	p.areaChart(c, "today", areaOpts{
		Values: today, Compare: yest, ProjectTo: 48, Axes: size != sizeM, Columns: size != sizeM,
		Color: r[3], Area: alpha(r[2], 0.10), ColColor: r[0], Tick: shortNum, Ticks: 5,
		NowLabel: pick(size != sizeM, L("NOW")+" "+format.Clock(now), ""), CompareEnd: pick(size != sizeM, upper(fmtr.Weekday(now.AddDate(0, 0, -1)))+" "+shortNum(ytot), ""),
		Labels: func(i int) string { return pad2(i / 2) },
		Tip: func(i int, cum float64) (string, []tipRow) {
			return pad2(i/2) + ":" + pick(i%2 == 1, "30", "00"), []tipRow{{Label: L("Today"), Value: shortNum(cum)}}
		},
	})
}

// ── Stat cards ──

func (a *ctrl) statCard(c *ui.Context, p palette, id string, size cardSize, rep0 analytics.Report) {
	m := a.m
	rep := rep0
	if rep.Range == analytics.RangeDay {
		rep = m.report(analytics.RangeMonth, rep0.Metric)
	}
	r := a.ramp(p, id)
	acc := a.accent(p, id)
	days := rep.Days[max(0, len(rep.Days)-30):]
	vals := make([]float64, len(days))
	for i, d := range days {
		vals[i] = rep.Metric.Value(d)
	}
	figSize := pick(size == sizeS, float32(34), 38)
	col := ui.Column(c.Key("stat")).FillWidth().Grow(1).Gap(10)
	col.Children(func() {
		switch id {
		case "stat.average":
			a.figure(c, p, "n", rep.Metric, rep.Stats.AveragePerDay, figSize)
			p.miniBars(c, "bars", vals, 26, func(int, float64) ui.Color { return r[1] })
			ui.Box(c).Grow(1)
			p.lbl(c, L("Per active day · grey days idle"))
		case "stat.peak":
			if rep.Stats.Peak == nil {
				p.empty(c, L("No usage in this range"))
				return
			}
			pv := rep.Metric.Value(*rep.Stats.Peak)
			peakI := -1
			for i, d := range days {
				if d.Date == rep.Stats.Peak.Date {
					peakI = i
				}
			}
			a.figure(c, p, "n", rep.Metric, pv, figSize)
			p.miniBars(c, "bars", vals, 26, func(i int, _ float64) ui.Color { return pick(i == peakI, r[3], r[0]) })
			ui.Box(c).Grow(1)
			p.lbl(c, L("%@ the daily average", ftoa(pv/math.Max(1e-9, rep.Stats.AveragePerDay), 1)+"×"))
		case "stat.active":
			ui.Row(c.Key("n")).Gap(6).AlignItems(ui.Baseline).Children(func() {
				bigText(c, itoa(rep.Stats.ActiveDays), figSize, p.T1)
				p.mono(c, "/ "+itoa(rep.Stats.TotalDays), 12, p.T3)
			})
			a.activeDots(c, p, days, acc)
			ui.Box(c).Grow(1)
			p.lbl(c, L("Longest streak %lld days", longestStreak(rep.Days)))
		case "stat.perMillion":
			rates := make([]float64, 0, len(days))
			for _, d := range days {
				if d.Tokens > 0 {
					rates = append(rates, d.Cost/(float64(d.Tokens)/1e6))
				}
			}
			ui.Row(c.Key("n")).Gap(8).AlignItems(ui.Baseline).Children(func() {
				bigText(c, format.Money(rep.Stats.CostPerMillion), figSize, p.T1)
				if len(rates) > 1 {
					p.mono(c, deltaText(rates[len(rates)-1], rates[0]), 11.5, p.T2)
				}
			})
			p.sparkLine(c, "c", rates, 26, acc, false, false)
			ui.Box(c).Grow(1)
			p.lbl(c, L("Cost of a million tokens at list prices"))
		case "stat.totalCost":
			costs := make([]float64, len(days))
			for i, d := range days {
				costs[i] = d.Cost
			}
			bigText(c.Key("n"), format.Money(rep.Stats.TotalCost), figSize, p.T1)
			p.sparkLine(c, "c", costs, 30, acc, false, true)
			ui.Box(c).Grow(1)
			prevCost := 0.0
			for _, d := range rep.PreviousDays {
				prevCost += d.Cost
			}
			p.lbl(c, L("%lld days", len(rep.Days))+pick(prevCost > 0, " · "+deltaText(rep.Stats.TotalCost, prevCost)+" "+L("vs prev"), ""))
		case "stat.messages":
			var msgs int64
			msgV := make([]float64, len(days))
			for i, d := range days {
				msgs += d.Messages
				msgV[i] = float64(d.Messages)
			}
			bigText(c.Key("n"), format.Grouped(msgs), figSize, p.T1)
			p.miniBars(c, "bars", msgV, 30, func(int, float64) ui.Color { return r[1] })
			ui.Box(c).Grow(1)
			p.lbl(c, L("%@ per active day", format.Grouped(int64(float64(msgs)/math.Max(1, float64(rep.Stats.ActiveDays))))))
		case "stat.topModel":
			if len(rep.Models) == 0 {
				p.empty(c, L("No usage in this range"))
				return
			}
			top := rep.Models[0]
			var tokTot, costTot float64
			for _, s := range rep.Models {
				tokTot += float64(s.Tokens)
				costTot += s.Cost
			}
			ui.Row(c.Key("n")).Gap(8).AlignItems(ui.Center).Children(func() {
				a.modelMark(c, p, top.Key, 18)
				ui.Text(c, m.modelName(top.Key)).Font(monoFont).FontSize(22).FontWeight(500).TextColor(p.T1).SingleLine().MinWidth(0).Ellipsis("…")
			})
			parts := []part{}
			for _, s := range rep.Models[:min(6, len(rep.Models))] {
				parts = append(parts, part{ID: s.Key, V: float64(s.Tokens), Color: m.modelColor(p, s.Key)})
			}
			p.segmentBar(c, "seg", parts, 8, "")
			ui.Box(c).Grow(1)
			p.lbl(c, L("%@ of tokens · %@ of cost", ftoa(float64(top.Tokens)/math.Max(1, tokTot)*100, 1)+"%", ftoa(top.Cost/math.Max(1e-9, costTot)*100, 0)+"%"))
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
			ui.Text(c.Key("n"), L(format.WeekdaysFromMonday[best])).FontSize(30).FontWeight(600).LetterSpacing(-0.5).TextColor(p.T1).SingleLine()
			ui.Box(c).Grow(1)
			p.miniBars(c, "bars", avg, 30, func(i int, _ float64) ui.Color { return pick(i == best, r[3], r[0]) })
			ui.Row(c.Key("wd")).FillWidth().Gap(2).Children(func() {
				for i, l := range format.WeekdayInitialsFromMonday {
					ui.Text(c.Key(i), l).Font(monoFont).FontSize(9).TextColor(pick(i == best, p.T1, p.T4)).Grow(1).Basis(0).TextAlign(ui.Center).SingleLine()
				}
			})
		}
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

// activeDots is the active-days grid: 15 a row, active days in the accent, idle days a hairline ring, today lit.
func (a *ctrl) activeDots(c *ui.Context, p palette, days []analytics.DaySummary, col ui.Color) {
	rows := (len(days) + 14) / 15
	ui.Box(c.Key("dots")).FillWidth().Height(float32(rows) * 14).Shrink(0).Draw(func(pt *ui.Painter, r ui.Rect) {
		const gap = 4
		d := min(10, (r.W-14*gap)/15)
		for i, day := range days {
			dot := ui.Rect{X: r.X + float32(i%15)*(d+gap), Y: r.Y + float32(i/15)*(d+gap), W: d, H: d}
			switch {
			case i == len(days)-1:
				pt.Shadow(dot, d/2, 0, 0, 6, 0, p.glow())
				pt.Fill(dot, p.Sig, d/2)
			case day.Tokens > 0:
				pt.Fill(dot, col, d/2)
			default:
				pt.Stroke(dot, p.L4, d/2, 1)
			}
		}
	})
}

// calendarWeeks is the calendar's span: the setting, else 17 / 26 / 53 weeks by size.
func calendarWeeks(setting int, size cardSize) int {
	if setting > 0 {
		return setting
	}
	return map[cardSize]int{sizeM: 17, sizeL: 26, sizeW: 53}[size]
}

// sortedShares is a report's shares ranked by value.
func sortedShares(shares []analytics.Share, byCost bool) []analytics.Share {
	out := slices.Clone(shares)
	sort.SliceStable(out, func(i, j int) bool {
		if byCost {
			return out[i].Cost > out[j].Cost
		}
		return out[i].Tokens > out[j].Tokens
	})
	return out
}
