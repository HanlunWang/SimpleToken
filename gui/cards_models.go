package gui

import (
	"math"
	"slices"
	"sort"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
)

// modelSlots are the models a card names: the top of the trailing-30-day ranking that has usage in the report
// (at most sep), then "other" for the rest when there is any.
func (a *ctrl) modelSlots(rep analytics.Report, byCost bool, sep int) ([]string, map[string]float64, float64) {
	vals := map[string]float64{}
	total := 0.0
	for _, s := range rep.Models {
		v := pick(byCost, s.Cost, float64(s.Tokens))
		vals[s.Key] = v
		total += v
	}
	keys := sortedKeys(vals)
	if len(keys) <= sep {
		return keys, vals, total
	}
	other := 0.0
	for _, k := range keys[sep:] {
		other += vals[k]
	}
	keys = append(keys[:sep:sep], "other")
	vals["other"] = other
	return keys, vals, total
}

// ── Models ──

func (a *ctrl) modelsCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	byCost := m.s.ModelsMetric == "cost"
	keys, vals, total := a.modelSlots(rep, byCost, 5)
	if len(keys) == 0 || total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	col := func(k string) ui.Color { return pick(k == "other", p.Model.Other, m.modelColor(p, k)) }
	pct := func(v float64) string { return ftoa(v/total*100, 1) + "%" }
	value := func(v float64) string { return pick(byCost, format.Money(v), shortNum(v)) }
	focus := a.w.focus["models"]
	switch size {
	case sizeS:
		parts := make([]part, len(keys))
		for i, k := range keys {
			parts[i] = part{ID: k, V: vals[k], Color: col(k)}
		}
		p.segmentBar(c, "seg", parts, 10, "")
		ui.Column(c.Key("rows")).FillWidth().Gap(7).Margin(10, 0, 0).Children(func() {
			for _, k := range keys[:min(3, len(keys))] {
				ui.Row(c.Key(k)).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
					a.modelLabel(c, p, k, 11.5, p.T1).Grow(1)
					p.mono(c, pct(vals[k]), 11.5, p.T2)
				})
			}
			if len(keys) > 3 {
				rest := 0.0
				for _, k := range keys[3:] {
					rest += vals[k]
				}
				p.mono(c, L("+ %lld more · %@", len(keys)-3, pct(rest)), 10.5, p.T3)
			}
		})
	case sizeM:
		ui.Column(c.Key("rows")).FillWidth().Grow(1).Justify(ui.Center).Children(func() {
			for i, k := range keys[:min(4, len(keys))] {
				a.modelRow(c, p, i, k, vals[k], vals[keys[0]], 30, false, rep, value(vals[k]), pct(vals[k]))
			}
		})
	default:
		ui.Row(c.Key("head")).FillWidth().Gap(12).Height(16).AlignItems(ui.Center).Shrink(0).Children(func() {
			hd := func(t string, w float32, grow float32, end bool) {
				e := ui.Text(c.Key(t), t).Font(monoFont).FontSize(10).LetterSpacing(0.6).TextColor(p.T4).SingleLine()
				if grow > 0 {
					e.Grow(grow).Basis(0).MinWidth(0)
				} else {
					e.Width(w)
				}
				if end {
					e.TextAlign(ui.End)
				}
			}
			hd(L("MODEL"), 0, 1.1, false)
			hd(L("SHARE"), 0, 2, false)
			hd(L("TOKENS"), 62, 0, true)
			hd("%", 46, 0, true)
			if m.s.ModelsShowSparklines {
				hd(L("30 DAYS"), 84, 0, true)
			}
		})
		ui.Column(c.Key("rows")).FillWidth().Grow(1).Children(func() {
			for i, k := range keys {
				a.modelRow(c, p, i+1, k, vals[k], vals[keys[0]], 38, m.s.ModelsShowSparklines, rep, value(vals[k]), pct(vals[k]))
			}
		})
	}
	a.w.focus["models"] = focus
}

// modelRow is one model in a table: its mark and name, its share bar, the value and the share; spark adds its
// last 30 days.
func (a *ctrl) modelRow(c *ui.Context, p palette, i int, k string, v, top float64, height float32, spark bool, rep analytics.Report, value, share string) {
	m := a.m
	col := pick(k == "other", p.Model.Other, m.modelColor(p, k))
	ui.Row(c.Key(k)).FillWidth().Height(height).Gap(12).AlignItems(ui.Center).Shrink(0).Children(func() {
		if i > 0 {
			ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
		}
		a.modelLabel(c, p, k, 12, p.T1).Grow(1.1).Basis(0)
		ui.Box(c.Key("bar")).Grow(2).Basis(0).MinWidth(60).Height(pick(height > 32, float32(6), 5)).Radius(3).Background(p.L2).Draw(func(pt *ui.Painter, r ui.Rect) {
			pt.Fill(ui.Rect{X: r.X, Y: r.Y, W: r.W * float32(v/math.Max(1e-9, top)), H: r.H}, col, r.H/2)
		})
		ui.Text(c, value).Font(monoFont).FontSize(12).TextColor(p.T1).Width(62).TextAlign(ui.End).SingleLine()
		ui.Text(c, share).Font(monoFont).FontSize(11).TextColor(p.T2).Width(46).TextAlign(ui.End).SingleLine()
		if spark {
			series := make([]float64, 0, 30)
			for _, d := range rep.Days[max(0, len(rep.Days)-30):] {
				if k == "other" {
					t := 0.0
					rank := m.ranking()
					for md, x := range d.ByModel {
						if i := slices.Index(rank, md); i < 0 || i >= 5 {
							t += float64(x)
						}
					}
					series = append(series, t)
					continue
				}
				series = append(series, float64(d.ByModel[k]))
			}
			ui.Box(c.Key("sp")).Width(84).Height(20).Draw(func(pt *ui.Painter, r ui.Rect) {
				mx := 1e-9
				for _, s := range series {
					mx = math.Max(mx, s)
				}
				if len(series) < 2 {
					return
				}
				pts := make([][2]float32, len(series))
				for j, s := range series {
					pts[j] = [2]float32{r.X + float32(j)/float32(len(series)-1)*r.W, r.Y + r.H - 2 - float32(s/mx)*(r.H-5)}
				}
				path := smoothPath(pts)
				path.Join(ui.RoundJoin)
				pt.StrokePath(path, 1.4, col)
				e := pts[len(pts)-1]
				pt.Fill(ui.Rect{X: e[0] - 2.2, Y: e[1] - 2.2, W: 4.4, H: 4.4}, col, 2.2)
			})
		}
	})
}

// ── Usage map ──

func (a *ctrl) mapCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	m := a.m
	groups := map[string]*tmGroup{}
	vendorV := map[string]float64{}
	total := 0.0
	for _, s := range rep.Models {
		v := vendorOf(s.Key)
		g := groups[v]
		if g == nil {
			g = &tmGroup{ID: v, Logo: vendorLogo(v)}
			groups[v] = g
		}
		g.Items = append(g.Items, part{ID: s.Key, V: float64(s.Tokens), Color: m.modelColor(p, s.Key)})
		vendorV[v] += float64(s.Tokens)
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
	// The vendor strip: the biggest vendor named with its logo, the rest together.
	vendors := sortedKeys(vendorV)
	top := vendors[0]
	share := vendorV[top] / total
	ui.Row(c.Key("vendors")).FillWidth().Gap(2).Shrink(0).Margin(0, 0, 8).Children(func() {
		strip := func(key, label string, w float64, col ui.Color, logoName string) {
			ui.Row(c.Key(key)).Grow(float32(w)).Basis(0).MinWidth(0).Gap(6).Padding(0, 0, 6).AlignItems(ui.Center).Children(func() {
				ui.Box(c).Absolute().Left(0).Bottom(0).FillWidth().Height(1).Background(col)
				if logoName != "" {
					logo(c, logoName, 11, col)
				}
				p.mono(c, label, 10, p.T3).LetterSpacing(0.6).Ellipsis("…")
			})
		}
		strip("top", upper(vendorName(top))+" "+ftoa(share*100, 1)+"%", share, m.vendorTint(p, top), vendorLogo(top))
		if len(vendors) > 1 {
			strip("rest", L("OTHER VENDORS")+" "+ftoa((1-share)*100, 1)+"%", 1-share, p.L4, "")
		}
	})
	p.treemap(c, "map", gs, total, func(cl tmCell) (string, []tipRow) {
		v := vendorOf(cl.ID)
		return upper(vendorName(v)), []tipRow{
			{Logo: vendorLogo(v), LogoC: cl.Color, Label: m.modelName(cl.ID), Value: m.num(cl.V)},
			{Label: L("Share"), Value: ftoa(cl.V/total*100, 1) + "%"},
		}
	})
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

// ── Flow ──

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
	merged := map[[2]string]float64{}
	for k, v := range pairs {
		to := k[1]
		if !slices.Contains(top, to) {
			to = "other"
		}
		merged[[2]string{k[0], to}] += v
	}
	var flows []flow
	for k, v := range merged {
		flows = append(flows, flow{From: k[0], To: k[1], V: v})
	}
	pc := func(v float64) string { return itoa(int(math.Round(v/total*100))) + "%" }
	tools := sortedKeys(toolV)
	var left []sankeyNode
	for i, t := range tools {
		left = append(left, sankeyNode{ID: t, Label: toolName(t), Sub: pc(toolV[t]), Color: m.toolColor(p, t), Strong: i == 0})
	}
	var right []sankeyNode
	other := 0.0
	for _, f := range flows {
		if f.To == "other" {
			other += f.V
		}
	}
	for _, md := range top {
		right = append(right, sankeyNode{ID: md, Label: m.modelName(md), Sub: pc(modelV[md]), Color: m.modelColor(p, md)})
	}
	if other > 0 {
		right = append(right, sankeyNode{ID: "other", Label: L("Other"), Sub: pc(other), Color: p.Model.Other})
	}
	p.sankey(c, "flow", left, right, flows, func(f flow) ui.Color { return m.toolColor(p, f.From) }, func(f flow) (string, []tipRow) {
		return upper(toolName(f.From) + " → " + pick(f.To == "other", L("Other"), m.modelName(f.To))), []tipRow{
			{Color: m.toolColor(p, f.From), Label: L("Tokens"), Value: m.num(f.V)},
			{Label: L("Share"), Value: ftoa(f.V/total*100, 1) + "%"},
		}
	})
	if size != sizeM {
		p.lbl(c, L("Hover a tool to light its paths")).Margin(8, 0, 0)
	}
}

// ── Daily usage ──

func (a *ctrl) usageCard(c *ui.Context, p palette, size cardSize, rep analytics.Report) {
	if rep.Range == analytics.RangeDay {
		a.usageIntraday(c, p, size)
		return
	}
	m := a.m
	stack := m.s.UsageStack
	rank := m.ranking()
	sep := max(2, min(5, m.s.SeparateModels+1))
	var keys []seriesKey
	switch stack {
	case "tool":
		for _, s := range rep.Clients {
			keys = append(keys, seriesKey{ID: s.Key, Color: m.toolColor(p, s.Key)})
		}
	case "none":
		keys = []seriesKey{{ID: "all", Color: a.ramp(p, "usage")[2]}}
	default:
		for _, md := range rank[:min(sep, len(rank))] {
			keys = append(keys, seriesKey{ID: md, Color: m.modelColor(p, md)})
		}
		keys = append(keys, seriesKey{ID: "other", Color: p.Model.Other})
	}
	days := rep.Days
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
	// Where today lands by midnight at this pace (daily buckets only).
	proj := 0.0
	if !rep.WeeklyBuckets && len(buckets) > 0 {
		now := m.now()
		frac := (float64(now.Hour()) + float64(now.Minute())/60) / 24
		last := 0.0
		for k := range keys {
			last += value(len(buckets)-1, k)
		}
		if frac > 0.05 {
			proj = last / frac
		}
	}
	if size != sizeM && stack != "none" {
		ui.Row(c.Key("legend")).FillWidth().Wrap().Gap(14).Margin(-6, 0, 10).Shrink(0).Children(func() {
			for _, k := range keys {
				ui.Row(c.Key(k.ID)).Gap(6).AlignItems(ui.Center).Children(func() {
					switch {
					case k.ID == "other":
						swatch(c, k.Color, 7)
						p.mono(c, L("Other"), 10.5, p.T2)
					case stack == "tool":
						logo(c, vendorLogo(k.ID), 11, k.Color)
						p.mono(c, toolName(k.ID), 10.5, p.T2)
					default:
						a.modelMark(c, p, k.ID, 11)
						p.mono(c, m.modelName(k.ID), 10.5, p.T2)
					}
				})
			}
		})
	}
	p.usageBars(c, "bars", usageOpts{
		Buckets: len(buckets), Keys: keys, Value: value, Proj: proj, Axes: size != sizeM, Avg: m.s.UsageShowAverage,
		Label: func(i int) string { return buckets[i].label }, Tick: a.tick(rep.Metric), WeeklyTicks: !rep.WeeklyBuckets,
		Tip: func(i int) (string, []tipRow) {
			if !rep.WeeklyBuckets {
				return a.dayTip(p, buckets[i].days[0])
			}
			rows := []tipRow{}
			for ki, k := range keys {
				rows = append(rows, tipRow{Color: k.Color, Label: pick(k.ID == "other", L("Other"), m.modelName(k.ID)), Value: a.figureText(rep.Metric, value(i, ki))})
			}
			return upper(L("Week of %@", buckets[i].label)), rows
		},
	})
}

// usageOpts configures usageBars.
type usageOpts struct {
	Buckets     int
	Keys        []seriesKey
	Value       func(bucket, key int) float64
	Proj        float64 // today's projected total (the last bucket), hatched above its bar; 0: none
	Axes, Avg   bool
	Label       func(i int) string
	Tick        func(v float64) string
	WeeklyTicks bool // a label every 7 buckets and "Today" at the end
	Tip         func(i int) (string, []tipRow)
}

// usageBars is the daily usage chart: stacked bars 58 % of their slot with 1.5 px gaps, idle days a dashed stub,
// the hovered day on a faint column, today's projection hatched, and the dashed average with its label.
func (p palette) usageBars(c *ui.Context, key string, o usageOpts) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(40)
	totals := make([]float64, o.Buckets)
	maxV, sum := 0.0, 0.0
	active := 0
	for i := range o.Buckets {
		for k := range o.Keys {
			totals[i] += o.Value(i, k)
		}
		maxV = math.Max(maxV, totals[i])
		if totals[i] > 0 && i < o.Buckets-1 {
			sum += totals[i]
			active++
		}
	}
	maxV = niceMax(math.Max(maxV, o.Proj) * 1.06)
	avg := sum / math.Max(1, float64(active))
	padB := pick(o.Axes, float32(16), 2)
	grow := box.AnimateTo("grow", 1, animData)
	b := box.Bounds()
	hover := -1
	if px, _, over := box.PointerPosition(); over && o.Buckets > 0 {
		hover = int(px / (b.W / float32(o.Buckets)))
		if hover >= o.Buckets {
			hover = -1
		}
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		y0, ih := r.Y+10, r.H-padB-10
		base := y0 + ih
		H := func(v float64) float32 { return float32(v/maxV) * ih * grow }
		if o.Axes {
			for _, f := range []float64{0.5, 1} {
				yy := base - float32(f)*ih
				var g ui.Path
				g.MoveTo(r.X, yy).LineTo(r.X+r.W, yy).Dash(0, 2, 4)
				pt.StrokePath(&g, 1, p.L2)
				p.axisText(pt, r.X, pick(f == 1, yy+3, yy-14), o.Tick(maxV*f), 0)
			}
		}
		pt.Line(r.X, base, r.X+r.W, base, 1, p.L3)
		slot := r.W / float32(max(1, o.Buckets))
		bw := max(1, slot*0.58)
		gap := pick(bw > 6, float32(1.5), 0.5)
		if hover >= 0 {
			pt.Fill(ui.Rect{X: r.X + float32(hover)*slot + 2, Y: y0 - 6, W: slot - 4, H: ih + 6}, p.L1, 2)
		}
		for i := range o.Buckets {
			x := r.X + float32(i)*slot + (slot-bw)/2
			if totals[i] <= 0 {
				pt.StrokeDashed(ui.Rect{X: x + 0.5, Y: base - 6.5, W: bw - 1, H: 6}, p.L3, 1, 1)
				continue
			}
			y := base
			first := true
			for k, s := range o.Keys {
				h := H(o.Value(i, k))
				if h < 0.4 {
					continue
				}
				g := pick(first, float32(0), gap)
				pt.Fill(ui.Rect{X: x, Y: y - h + g, W: bw, H: max(0.4, h-g)}, s.Color, 1)
				y -= h
				first = false
			}
			if i == o.Buckets-1 && o.Proj > totals[i] {
				top := base - H(o.Proj)
				rr := ui.Rect{X: x, Y: top, W: bw, H: y - top - gap}
				if rr.H > 1 {
					hatch(pt, rr, 1, alpha(p.FG, 0.38))
					pt.StrokeDashed(rr, p.L4, 1, 1)
				}
			}
		}
		if o.Avg && avg > 0 {
			ay := base - H(avg)
			var g ui.Path
			g.MoveTo(r.X, ay).LineTo(r.X+r.W, ay).Dash(0, 5, 4)
			pt.StrokePath(&g, 1, p.Ink[1])
			p.axisTextEnd(pt, r.X+r.W, ay-14, "AVG "+o.Tick(avg), p.T2)
		}
		if o.Axes && o.Label != nil && o.Buckets > 0 {
			if o.WeeklyTicks {
				for i := 1; i < o.Buckets-3; i += 7 {
					p.axisTextC(pt, r.X+float32(i)*slot+slot/2, r.Y+r.H-12, o.Label(i), p.T4)
				}
				p.axisTextC(pt, r.X+float32(o.Buckets-1)*slot+slot/2, r.Y+r.H-12, L("Today"), p.T1)
			} else {
				for k, i := range []int{0, o.Buckets / 2, o.Buckets - 1} {
					p.axisText(pt, r.X+float32(i)*slot+slot/2, r.Y+r.H-12, o.Label(i), k)
				}
			}
		}
	})
	if hover >= 0 && o.Tip != nil {
		box.Children(func() {
			title, rows := o.Tip(hover)
			p.tooltip(c, float32(hover+1)*b.W/float32(o.Buckets)+2, -4, b.W, title, rows)
		})
	}
	return box
}

// usageIntraday is the usage chart at Today: one day in half-hour or hour slots (Claude Code, from the intraday
// scanner), stacked by model, with a day navigator; today shows a "now" cap and faint future slots.
func (a *ctrl) usageIntraday(c *ui.Context, p palette, size cardSize) {
	m, w := a.m, a.w
	now := m.now()
	day := w.usageDay
	if day == "" {
		day = m.d.TodayKey
	}
	isToday := day == m.d.TodayKey
	ex := map[string]bool{}
	for _, x := range m.s.ExcludedModels {
		ex[x] = true
	}
	byModel := m.d.Intra.ModelBuckets(day, ex)
	hourly := m.s.IntradayMinutes != 30
	slots := pick(hourly, 24, 48)
	per := 48 / slots
	val := func(list []int64, i int) float64 {
		v := 0.0
		for k := i * per; k < (i+1)*per && k < len(list); k++ {
			v += float64(list[k])
		}
		return v
	}
	rank := m.ranking()
	sep := max(2, min(5, m.s.SeparateModels+1))
	var keys []seriesKey
	for _, md := range rank[:min(sep, len(rank))] {
		if _, ok := byModel[md]; ok {
			keys = append(keys, seriesKey{ID: md, Color: m.modelColor(p, md)})
		}
	}
	keys = append(keys, seriesKey{ID: "other", Color: p.Model.Other})
	value := func(b, k int) float64 {
		switch id := keys[k].ID; id {
		case "other":
			t := 0.0
			for md, l := range byModel {
				if i := slices.Index(rank, md); i < 0 || i >= sep {
					t += val(l, b)
				}
			}
			return t
		default:
			return val(byModel[id], b)
		}
	}
	total := 0.0
	for b := range slots {
		for k := range keys {
			total += value(b, k)
		}
	}
	nowSlot := (now.Hour()*60 + now.Minute()) / (24 * 60 / slots)
	slotLabel := func(i int) string {
		mins := i * 24 * 60 / slots
		return pad2(mins/60) + ":" + pad2(mins%60)
	}
	ui.Row(c.Key("nav")).FillWidth().Gap(10).AlignItems(ui.Center).Margin(-4, 0, 8).Shrink(0).Children(func() {
		if size != sizeM {
			bigText(c.Key("t"), fmtr.Short(total), 28, p.T1)
			p.mono(c, "Claude Code", 10.5, p.T3)
		}
		ui.Box(c).Grow(1)
		t, _ := format.DateFromKey(day)
		if p.iconBtn(c, "prev", "chevron-left", L("Previous day"), false).Clicked() {
			w.usageDay = format.DayKey(t.AddDate(0, 0, -1))
		}
		label := ui.Row(c.Key("date")).Height(24).Padding(0, 8).Radius(p.rCtl()).AlignItems(ui.Center).Label(L("Choose a day"))
		label.Background(label.AnimateColor("bg", pick(label.Hovered() || w.calOpen, p.L2, ui.Transparent), animHover))
		label.Children(func() { p.mono(c, upper(format.Weekday(t)+" "+format.ShortDate(day)), 11, p.T1) })
		if label.Clicked() {
			w.calOpen, w.calDate = !w.calOpen, t
		}
		ui.Popover(c, label, &w.calOpen, func() {
			if ui.Calendar(c.Key("cal"), &w.calDate).Changed() {
				if k := format.DayKey(w.calDate); k <= m.d.TodayKey {
					w.usageDay = k
				}
				w.calOpen = false
			}
		})
		if p.iconBtn(c, "next", "chevron-right", L("Next day"), false).Clicked() && !isToday {
			w.usageDay = format.DayKey(t.AddDate(0, 0, 1))
		}
		if !isToday && p.button(c, "today", L("Today"), "", btnGhost).Clicked() {
			w.usageDay = ""
		}
	})
	if total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	p.barChart(c, "bars", barOpts{
		Buckets: slots, Keys: keys, Value: value, Axes: size != sizeM, Tick: shortNum,
		Label: slotLabel, LabelAt: func(i int) bool { return i%(slots/4) == 0 }, Now: nowSlot, HasNow: isToday,
		Tip: func(i int) (string, []tipRow) {
			rows := []tipRow{}
			for k, s := range keys {
				v := value(i, k)
				if v == 0 {
					continue
				}
				row := tipRow{Color: s.Color, Label: pick(s.ID == "other", L("Other"), m.modelName(s.ID)), Value: shortNum(v)}
				if s.ID != "other" {
					row.Color, row.Logo, row.LogoC = ui.Color{}, vendorLogo(vendorOf(s.ID)), s.Color
				}
				rows = append(rows, row)
			}
			return slotLabel(i) + "–" + slotLabel(i+1), rows
		},
	})
}
