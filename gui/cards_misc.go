package gui

import (
	"math"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
)

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
	prev := map[string]float64{}
	for _, d := range rep.PreviousDays {
		for k, v := range d.ByClient {
			prev[k] += float64(v)
		}
	}
	share := func(v float64) string { return ftoa(v/total*100, 1) + "%" }
	bar := func(height float32) {
		ui.Row(c.Key("share")).FillWidth().Height(height).Gap(3).Shrink(0).Children(func() {
			for _, s := range rep.Clients {
				ui.Box(c.Key(s.Key)).Grow(float32(s.Tokens)).Basis(0).FillHeight().Radius(min(3, height/2)).Background(m.toolColor(p, s.Key))
			}
		})
	}
	top := rep.Clients[0]
	switch size {
	case sizeS:
		ui.Row(c.Key("n")).Gap(8).AlignItems(ui.Baseline).Children(func() {
			bigText(c, itoa(int(math.Round(float64(top.Tokens)/total*100)))+"%", 34, p.T1)
			logo(c, vendorLogo(top.Key), 14, m.toolColor(p, top.Key))
			ui.Text(c, toolName(top.Key)).FontSize(12.5).TextColor(p.T1).SingleLine().MinWidth(0).Ellipsis("…")
		})
		ui.Box(c).Height(8)
		bar(10)
		ui.Box(c).Grow(1)
		parts := []string{}
		for _, s := range rep.Clients[1:min(4, len(rep.Clients))] {
			parts = append(parts, toolName(s.Key)+" "+itoa(int(math.Round(float64(s.Tokens)/total*100)))+"%")
		}
		p.mono(c, strings.Join(parts, "  "), 10.5, p.T2).Ellipsis("…")
	case sizeM:
		ui.Column(c.Key("rows")).FillWidth().Grow(1).Justify(ui.Center).Children(func() {
			for i, s := range rep.Clients[:min(4, len(rep.Clients))] {
				v := float64(s.Tokens)
				ui.Row(c.Key(s.Key)).FillWidth().Height(30).Gap(12).AlignItems(ui.Center).Children(func() {
					if i > 0 {
						ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
					}
					logo(c, vendorLogo(s.Key), 13, m.toolColor(p, s.Key))
					ui.Text(c, toolName(s.Key)).FontSize(12.5).TextColor(p.T1).Width(100).SingleLine().Ellipsis("…")
					ui.Box(c.Key("b")).Grow(1).Height(5).Radius(3).Background(p.L2).Draw(func(pt *ui.Painter, r ui.Rect) {
						pt.Fill(ui.Rect{X: r.X, Y: r.Y, W: r.W * float32(v/float64(top.Tokens)), H: r.H}, m.toolColor(p, s.Key), 2.5)
					})
					ui.Text(c, shortNum(v)).Font(monoFont).FontSize(12).TextColor(p.T1).Width(56).TextAlign(ui.End).SingleLine()
					ui.Text(c, deltaText(v, prev[s.Key])).Font(monoFont).FontSize(11).TextColor(p.T2).Width(56).TextAlign(ui.End).SingleLine()
				})
			}
		})
	default:
		ui.Row(c.Key("n")).Gap(10).AlignItems(ui.Baseline).Shrink(0).Children(func() {
			bigText(c, fmtr.Short(total), 34, p.T1)
			p.mono(c, L("across %lld tools · %lld days", len(rep.Clients), len(rep.Days)), 11, p.T3)
		})
		ui.Box(c).Height(10)
		bar(6)
		ui.Box(c).Height(4)
		days := rep.Days[max(0, len(rep.Days)-30):]
		rows := min(len(rep.Clients), 5)
		rowH := float32(58)
		ui.Column(c.Key("rows")).FillWidth().Grow(1).Children(func() {
			for _, s := range rep.Clients[:rows] {
				v := float64(s.Tokens)
				col := m.toolColor(p, s.Key)
				vals := make([]float64, len(days))
				activeDays := 0
				for j, d := range days {
					vals[j] = float64(d.ByClient[s.Key])
					if vals[j] > 0 {
						activeDays++
					}
				}
				ui.Row(c.Key(s.Key)).FillWidth().Height(rowH).Gap(14).AlignItems(ui.Center).Shrink(0).Children(func() {
					ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
					p.tile(c, vendorLogo(s.Key), "", col)
					ui.Column(c.Key("name")).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
						ui.Text(c, toolName(s.Key)).FontSize(13).FontWeight(500).TextColor(p.T1).SingleLine().Ellipsis("…")
						sub := L("%lld active days", activeDays)
						if d := deltaText(v, prev[s.Key]); d != "" {
							sub += " · " + d
						}
						p.mono(c, sub, 10.5, p.T3).Ellipsis("…")
					})
					ui.Box(c.Key("bars")).Grow(1.25).Basis(0).MinWidth(100).Children(func() {
						p.miniBars(c, "mb", vals, 26, func(j int, _ float64) ui.Color { return pick(j == len(vals)-1, col, alpha(col, 0.62)) })
					})
					ui.Column(c.Key("v")).Width(64).AlignItems(ui.End).Gap(5).Children(func() {
						p.mono(c, shortNum(v), 12.5, p.T1)
						p.mono(c, share(v), 10.5, p.T3)
					})
				})
			}
		})
		p.lbl(c, L("Daily tokens · each row scaled to its own peak · today brightest"))
	}
}

// ── Token breakdown ──

var compKeys = [][2]string{{"output", "Output"}, {"input", "Input"}, {"cacheWrite", "Cache write"}, {"cacheRead", "Cache read"}}

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
	vals := [4]float64{float64(src.OutputTokens), float64(src.InputTokens), float64(src.CacheWriteTokens), float64(src.CacheReadTokens)}
	total := vals[0] + vals[1] + vals[2] + vals[3]
	if total == 0 {
		p.empty(c, L("No usage in this range"))
		return
	}
	cols := [4]ui.Color{p.Ink[0], p.Accent.Slate, p.Accent.Violet, {}}
	if m.s.SeriesColors == "ink" {
		cols = [4]ui.Color{p.Ink[0], p.Ink[1], p.Ink[2], {}}
	}
	pct := func(i int) float64 { return vals[i] / total * 100 }
	swatchOf := func(i int) {
		if i == 3 {
			ui.Box(c.Key("sw")).Size(7, 7).Radius(1.5).Border(1, p.L4).Shrink(0)
			return
		}
		swatch(c, cols[i], 7)
	}
	if size == sizeS {
		ui.Row(c.Key("n")).Gap(8).AlignItems(ui.Baseline).Children(func() {
			bigText(c, itoa(int(math.Round(pct(3))))+"%", 34, p.T1)
			ui.Text(c, L("from cache")).FontSize(12).TextColor(p.T2).SingleLine()
		})
		ui.Box(c).Height(8)
		p.waffle(c, "w", vals, cols, 50, 25, 3)
		ui.Box(c).Grow(1)
		p.mono(c, L("out")+" "+ftoa(pct(0), 1)+"%  "+L("in")+" "+ftoa(pct(1), 1)+"%  "+L("write")+" "+ftoa(pct(2), 1)+"%", 10.5, p.T2).Ellipsis("…")
		return
	}
	rows := func(h float32) {
		ui.Column(c.Key("rows")).FillWidth().Grow(1).Children(func() {
			for i, k := range compKeys {
				ui.Row(c.Key(k[0])).FillWidth().Height(h).Gap(10).AlignItems(ui.Center).Children(func() {
					if i > 0 || size == sizeL {
						ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
					}
					swatchOf(i)
					ui.Text(c, L(k[1])).FontSize(12.5).TextColor(p.T1).Grow(1).SingleLine()
					p.mono(c, shortNum(vals[i]), 12, p.T1)
					ui.Text(c, ftoa(pct(i), 1)+"%").Font(monoFont).FontSize(11).TextColor(p.T2).Width(44).TextAlign(ui.End).SingleLine()
				})
			}
		})
	}
	if size == sizeM {
		ui.Row(c.Key("m")).FillWidth().Grow(1).Gap(18).AlignItems(ui.Center).Children(func() {
			ui.Box(c.Key("wf")).Grow(1).Basis(0).Children(func() { p.waffle(c, "w", vals, cols, 100, 20, 3) })
			ui.Column(c.Key("r")).Grow(1).Basis(0).Children(func() { rows(26) })
		})
		return
	}
	p.waffle(c, "w", vals, cols, 100, 20, 4)
	ui.Box(c).Height(14)
	rows(34)
}

// waffle is n dots, cols across, one share each: the first shares filled in their colours, the last (cache read,
// the bulk) a hairline ring.
func (p palette) waffle(c *ui.Context, key string, vals [4]float64, cols [4]ui.Color, n, across int, gap float32) ui.Element {
	total := vals[0] + vals[1] + vals[2] + vals[3]
	counts := [4]int{}
	acc := 0.0
	for i := range 3 {
		acc += vals[i]
		counts[i] = int(math.Round(acc / total * float64(n)))
	}
	rowsN := (n + across - 1) / across
	box := ui.Box(c.Key(key)).FillWidth().Shrink(0)
	b := box.Bounds()
	d := (b.W - float32(across-1)*gap) / float32(across)
	if d <= 0 {
		d = 8
	}
	box.Height(float32(rowsN)*d + float32(rowsN-1)*gap)
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		d := (r.W - float32(across-1)*gap) / float32(across)
		for i := range n {
			dot := ui.Rect{X: r.X + float32(i%across)*(d+gap), Y: r.Y + float32(i/across)*(d+gap), W: d, H: d}
			switch {
			case i < counts[0]:
				pt.Fill(dot, cols[0], d/2)
			case i < counts[1]:
				pt.Fill(dot, cols[1], d/2)
			case i < counts[2]:
				pt.Fill(dot, cols[2], d/2)
			default:
				pt.Stroke(dot, p.L4, d/2, 1)
			}
		}
	})
	return box
}

// ── This month's cost ──

func (a *ctrl) costCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	mc := m.monthCost()
	acc := a.accent(p, "cost")
	r := a.ramp(p, "cost")
	spent := 0.0
	for _, d := range mc.Days {
		spent = d.Cumulative
	}
	now := m.now()
	lastName := format.MonthName(now.AddDate(0, -1, 0))
	// The month's cost by model: the top three and the rest.
	byModel := map[string]float64{}
	for _, d := range m.days(len(mc.Days)) {
		for k, v := range d.CostByModel {
			byModel[k] += v
		}
	}
	order := sortedKeys(byModel)
	type seg struct {
		id string
		v  float64
	}
	var segs []seg
	rest := 0.0
	for i, k := range order {
		if i < 3 {
			segs = append(segs, seg{k, byModel[k]})
		} else {
			rest += byModel[k]
		}
	}
	if rest > 0 {
		segs = append(segs, seg{"other", rest})
	}
	segCol := func(id string) ui.Color {
		if m.s.SeriesColors == "ink" && len(segs) == 1 {
			return acc
		}
		return pick(id == "other", p.Model.Other, m.modelColor(p, id))
	}
	scale := math.Max(math.Max(mc.Projected, mc.LastMonthTotal), spent) * 1.06
	costBar := func(height float32, marker bool) {
		ui.Box(c.Key("bar")).FillWidth().Height(height + pick(marker, float32(18), 4)).Shrink(0).Draw(func(pt *ui.Painter, rr ui.Rect) {
			if scale <= 0 {
				return
			}
			y := rr.Y + 4
			x := rr.X
			const gap = 2
			for _, s := range segs {
				w := float32(s.v/scale) * rr.W
				if w < 1 {
					continue
				}
				pt.Fill(ui.Rect{X: x, Y: y, W: w - gap, H: height}, segCol(s.id), 3)
				x += w
			}
			if mc.Projected > spent {
				w := float32((mc.Projected-spent)/scale) * rr.W
				pr := ui.Rect{X: x, Y: y, W: w - gap, H: height}
				hatch(pt, pr, 3, alpha(p.FG, 0.3))
				pt.Stroke(pr, p.L3, 3, 1)
				x += w
			}
			if left := rr.X + rr.W - x; left > 2 {
				pt.StrokeDashed(ui.Rect{X: x, Y: y, W: left, H: height}, p.L3, 3, 1)
			}
			if mc.LastMonthTotal > 0 {
				lx := rr.X + float32(mc.LastMonthTotal/scale)*rr.W
				pt.Fill(ui.Rect{X: lx, Y: y - 4, W: 1.5, H: height + 8}, p.Ink[0], 0.75)
				if marker {
					p.axisTextC(pt, lx, y+height+5, upper(lastName)+" "+format.Money(mc.LastMonthTotal), p.T2)
				}
			}
		})
	}
	head := func(fig float32) {
		ui.Row(c.Key("head")).FillWidth().Wrap().Gap(14).AlignItems(ui.End).Shrink(0).Children(func() {
			bigText(c.Key("spent"), format.Money(spent), fig, p.T1)
			note := L("proj. %@", format.Money(mc.Projected)) + " · " + L(lastName) + " " + format.Money(mc.LastMonthTotal)
			if size == sizeM || size == sizeW {
				note += " · " + L("day %lld of %lld", len(mc.Days), mc.DaysInMonth)
			}
			p.mono(c, note, pick(size == sizeS, float32(10.5), 12), p.T2).Padding(0, 0, 4)
		})
	}
	switch size {
	case sizeS:
		head(34)
		ui.Box(c).Grow(1)
		costBar(10, false)
	case sizeM, sizeW:
		head(38)
		ui.Box(c).Height(10)
		costBar(14, false)
		ui.Box(c).Height(8)
		ui.Row(c.Key("legend")).FillWidth().Gap(12).Children(func() {
			for _, s := range segs {
				ui.Row(c.Key(s.id)).Grow(1).Basis(0).MinWidth(0).Gap(6).AlignItems(ui.Center).Children(func() {
					if s.id == "other" {
						swatch(c, p.Model.Other, 7)
					} else {
						a.modelMark(c, p, s.id, 11)
					}
					p.mono(c, shortModel(m.modelName(s.id))+" "+format.Money(s.v), 11, p.T2).Ellipsis("…")
				})
			}
			if mc.Projected > spent {
				p.mono(c, "+"+format.Money(mc.Projected-spent), 11, p.T2)
			}
		})
	default:
		head(44)
		ui.Box(c).Height(10)
		costBar(16, true)
		ui.Column(c.Key("rows")).FillWidth().Children(func() {
			for _, s := range segs {
				ui.Row(c.Key(s.id)).FillWidth().Height(30).Gap(10).AlignItems(ui.Center).Children(func() {
					ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
					if s.id == "other" {
						swatch(c, p.Model.Other, 7)
						ui.Text(c, L("Other")).Font(monoFont).FontSize(12).TextColor(p.T1).Grow(1).SingleLine()
					} else {
						a.modelLabel(c, p, s.id, 12, p.T1).Grow(1)
					}
					p.mono(c, format.Money(s.v), 12, p.T1)
				})
			}
			if mc.Projected > spent {
				ui.Row(c.Key("proj")).FillWidth().Height(30).Gap(10).AlignItems(ui.Center).Children(func() {
					ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
					ui.Box(c).Size(7, 7).Shrink(0).Draw(func(pt *ui.Painter, rr ui.Rect) {
						hatch(pt, rr, 1.5, alpha(p.FG, 0.4))
						pt.Stroke(rr, p.L4, 1.5, 1)
					})
					ui.Text(c, L("Projected by %@", format.ShortDate(monthEnd(m.d.TodayKey)))).Font(monoFont).FontSize(12).TextColor(p.T2).Grow(1).SingleLine()
					p.mono(c, "+"+format.Money(mc.Projected-spent), 12, p.T1)
				})
			}
		})
		ui.Box(c).Grow(1)
		// The month's days: past days in the accent, today hatched to where it is heading, the rest to come.
		ui.Box(c.Key("days")).FillWidth().Height(34).Shrink(0).Draw(func(pt *ui.Painter, rr ui.Rect) {
			n := max(1, mc.DaysInMonth)
			const gap = 3
			bw := (rr.W - float32(n-1)*gap) / float32(n)
			dmax := mc.Projected / float64(n)
			for _, d := range mc.Days {
				dmax = math.Max(dmax, d.Cost)
			}
			dmax *= 1.1
			projDay := mc.Projected / float64(n)
			for i := range n {
				x := rr.X + float32(i)*(bw+gap)
				switch {
				case i < len(mc.Days)-1:
					h := max(2, float32(mc.Days[i].Cost/dmax)*rr.H)
					pt.Fill(ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}, r[2], 2)
				case i == len(mc.Days)-1:
					h := float32(projDay/dmax) * rr.H
					tr := ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}
					hatch(pt, tr, 2, alpha(r[2], 0.55))
					fh := float32(mc.Days[i].Cost/dmax) * rr.H
					pt.Fill(ui.Rect{X: x, Y: rr.Y + rr.H - fh, W: bw, H: fh}, r[3], 2)
					pt.Stroke(tr, p.sigLine(), 2, 1)
				default:
					h := float32(projDay/dmax) * rr.H
					pt.StrokeDashed(ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}, p.L3, 2, 1)
				}
			}
		})
	}
}

// shortModel drops the vendor prefix of a model id ("claude-opus-5" → "opus-5").
func shortModel(id string) string {
	for _, pre := range []string{"claude-", "gpt-", "gemini-"} {
		if strings.HasPrefix(id, pre) && pre != "gpt-" {
			return strings.TrimPrefix(id, pre)
		}
	}
	return id
}

// monthEnd is the last day of a day key's month.
func monthEnd(key string) string {
	t, ok := format.DateFromKey(key)
	if !ok {
		return key
	}
	return format.DayKey(t.AddDate(0, 1, -t.Day()))
}
