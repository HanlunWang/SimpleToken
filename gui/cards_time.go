package gui

import (
	"math"
	"sort"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/format"
)

// ── Calendar ──

func (a *ctrl) calendarCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	weeks := calendarWeeks(m.s.CalendarWeeks, size)
	metric := analytics.Metric(m.s.CalendarMetric)
	now := m.now()
	// Weeks start on Monday; the last column ends with today.
	days := m.days((weeks-1)*7 + format.WeekdayIndex(now) + 1)
	active, longest, run, streak := 0, 0, 0, 0
	weekSum := map[int]float64{}
	total := 0.0
	for i, d := range days {
		v := metric.Value(d)
		total += v
		weekSum[i/7] += v
		if d.Tokens > 0 {
			active++
			run++
			longest = max(longest, run)
		} else {
			run = 0
		}
	}
	for i := len(days) - 1; i >= 0 && days[i].Tokens > 0; i-- {
		streak++
	}
	best := 0.0
	for _, v := range weekSum {
		best = math.Max(best, v)
	}
	r := a.ramp(p, "calendar")
	grid := func(height float32) {
		p.calendarDots(c, "cal", days, metric, r, height, func(i int) (string, []tipRow) { return a.dayTip(p, days[i]) })
	}
	if size == sizeM {
		ui.Row(c.Key("m")).FillWidth().Grow(1).Gap(18).AlignItems(ui.Center).Children(func() {
			ui.Box(c.Key("g")).Grow(1).FillHeight().Children(func() { grid(0) })
			ui.Column(c.Key("side")).Gap(10).Shrink(0).Children(func() {
				ui.Column(c).Gap(2).Children(func() {
					p.mono(c, itoa(active)+" / "+itoa(len(days)), 16, p.T1)
					p.lbl(c, L("active days"))
				})
				ui.Column(c).Gap(2).Children(func() {
					p.mono(c, L("%lld days", streak), 16, p.T1)
					p.lbl(c, L("current streak"))
				})
			})
		})
		return
	}
	ui.Box(c.Key("g")).FillWidth().Grow(1).Children(func() { grid(0) })
	p.footRow(c, func() {
		p.factInline(c, itoa(active), L("active days"))
		p.factInline(c, L("%lld days", longest), L("longest streak"))
		p.factInline(c, a.figureText(metric, best), L("best week"))
		ui.Box(c).Grow(1)
		p.heatScale(c, r)
	})
}

// calendarDots is the calendar grid (Monday on top), dots sized and shaded by quartile of the active days, today
// ringed in the signal colour, month names above and weekday names on the left.
func (p palette) calendarDots(c *ui.Context, key string, days []analytics.DaySummary, metric analytics.Metric, ramp [4]ui.Color, _ float32, tip func(i int) (string, []tipRow)) ui.Element {
	box := ui.Box(c.Key(key)).FillWidth().Grow(1).MinHeight(60)
	if len(days) == 0 {
		return box
	}
	var nz []float64
	for _, d := range days {
		if v := metric.Value(d); v > 0 {
			nz = append(nz, v)
		}
	}
	sort.Float64s(nz)
	var q [3]float64
	for i, f := range []float64{0.25, 0.5, 0.75} {
		if len(nz) > 0 {
			q[i] = nz[int(f*float64(len(nz)))]
		}
	}
	level := func(v float64) int {
		switch {
		case v <= 0:
			return 0
		case v < q[0]:
			return 1
		case v < q[1]:
			return 2
		case v < q[2]:
			return 3
		}
		return 4
	}
	weeks := (len(days) + 6) / 7
	const labW, labH = 30, 16
	b := box.Bounds()
	// Columns spread across the width and rows down the height; the dots size to the smaller step.
	cw, ch := (b.W-labW)/float32(weeks), (b.H-labH)/7
	hover := -1
	if px, py, over := box.PointerPosition(); over && cw > 0 && ch > 0 {
		wk, wd := int((px-labW)/cw), int((py-labH)/ch)
		if i := wk*7 + wd; wk >= 0 && wd >= 0 && wd < 7 && i < len(days) {
			hover = i
		}
	}
	radii := [5]float32{1.3, 2.4, 3.1, 3.8, 4.4}
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 500 * time.Millisecond, Ease: ui.EaseOut})
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		cw, ch := (r.W-labW)/float32(weeks), (r.H-labH)/7
		k := min(cw, ch) / 12
		for i, l := range []string{"Mon", "", "Wed", "", "Fri", "", "Sun"} {
			if l != "" {
				pt.RichText(r.X, r.Y+labH+float32(i)*ch+ch/2-6, 0, ui.Span{Text: L(l), Font: monoFont, Size: 9.5, Color: p.T4})
			}
		}
		lastMonth := -1
		for wk := 0; wk < weeks; wk++ {
			t, ok := format.DateFromKey(days[min(len(days)-1, wk*7)].Date)
			if ok && int(t.Month()) != lastMonth && t.Day() <= 7 {
				if wk > 0 {
					pt.RichText(r.X+labW+float32(wk)*cw, r.Y, 0, ui.Span{Text: fmtr.MonthName(t), Font: monoFont, Size: 10, Color: p.T3})
				}
				lastMonth = int(t.Month())
			}
		}
		shown := int(float32(weeks) * grow)
		for i, d := range days {
			wk, wd := i/7, i%7
			if wk > shown {
				continue
			}
			lv := level(metric.Value(d))
			col := p.L4
			if lv > 0 {
				col = ramp[lv-1]
			}
			rr := radii[lv]*k + pick(i == hover, float32(1), 0)
			x, y := r.X+labW+float32(wk)*cw+cw/2, r.Y+labH+float32(wd)*ch+ch/2
			pt.Fill(ui.Rect{X: x - rr, Y: y - rr, W: 2 * rr, H: 2 * rr}, col, rr)
			if i == len(days)-1 {
				ring := 5.6 * k
				rc := ui.Rect{X: x - ring, Y: y - ring, W: 2 * ring, H: 2 * ring}
				pt.Shadow(rc, ring, 0, 0, 6, 0, alpha(p.Sig, 0.25))
				pt.Stroke(rc, p.Sig, ring, 1.2)
			}
		}
	})
	if hover >= 0 && tip != nil {
		box.Children(func() {
			title, rows := tip(hover)
			p.tooltip(c, labW+float32(hover/7)*cw, labH-4, b.W, title, rows)
		})
	}
	return box
}

// heatScale is the Less → More legend: the calendar's five dot sizes.
func (p palette) heatScale(c *ui.Context, ramp [4]ui.Color) ui.Element {
	return ui.Row(c.Key("heat")).Gap(6).AlignItems(ui.Center).Shrink(0).Children(func() {
		p.mono(c, L("Less"), 10, p.T3)
		ui.Box(c).Size(76, 10).Draw(func(pt *ui.Painter, r ui.Rect) {
			radii := []float32{1.3, 2.4, 3.1, 3.8, 4.4}
			xs := []float32{5, 21, 37, 54, 71}
			for i, rr := range radii {
				col := p.L4
				if i > 0 {
					col = ramp[i-1]
				}
				pt.Fill(ui.Rect{X: r.X + xs[i] - rr, Y: r.Y + 5 - rr, W: 2 * rr, H: 2 * rr}, col, rr)
			}
		})
		p.mono(c, L("More"), 10, p.T3)
	})
}

// ── Time of day ──

// weekProfile is Claude Code's average tokens per half hour of each weekday (Monday first) over the last n days,
// with how many of those days each weekday had, and today's half hours so far.
func (a *ctrl) weekProfile(n int) (avg [7][48]float64, today [48]float64) {
	m := a.m
	ex := map[string]bool{}
	for _, x := range m.s.ExcludedModels {
		ex[x] = true
	}
	var count [7]float64
	now := m.now()
	for back := 1; back <= n; back++ {
		t := now.AddDate(0, 0, -back)
		wd := format.WeekdayIndex(t)
		count[wd]++
		for i, v := range m.d.Intra.Buckets(format.DayKey(t), ex) {
			if i < 48 {
				avg[wd][i] += float64(v)
			}
		}
	}
	for wd := range 7 {
		for i := range 48 {
			avg[wd][i] /= math.Max(1, count[wd])
		}
	}
	for i, v := range m.d.Intra.Buckets(m.d.TodayKey, ex) {
		if i < 48 {
			today[i] = float64(v)
		}
	}
	return avg, today
}

func (a *ctrl) punchCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	now := m.now()
	avg, today := a.weekProfile(28)
	r := a.ramp(p, "punchcard")
	todayWd := format.WeekdayIndex(now)
	nowSlot := now.Hour()*2 + now.Minute()/30
	// Today's lane shows today itself up to now.
	lanes := avg
	for i := range 48 {
		lanes[todayWd][i] = pick(i <= nowSlot, today[i], 0)
	}
	mx := 1e-9
	var hourAvg [24]float64
	for wd := range 7 {
		for i := range 48 {
			mx = math.Max(mx, lanes[wd][i])
			if wd < 5 {
				hourAvg[i/2] += avg[wd][i] / 5
			}
		}
	}
	if mx <= 1e-9 {
		p.empty(c, L("No usage in this range"))
		return
	}
	if size == sizeM {
		hm := 1e-9
		for _, v := range hourAvg {
			hm = math.Max(hm, v)
		}
		ui.Box(c.Key("hours")).FillWidth().Grow(1).Draw(func(pt *ui.Painter, rr ui.Rect) {
			const gap = 3
			bw := (rr.W - 23*gap) / 24
			for h, v := range hourAvg {
				f := v / hm
				col := p.L3
				switch {
				case f > 0.66:
					col = r[3]
				case f > 0.33:
					col = r[2]
				case f > 0.08:
					col = r[1]
				}
				bh := max(rr.H*0.04, float32(f)*rr.H)
				bar := ui.Rect{X: rr.X + float32(h)*(bw+gap), Y: rr.Y + rr.H - bh, W: bw, H: bh}
				pt.Fill(bar, col, 2)
				if h == now.Hour() {
					pt.Stroke(ui.Rect{X: bar.X - 2.5, Y: bar.Y - 2.5, W: bar.W + 5, H: bar.H + 5}, p.Sig, 3, 1)
				}
			}
		})
		ui.Row(c.Key("x")).FillWidth().Justify(ui.SpaceBetween).Margin(8, 0, 0).Children(func() {
			for _, l := range []string{"00", "06", "12", pad2(now.Hour()) + " · " + L("now"), "18", "23"} {
				p.mono(c, l, 10, pick(len(l) > 2, p.T1, p.T4))
			}
		})
		return
	}
	// Lanes: weekday labels, the lanes, each weekday's active hours.
	var hours [7]float64
	for wd := range 7 {
		for i := range 48 {
			if lanes[wd][i]/mx >= 0.16 {
				hours[wd] += 0.5
			}
		}
	}
	ui.Row(c.Key("now")).FillWidth().Height(14).Shrink(0).Children(func() {
		ui.Box(c).Width(36)
		ui.Box(c.Key("nl")).Grow(1).FillHeight().Draw(func(pt *ui.Painter, rr ui.Rect) {
			x := rr.X + 12 + float32(nowSlot)/47*(rr.W-24)
			p.axisTextC(pt, x, rr.Y, L("NOW")+" "+format.Clock(now), p.T1)
		})
		ui.Box(c).Width(44)
	})
	ui.Row(c.Key("lanes")).FillWidth().Grow(1).Gap(8).Children(func() {
		ui.Column(c.Key("wd")).Width(28).FillHeight().Justify(ui.SpaceAround).Children(func() {
			for wd, l := range format.WeekdaysFromMonday {
				p.mono(c, L(l), 10, pick(wd == todayWd, p.T1, p.T3))
			}
		})
		ui.Box(c.Key("grid")).Grow(1).FillHeight().Draw(func(pt *ui.Painter, rr ui.Rect) {
			row := rr.H / 7
			laneH := min(18, row*0.7)
			x := func(s int) float32 { return rr.X + 12 + float32(s)/47*(rr.W-24) }
			xNow := x(nowSlot)
			for wd := range 7 {
				ly := rr.Y + float32(wd)*row + (row-laneH)/2
				pt.Fill(ui.Rect{X: rr.X, Y: ly, W: rr.W, H: laneH}, p.BG, laneH/2)
				cy := ly + laneH/2
				var ticks [3][][2]float32
				for s := range 48 {
					if wd == todayWd && s > nowSlot {
						continue
					}
					f := lanes[wd][s] / mx
					if f < 0.16 {
						continue
					}
					lv := pick(f < 0.42, 0, pick(f < 0.78, 1, 2))
					half := []float32{2.2, 4.6, 7}[lv] * laneH / 18
					ticks[lv] = append(ticks[lv], [2]float32{x(s), cy - half}, [2]float32{x(s), cy + half}, [2]float32{float32(math.NaN()), 0})
				}
				for lv := range 3 {
					pt.StrokePolyline(ticks[lv], 2.6, r[lv+1])
				}
				if wd == todayWd {
					fut := ui.Rect{X: xNow + 5, Y: ly + 1, W: rr.X + rr.W - xNow - 6, H: laneH - 2}
					if fut.W > 4 {
						pt.StrokeDashed(fut, p.L4, (laneH-2)/2, 1)
					}
				}
			}
			pt.Line(xNow, rr.Y-2, xNow, rr.Y+rr.H, 1, p.sigLine())
			dy := rr.Y + float32(todayWd)*row + row/2
			dot := ui.Rect{X: xNow - 3.2, Y: dy - 3.2, W: 6.4, H: 6.4}
			pt.Shadow(dot, 3.2, 0, 0, 6, 0, p.glow())
			pt.Fill(dot, p.Sig, 3.2)
		})
		ui.Column(c.Key("hrs")).Width(36).FillHeight().Justify(ui.SpaceAround).AlignItems(ui.End).Children(func() {
			for wd := range 7 {
				p.mono(c, ftoa(hours[wd], 1)+"h", 10, p.T2)
			}
		})
	})
	ui.Row(c.Key("x")).FillWidth().Margin(4, 0, 0).Shrink(0).Children(func() {
		ui.Box(c).Width(36)
		ui.Row(c).Grow(1).Justify(ui.SpaceBetween).Children(func() {
			for _, l := range []string{"00", "06", "12", "18", "24"} {
				p.mono(c, l, 10, p.T4)
			}
		})
		ui.Box(c).Width(44)
	})
	// Facts: the two busiest half hours of a weekday (apart), the active hours per weekday.
	type slotV struct {
		s int
		v float64
	}
	var all []slotV
	for s := range 48 {
		v := 0.0
		for wd := range 5 {
			v += avg[wd][s]
		}
		all = append(all, slotV{s, v})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].v > all[j].v })
	peaks := []int{}
	for _, x := range all {
		if x.v <= 0 || len(peaks) == 2 {
			break
		}
		if len(peaks) == 0 || absInt(x.s-peaks[0]) >= 4 {
			peaks = append(peaks, x.s)
		}
	}
	sort.Ints(peaks)
	label := func(s int) string { return pad2(s/2) + ":" + pick(s%2 == 1, "30", "00") }
	wkHours := 0.0
	for wd := range 5 {
		wkHours += hours[wd] / 5
	}
	p.footRow(c, func() {
		switch len(peaks) {
		case 2:
			p.factInline(c, label(peaks[0])+" · "+label(peaks[1]), L("two peaks"))
		case 1:
			p.factInline(c, label(peaks[0]), L("busiest half hour"))
		}
		p.factInline(c, ftoa(wkHours, 1)+"h", L("active per weekday"))
	})
}

func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
