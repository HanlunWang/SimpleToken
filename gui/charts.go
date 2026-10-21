package gui

import (
	"math"
	"sort"
	"time"

	"github.com/egoist/mygo/ui"
)

// Chart kit. Mark rules: thin marks, 2 px surface gaps between fills, dashed 1 px rules, recessive mono axes;
// colour only for identity (series) or state (the signal: now, focus, over the alert threshold). Each chart is
// one element painted from Draw and hit-tested by coordinates (PointerPosition), so a chart of 400 days costs one
// element, not 400.

// tipRow is one line of a chart tooltip.
type tipRow struct {
	Color ui.Color // series swatch (zero: none)
	Logo  string   // vendor mark beside the swatch
	LogoC ui.Color
	Label string
	Value string
	Dim   bool
}

// tooltip is the floating card a chart shows for the hovered mark: elevated, hairline border, mono numbers.
// x, y are in the chart's coordinates; it keeps inside width cw.
func (p palette) tooltip(c *ui.Context, x, y, cw float32, title string, rows []tipRow) {
	const w = 190
	left := max(4, min(cw-w-4, x+12))
	ui.Column(c.Key("tip")).Absolute().Left(left).Top(y).Width(w).Padding(7, 9).Gap(3).Radius(5).
		Background(p.Elev).Border(1, p.L3).Shadow(0, 8, 24, 0, ui.RGBA(0, 0, 0, pick(p.Dark, float32(0.45), 0.12))).
		PassThrough().Children(func() {
		if title != "" {
			ui.Text(c, title).Font(monoFont).FontSize(10).LetterSpacing(0.4).TextColor(p.T3).SingleLine()
		}
		for i, r := range rows {
			if r.Label == "" && r.Value == "" {
				ui.Box(c.Key(i)).FillWidth().Height(1).Margin(2, 0).Background(p.L2)
				continue
			}
			ui.Row(c.Key(i)).FillWidth().Gap(6).AlignItems(ui.Center).Children(func() {
				if r.Color.A > 0 {
					swatch(c, r.Color, 7)
				}
				if r.Logo != "" {
					logo(c, r.Logo, 11, r.LogoC)
				}
				ui.Text(c, r.Label).Font(monoFont).FontSize(11).TextColor(pick(r.Dim, p.T3, p.T2)).SingleLine().Grow(1).MinWidth(0).Ellipsis("…")
				ui.Text(c, r.Value).Font(monoFont).FontSize(11).TextColor(p.T1).SingleLine()
			})
		}
	})
}

// axisText draws a mono tick label.
func (p palette) axisText(pt *ui.Painter, x, y float32, s string, anchor int) {
	sp := ui.Span{Text: s, Font: monoFont, Size: 9.5, Color: p.T4}
	w, _ := pt.MeasureText(0, sp)
	switch anchor {
	case 1:
		x -= w / 2
	case 2:
		x -= w
	}
	pt.RichText(x, y, 0, sp)
}

// dashH draws a horizontal dashed rule.
func dashH(pt *ui.Painter, x0, x1, y float32, col ui.Color, dash, gap float32) {
	for x := x0; x < x1; x += dash + gap {
		pt.Line(x, y, min(x+dash, x1), y, 1, col)
	}
}

func dashPath(pt *ui.Painter, pts [][2]float32, col ui.Color, width, dash, gap float32) {
	on, left := true, dash
	for i := 1; i < len(pts); i++ {
		x0, y0, x1, y1 := pts[i-1][0], pts[i-1][1], pts[i][0], pts[i][1]
		seg := float32(math.Hypot(float64(x1-x0), float64(y1-y0)))
		pos := float32(0)
		for pos < seg {
			step := min(left, seg-pos)
			if on {
				t0, t1 := pos/seg, (pos+step)/seg
				pt.Line(x0+(x1-x0)*t0, y0+(y1-y0)*t0, x0+(x1-x0)*t1, y0+(y1-y0)*t1, width, col)
			}
			pos += step
			left -= step
			if left <= 0 {
				on = !on
				left = pick(on, dash, gap)
			}
		}
	}
}

func niceMax(v float64) float64 {
	if v <= 0 {
		return 1
	}
	pw := math.Pow(10, math.Floor(math.Log10(v)))
	m := v / pw
	switch {
	case m <= 1:
		m = 1
	case m <= 2:
		m = 2
	case m <= 2.5:
		m = 2.5
	case m <= 5:
		m = 5
	default:
		m = 10
	}
	return m * pw
}

// ── Cumulative area: this period vs the previous one, faint daily columns, optional projection ──

type areaOpts struct {
	Values    []float64 // per bucket (not cumulative)
	Compare   []float64 // the previous period, per bucket
	ProjectTo int       // total buckets of the period, for a dashed projection to its end (0: none)
	Axes      bool
	Columns   bool
	Labels    func(i int) string // x labels (start, middle, end)
	Tick      func(v float64) string
	Color     ui.Color
	Tip       func(i int, cum float64) (string, []tipRow)
	// Pace draws a dashed straight line from 0 to Pace at the period's end (even pace to a target).
	Pace float64
}

func (p palette) areaChart(c *ui.Context, key string, o areaOpts) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(40)
	n := max(len(o.Values), o.ProjectTo)
	cum := cumulative(o.Values)
	ccum := cumulative(o.Compare)
	last := 0.0
	if len(cum) > 0 {
		last = cum[len(cum)-1]
	}
	proj := 0.0
	if o.ProjectTo > 0 && len(o.Values) > 0 {
		proj = last * float64(o.ProjectTo) / float64(len(o.Values))
	}
	top := last
	if len(ccum) > 0 {
		top = math.Max(top, ccum[len(ccum)-1])
	}
	maxV := niceMax(math.Max(math.Max(top, proj), o.Pace) * 1.04)
	colMax := 1.0
	for _, v := range o.Values {
		colMax = math.Max(colMax, v)
	}
	padR := pick(o.Axes, float32(40), 0)
	padB := pick(o.Labels != nil, float32(18), 2)
	grow := box.AnimateTo("grow", 1, animData)
	b := box.Bounds()
	X := func(i int, iw float32) float32 {
		if n <= 1 {
			return 0
		}
		return float32(i) / float32(n-1) * iw
	}
	hover := -1
	if px, _, over := box.PointerPosition(); over && n > 1 {
		iw := b.W - padR
		hover = int(math.Round(float64(px / iw * float32(n-1))))
		if hover < 0 || hover >= len(o.Values) {
			hover = -1
		}
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		iw, ih := r.W-padR, r.H-padB-6
		y0 := r.Y + 6
		Y := func(v float64) float32 { return y0 + ih - float32(v/maxV)*ih*grow }
		if o.Axes {
			for _, f := range []float64{0.5, 1} {
				yy := Y(maxV * f)
				dashH(pt, r.X, r.X+iw, yy, p.L2, 2, 3)
				p.axisText(pt, r.X+iw+6, yy-6, o.Tick(maxV*f), 0)
			}
		}
		if o.Columns {
			bw := iw / float32(n)
			for i, v := range o.Values {
				h := float32(v/colMax) * ih * 0.32 * grow
				pt.Fill(ui.Rect{X: r.X + X(i, iw) - max(0.75, bw/2-1.5), Y: y0 + ih - h, W: max(1.5, bw-3), H: h}, pick(i == hover, p.L4, p.L3), 1)
			}
		}
		line := func(arr []float64) [][2]float32 {
			pts := make([][2]float32, len(arr))
			for i, v := range arr {
				pts[i] = [2]float32{r.X + X(i, iw), Y(v)}
			}
			return pts
		}
		if len(ccum) > 1 {
			dashPath(pt, line(ccum), p.T3, 1.2, 3, 3)
		}
		if o.Pace > 0 {
			dashPath(pt, [][2]float32{{r.X, Y(0)}, {r.X + X(n-1, iw), Y(o.Pace)}}, alpha(p.Sig, 0.5), 1, 2, 4)
		}
		if len(cum) > 0 {
			pts := line(cum)
			var area ui.Path
			area.MoveTo(pts[0][0], y0+ih)
			for _, q := range pts {
				area.LineTo(q[0], q[1])
			}
			area.LineTo(pts[len(pts)-1][0], y0+ih).Close()
			pt.FillPath(&area, alpha(o.Color, 0.09))
			pt.StrokePolyline(pts, 2, o.Color)
			lx, ly := pts[len(pts)-1][0], pts[len(pts)-1][1]
			if o.ProjectTo > 0 {
				dashPath(pt, [][2]float32{{lx, ly}, {r.X + X(n-1, iw), Y(proj)}}, alpha(o.Color, 0.6), 1.2, 2, 4)
			}
			// The live end point: the one thing that glows.
			dot := ui.Rect{X: lx - 3.5, Y: ly - 3.5, W: 7, H: 7}
			pt.Shadow(dot, 3.5, 0, 0, 6, 0, p.glow())
			pt.Fill(dot, p.Sig, 3.5)
		}
		if hover >= 0 {
			hx := r.X + X(hover, iw)
			pt.Line(hx, y0, hx, y0+ih, 1, p.L4)
			hd := ui.Rect{X: hx - 3, Y: Y(cum[hover]) - 3, W: 6, H: 6}
			pt.Fill(hd, p.BG, 3)
			pt.Stroke(hd, o.Color, 3, 1.5)
		}
		if o.Labels != nil && n > 0 {
			for k, i := range []int{0, (n - 1) / 2, n - 1} {
				p.axisText(pt, r.X+X(i, iw), r.Y+r.H-13, o.Labels(i), k)
			}
		}
	})
	if hover >= 0 && o.Tip != nil {
		box.Children(func() {
			title, rows := o.Tip(hover, cum[hover])
			p.tooltip(c, X(hover, b.W-padR), 6, b.W, title, rows)
		})
	}
	return box
}

func cumulative(v []float64) []float64 {
	out := make([]float64, len(v))
	s := 0.0
	for i, x := range v {
		s += x
		out[i] = s
	}
	return out
}

// ── Stacked bars ──

type seriesKey struct {
	ID    string
	Color ui.Color
}

type barOpts struct {
	Buckets int
	Keys    []seriesKey
	Value   func(bucket, key int) float64
	Focus   string
	AvgLine bool
	Axes    bool
	Label   func(i int) string
	Tick    func(v float64) string
	Tip     func(i int) (string, []tipRow)
	// Now (with HasNow) marks the current bucket with a signal cap; buckets after it are future (faint stubs).
	Now    int
	HasNow bool
	// LabelAt, when set, picks which buckets get an x label (instead of start, middle, end).
	LabelAt func(i int) bool
}

func (p palette) barChart(c *ui.Context, key string, o barOpts) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(30)
	totals := make([]float64, o.Buckets)
	maxV, sum := 0.0, 0.0
	for i := range o.Buckets {
		for k := range o.Keys {
			totals[i] += o.Value(i, k)
		}
		maxV = math.Max(maxV, totals[i])
		sum += totals[i]
	}
	maxV = niceMax(maxV)
	avg := sum / math.Max(1, float64(o.Buckets))
	padR := pick(o.Axes, float32(38), 0)
	padB := pick(o.Axes, float32(16), 0)
	grow := box.AnimateTo("grow", 1, animData)
	b := box.Bounds()
	hover := -1
	if px, _, over := box.PointerPosition(); over && o.Buckets > 0 {
		hover = int(px / ((b.W - padR) / float32(o.Buckets)))
		if hover >= o.Buckets {
			hover = -1
		}
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		iw, ih := r.W-padR, r.H-padB-4
		y0 := r.Y + 4
		if o.Axes {
			for _, f := range []float64{0.5, 1} {
				yy := y0 + ih - float32(f)*ih
				pt.Line(r.X, yy, r.X+iw, yy, 1, p.L2)
				p.axisText(pt, r.X+iw+6, yy-6, o.Tick(maxV*f), 0)
			}
		}
		bw := iw / float32(max(1, o.Buckets))
		gap := pick(bw > 6, float32(2), 1)
		for i := range o.Buckets {
			if o.HasNow && i > o.Now {
				pt.Fill(ui.Rect{X: r.X + float32(i)*bw + gap/2, Y: y0 + ih - 2, W: max(1, bw-gap), H: 2}, p.L2, 1)
				continue
			}
			if o.HasNow && i == o.Now {
				top := 0.0
				for k := range o.Keys {
					top += o.Value(i, k)
				}
				cy := y0 + ih - float32(top/maxV)*ih*grow - 4
				cap := ui.Rect{X: r.X + float32(i)*bw + gap/2, Y: cy, W: max(1, bw-gap), H: 2}
				pt.Shadow(cap, 1, 0, 0, 4, 0, p.glow())
				pt.Fill(cap, p.Sig, 1)
			}
			y := y0 + ih
			dim := hover >= 0 && hover != i
			for k, s := range o.Keys {
				v := o.Value(i, k)
				if v <= 0 {
					continue
				}
				h := float32(v/maxV) * ih * grow
				col := s.Color
				if o.Focus != "" && o.Focus != s.ID {
					col = alpha(col, 0.18)
				}
				if dim {
					col = alpha(col, 0.38)
				}
				y -= h
				pt.Fill(ui.Rect{X: r.X + float32(i)*bw + gap/2, Y: y + pick(k > 0, float32(0), 0), W: max(1, bw-gap), H: max(1, h-pick(k > 0, gap, 0))}, col, pick(bw < 5, float32(0.5), 1.5))
			}
		}
		if o.AvgLine && avg > 0 {
			ay := y0 + ih - float32(avg/maxV)*ih
			dashH(pt, r.X, r.X+iw, ay, p.T2, 3, 3)
			p.axisText(pt, r.X+2, ay-13, "AVG "+o.Tick(avg), 0)
		}
		pt.Line(r.X, y0+ih+0.5, r.X+iw, y0+ih+0.5, 1, p.L3)
		if o.Axes && o.Label != nil && o.Buckets > 0 {
			if o.LabelAt != nil {
				for i := range o.Buckets {
					if o.LabelAt(i) {
						p.axisText(pt, r.X+float32(i)*bw, r.Y+r.H-12, o.Label(i), 0)
					}
				}
			} else {
				for k, i := range []int{0, o.Buckets / 2, o.Buckets - 1} {
					p.axisText(pt, r.X+float32(i)*bw+bw/2, r.Y+r.H-12, o.Label(i), k)
				}
			}
		}
	})
	if hover >= 0 && o.Tip != nil {
		box.Children(func() {
			title, rows := o.Tip(hover)
			p.tooltip(c, float32(hover)*(b.W-padR)/float32(o.Buckets), 6, b.W, title, rows)
		})
	}
	return box
}

// ── Small multiples ──

type sparkOpts struct {
	Emph   int     // emphasised bar (signal colour), -1 none
	Rule   float64 // dashed average rule (0: none)
	Height float32
	Dots   bool // draw each bar as a column of dots (Nothing's dot bars)
	Color  ui.Color
	Labels []string
}

// sparkBars returns the element and the hovered index (-1).
func (p palette) sparkBars(c *ui.Context, key string, vals []float64, o sparkOpts) (ui.Element, int) {
	lh := pick(len(o.Labels) > 0, float32(14), 0)
	box := ui.Box(c.Key(key)).FillWidth().Height(o.Height + lh).Shrink(0)
	maxV := o.Rule
	for _, v := range vals {
		maxV = math.Max(maxV, v)
	}
	maxV = math.Max(maxV, 1e-9)
	grow := box.AnimateTo("grow", 1, animData)
	hover := -1
	if px, _, over := box.PointerPosition(); over && len(vals) > 0 {
		hover = min(len(vals)-1, int(px/(box.Bounds().W/float32(len(vals)))))
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		n := len(vals)
		if n == 0 {
			return
		}
		h := o.Height
		bw := r.W / float32(n)
		const D, G = 3.2, 1.6
		rows := int(h / (D + G))
		for i, v := range vals {
			col := o.Color
			lit := i == o.Emph
			if lit {
				col = p.Sig
			} else if hover >= 0 && i != hover {
				col = alpha(col, 0.5)
			}
			if o.Dots {
				on := int(math.Round(v / maxV * float64(rows) * float64(grow)))
				cols := max(1, int((bw-G)/(D+G)))
				off := (bw - float32(cols)*(D+G) + G) / 2
				for rr := range rows {
					for cc := range cols {
						d := ui.Rect{X: r.X + float32(i)*bw + off + float32(cc)*(D+G), Y: r.Y + h - float32(rr+1)*(D+G) + G, W: D, H: D}
						if rr < on {
							if lit {
								pt.Shadow(d, D/2, 0, 0, 3, 0, p.glowSoft())
							}
							pt.Fill(d, col, D/2)
						} else {
							pt.Fill(d, p.DotOff, D/2)
						}
					}
				}
				continue
			}
			bh := max(pick(v > 0, float32(1.5), 0), float32(v/maxV)*h*grow)
			pt.Fill(ui.Rect{X: r.X + float32(i)*bw + 1, Y: r.Y + h - bh, W: max(1, bw-2), H: bh}, col, 1.5)
		}
		if o.Rule > 0 {
			dashH(pt, r.X, r.X+r.W, r.Y+h-float32(o.Rule/maxV)*h, p.T3, 2, 3)
		}
		for i, l := range o.Labels {
			col := pick(i == o.Emph, p.T1, p.T4)
			sp := ui.Span{Text: l, Font: monoFont, Size: 9.5, Color: col}
			w, _ := pt.MeasureText(0, sp)
			pt.RichText(r.X+float32(i)*bw+(bw-w)/2, r.Y+h+2, 0, sp)
		}
	})
	return box, hover
}

// sparkLine is a line with a faint area; live puts the glowing dot at its end.
func (p palette) sparkLine(c *ui.Context, key string, vals []float64, height float32, col ui.Color, live, fill bool) ui.Element {
	return ui.Box(c.Key(key)).FillWidth().Height(height).Shrink(0).Draw(func(pt *ui.Painter, r ui.Rect) {
		if len(vals) < 2 {
			return
		}
		lo, hi := 0.0, 1e-12
		for _, v := range vals {
			lo, hi = math.Min(lo, v), math.Max(hi, v)
		}
		pts := make([][2]float32, len(vals))
		for i, v := range vals {
			pts[i] = [2]float32{r.X + float32(i)/float32(len(vals)-1)*(r.W-4), r.Y + 3 + (r.H-6)*float32(1-(v-lo)/(hi-lo))}
		}
		if fill {
			var a ui.Path
			a.MoveTo(pts[0][0], r.Y+r.H)
			for _, q := range pts {
				a.LineTo(q[0], q[1])
			}
			a.LineTo(pts[len(pts)-1][0], r.Y+r.H).Close()
			pt.FillPath(&a, alpha(col, 0.08))
		}
		pt.StrokePolyline(pts, 1.6, col)
		if live {
			e := pts[len(pts)-1]
			d := ui.Rect{X: e[0] - 2.6, Y: e[1] - 2.6, W: 5.2, H: 5.2}
			pt.Shadow(d, 2.6, 0, 0, 5, 0, p.glow())
			pt.Fill(d, p.Sig, 2.6)
		}
	})
}

// part is one slice of a whole.
type part struct {
	ID    string
	V     float64
	Color ui.Color
	Band  ui.Color // thin vendor band outside a donut sector (zero: none)
}

// segmentBar draws proportional segments with 2 px gaps; returns the hovered id.
func (p palette) segmentBar(c *ui.Context, key string, parts []part, height float32, focus string) (ui.Element, string) {
	box := ui.Box(c.Key(key)).FillWidth().Height(height).Shrink(0)
	total := 0.0
	for _, s := range parts {
		total += s.V
	}
	hover := ""
	px, _, over := box.PointerPosition()
	w := box.Bounds().W
	if over && total > 0 {
		x := float32(0)
		for _, s := range parts {
			sw := float32(s.V/total) * w
			if px >= x && px < x+sw {
				hover = s.ID
			}
			x += sw
		}
	}
	grow := box.AnimateTo("grow", 1, animData)
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		if total <= 0 {
			return
		}
		x := r.X
		for _, s := range parts {
			sw := float32(s.V/total) * r.W * grow
			col := s.Color
			if (focus != "" && focus != s.ID) || (hover != "" && hover != s.ID) {
				col = alpha(col, 0.25)
			}
			pt.Fill(ui.Rect{X: x, Y: r.Y, W: max(1, sw-2), H: r.H}, col, 1)
			x += sw
		}
	})
	return box, hover
}

// donut is a thin ring with 2 px gaps; the hovered or focused sector lifts outward, its vendor band rides outside.
// Clicking a sector toggles focus. center builds the label in the middle.
func (p palette) donut(c *ui.Context, key string, parts []part, size, thick float32, focus *string, center func(hover string)) (ui.Element, string) {
	box := ui.Box(c.Key(key)).Size(size, size).Shrink(0)
	total := 0.0
	for _, s := range parts {
		total += s.V
	}
	rad := size/2 - thick/2 - 4
	hover := ""
	if px, py, over := box.PointerPosition(); over && total > 0 {
		dx, dy := float64(px-size/2), float64(py-size/2)
		d := math.Hypot(dx, dy)
		if d > float64(rad-thick) && d < float64(rad+thick) {
			a := math.Atan2(dy, dx) + math.Pi/2
			if a < 0 {
				a += 2 * math.Pi
			}
			acc := 0.0
			for _, s := range parts {
				acc += s.V / total * 2 * math.Pi
				if a <= acc {
					hover = s.ID
					break
				}
			}
		}
	}
	if box.Clicked() && hover != "" && focus != nil {
		*focus = pick(*focus == hover, "", hover)
	}
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 600 * time.Millisecond, Ease: ui.EaseOut})
	f := ""
	if focus != nil {
		f = *focus
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		cx, cy := r.X+r.W/2, r.Y+r.H/2
		ring := func(radius float32, a0, a1 float64, width float32, col ui.Color, dx, dy float32) {
			var path ui.Path
			steps := max(2, int((a1-a0)*40))
			for i := 0; i <= steps; i++ {
				a := a0 + (a1-a0)*float64(i)/float64(steps)
				x, y := cx+dx+radius*float32(math.Cos(a)), cy+dy+radius*float32(math.Sin(a))
				if i == 0 {
					path.MoveTo(x, y)
				} else {
					path.LineTo(x, y)
				}
			}
			pt.StrokePath(&path, width, col)
		}
		ring(rad, 0, 2*math.Pi, thick, p.L1, 0, 0)
		if total <= 0 {
			return
		}
		a := -math.Pi / 2
		gapA := 2 / float64(rad)
		for _, s := range parts {
			span := s.V / total * 2 * math.Pi * float64(grow)
			s0, s1 := a+gapA/2, a+span-gapA/2
			a += span
			if s1 <= s0 {
				continue
			}
			mid := (s0 + s1) / 2
			lift := pick(hover == s.ID || f == s.ID, float32(3), 0)
			dx, dy := float32(math.Cos(mid))*lift, float32(math.Sin(mid))*lift
			col := s.Color
			dim := f != "" && f != s.ID
			if dim {
				col = alpha(col, 0.22)
			}
			ring(rad, s0, s1, thick, col, dx, dy)
			if s.Band.A > 0 {
				ring(rad+thick/2+2.5, s0, s1, 2, pick(dim, alpha(s.Band, 0.22), s.Band), dx, dy)
			}
		}
	})
	box.Children(func() {
		ui.Column(c).Absolute().Left(0).Top(0).Size(size, size).AlignItems(ui.Center).Justify(ui.Center).PassThrough().Children(func() { center(hover) })
	})
	return box, hover
}

// ── Limits ──

// dotGauge is the logo's ¾ arc as dots: used dots lit in ink, all signal once over the alert threshold;
// hollow dots project where the current pace ends; a signal tick outside marks even pace.
func (p palette) dotGauge(c *ui.Context, key string, used, pace float64, hot bool, size float32, label, sub string, showPace bool) ui.Element {
	const n = 27
	lh := pick(label != "", float32(13), 0) + pick(sub != "", float32(12), 0)
	box := ui.Box(c.Key(key)).Size(size, size*0.84+lh).Shrink(0)
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 500 * time.Millisecond, Ease: ui.EaseOut})
	proj := used
	if pace > 0.1 {
		proj = math.Min(100, used/pace)
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		cx, cy := r.X+size/2, r.Y+size/2
		rad := size/2 - 6
		dot := max(2.6, size/26)
		pos := func(f float64, rr float32) (float32, float32) {
			a := (-225 + f*270) * math.Pi / 180
			return cx + rr*float32(math.Cos(a)), cy + rr*float32(math.Sin(a))
		}
		for i := range n {
			f := float64(i) / (n - 1)
			x, y := pos(f, rad)
			d := ui.Rect{X: x - dot/2, Y: y - dot/2, W: dot, H: dot}
			lit := f*100 <= used*float64(grow)+0.01
			switch {
			case lit && hot:
				pt.Shadow(d, dot/2, 0, 0, 3, 0, p.glowSoft())
				pt.Fill(d, p.Sig, dot/2)
			case lit:
				pt.Fill(d, p.T1, dot/2)
			case f*100 <= proj && showPace:
				pt.Stroke(d, p.T3, dot/2, 0.8)
			default:
				pt.Fill(d, p.DotOff, dot/2)
			}
		}
		if showPace && pace > 0 {
			x0, y0 := pos(pace, rad+1.5)
			x1, y1 := pos(pace, rad+6)
			pt.Line(x0, y0, x1, y1, 1.6, p.Sig)
		}
	})
	box.Children(func() {
		ui.Row(c).Absolute().Left(0).Top(size/2 - size*0.15).Width(size).Justify(ui.Center).AlignItems(ui.End).PassThrough().Children(func() {
			ui.Text(c, itoa(int(math.Round(used)))).Font(dotFont).FontSize(size * 0.27).TextColor(pick(hot, p.Sig, p.T1)).SingleLine()
			ui.Text(c, "%").Font(monoFont).FontSize(max(9, size*0.11)).TextColor(p.T3).SingleLine()
		})
		ui.Column(c).Absolute().Left(-10).Top(size * 0.84).Width(size + 20).AlignItems(ui.Center).Gap(1).PassThrough().Children(func() {
			if label != "" {
				ui.Text(c, label).Font(monoFont).FontSize(9.5).LetterSpacing(0.6).TextColor(p.T2).SingleLine()
			}
			if sub != "" {
				ui.Text(c, sub).Font(monoFont).FontSize(9.5).TextColor(p.T4).SingleLine()
			}
		})
	})
	return box
}

// paceMeter is a row of cells: filled in ink (signal over the threshold), hollow cells to the projection, and a
// signal tick at even pace.
func (p palette) paceMeter(c *ui.Context, key string, used, pace float64, hot bool, cells int, showPace bool) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).MinWidth(40).Height(9)
	grow := box.AnimateTo("grow", 1, animData)
	proj := used
	if pace > 0.1 {
		proj = math.Min(100, used/pace)
	}
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		const gap = 2
		cw := (r.W - float32(cells-1)*gap) / float32(cells)
		for i := range cells {
			f := (float64(i) + 0.5) / float64(cells) * 100
			cell := ui.Rect{X: r.X + float32(i)*(cw+gap), Y: r.Y, W: cw, H: r.H}
			switch {
			case f <= used*float64(grow) && hot:
				pt.Shadow(cell, 1, 0, 0, 4, 0, p.glowSoft())
				pt.Fill(cell, p.Sig, 1)
			case f <= used*float64(grow):
				pt.Fill(cell, p.T1, 1)
			case f <= proj && showPace:
				pt.Stroke(cell, p.T3, 1, 1)
			default:
				pt.Fill(cell, p.L3, 1)
			}
		}
		if showPace && pace > 0 {
			x := r.X + float32(pace)*r.W - 1
			tick := ui.Rect{X: x, Y: r.Y - 3, W: 2, H: r.H + 6}
			pt.Shadow(tick, 1, 0, 0, 4, 0, p.glow())
			pt.Fill(tick, p.Sig, 1)
		}
	})
	return box
}

type ringItem struct {
	Used, Pace float64
	Hot        bool
}

// rings is the Activity-style nest for the small Limits card.
func (p palette) rings(c *ui.Context, key string, items []ringItem, size, thick float32) ui.Element {
	box := ui.Box(c.Key(key)).Size(size, size).Shrink(0)
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 600 * time.Millisecond, Ease: ui.EaseOut})
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		cx, cy := r.X+size/2, r.Y+size/2
		for k, it := range items {
			rad := size/2 - thick/2 - float32(k)*(thick+3)
			arc := func(a0, a1 float64, col ui.Color) {
				var path ui.Path
				steps := max(2, int((a1-a0)*30))
				for i := 0; i <= steps; i++ {
					a := a0 + (a1-a0)*float64(i)/float64(steps)
					x, y := cx+rad*float32(math.Cos(a)), cy+rad*float32(math.Sin(a))
					if i == 0 {
						path.MoveTo(x, y)
					} else {
						path.LineTo(x, y)
					}
				}
				pt.StrokePath(&path, thick, col)
			}
			arc(0, 2*math.Pi, p.L2)
			col := []ui.Color{p.T1, p.Ink[1], p.Ink[2]}[min(k, 2)]
			if it.Hot {
				col = p.Sig
			}
			if it.Used > 0 {
				arc(-math.Pi/2, -math.Pi/2+2*math.Pi*it.Used/100*float64(grow), col)
			}
			pa := -math.Pi/2 + 2*math.Pi*it.Pace
			x0, y0 := cx+(rad-thick/2-1)*float32(math.Cos(pa)), cy+(rad-thick/2-1)*float32(math.Sin(pa))
			x1, y1 := cx+(rad+thick/2+1)*float32(math.Cos(pa)), cy+(rad+thick/2+1)*float32(math.Sin(pa))
			pt.Line(x0, y0, x1, y1, 1.5, p.Sig)
		}
	})
	return box
}

// ── Treemap (squarified) ──

type tmCell struct {
	part
	Group      string
	X, Y, W, H float32
}

func squarify(items []part, x, y, w, h float32) []tmCell {
	total := 0.0
	for _, it := range items {
		total += it.V
	}
	if total <= 0 || w <= 0 || h <= 0 {
		return nil
	}
	type area struct {
		part
		a float32
	}
	rest := make([]area, len(items))
	for i, it := range items {
		rest[i] = area{it, float32(it.V/total) * w * h}
	}
	var out []tmCell
	for len(rest) > 0 {
		short := min(w, h)
		worst := func(row []area) float32 {
			s, mx, mn := float32(0), float32(0), float32(math.MaxFloat32)
			for _, q := range row {
				s += q.a
				mx, mn = max(mx, q.a), min(mn, q.a)
			}
			return max(short*short*mx/(s*s), s*s/(short*short*max(mn, 1e-6)))
		}
		row := rest[:1]
		best := worst(row)
		for i := 1; i < len(rest); i++ {
			if wv := worst(rest[:i+1]); wv > best {
				break
			} else {
				row, best = rest[:i+1], wv
			}
		}
		s := float32(0)
		for _, q := range row {
			s += q.a
		}
		if w >= h {
			cw := s / h
			cy := y
			for _, q := range row {
				ch := q.a / cw
				out = append(out, tmCell{part: q.part, X: x, Y: cy, W: cw, H: ch})
				cy += ch
			}
			x, w = x+cw, w-cw
		} else {
			ch := s / w
			cx := x
			for _, q := range row {
				cw := q.a / ch
				out = append(out, tmCell{part: q.part, X: cx, Y: y, W: cw, H: ch})
				cx += cw
			}
			y, h = y+ch, h-ch
		}
		rest = rest[len(row):]
	}
	return out
}

type tmGroup struct {
	ID    string
	Band  ui.Color // vendor colour strip on each cell's left edge
	Logo  string
	Items []part
}

// treemap lays groups out first, then their items inside; light reports whether a fill needs dark text.
func (p palette) treemap(c *ui.Context, key string, groups []tmGroup, tip func(cell tmCell) (string, []tipRow)) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(60)
	b := box.Bounds()
	gs := make([]part, len(groups))
	for i, g := range groups {
		for _, it := range g.Items {
			gs[i].V += it.V
		}
		gs[i].ID = g.ID
	}
	sort.SliceStable(gs, func(i, j int) bool { return gs[i].V > gs[j].V })
	var cells []tmCell
	for _, g := range squarify(gs, 0, 0, b.W, b.H) {
		var grp tmGroup
		for _, x := range groups {
			if x.ID == g.ID {
				grp = x
			}
		}
		items := append([]part(nil), grp.Items...)
		sort.SliceStable(items, func(i, j int) bool { return items[i].V > items[j].V })
		for _, cl := range squarify(items, g.X, g.Y, g.W, g.H) {
			cl.Group = g.ID
			cl.Band = grp.Band
			cells = append(cells, cl)
		}
	}
	hover := -1
	if px, py, over := box.PointerPosition(); over {
		for i, cl := range cells {
			if px >= cl.X && px < cl.X+cl.W && py >= cl.Y && py < cl.Y+cl.H {
				hover = i
			}
		}
	}
	box.Children(func() {
		for i, cl := range cells {
			cell := ui.Box(c.Key(cl.ID)).Absolute().Left(cl.X+1).Top(cl.Y+1).Size(max(0, cl.W-2), max(0, cl.H-2)).Radius(3).Clip().
				Background(cl.Color).Opacity(box.AnimateTo("o"+cl.ID, pick(hover >= 0 && hover != i, float32(0.45), 1), animHover)).PassThrough()
			ink := pick(luminance(cl.Color) > 0.5, ui.Hex("#14120b"), ui.Hex("#ffffff"))
			cell.Children(func() {
				if cl.Band.A > 0 {
					ui.Box(c).Absolute().Left(0).Top(0).Width(3).FillHeight().Background(cl.Band)
				}
				if cl.W > 56 && cl.H > 32 {
					ui.Column(c).Padding(6, 7, 6, 10).Gap(2).Children(func() {
						ui.Row(c).Gap(5).AlignItems(ui.Center).Children(func() {
							for _, g := range groups {
								if g.ID == cl.Group && g.Logo != "" {
									logo(c, g.Logo, 11, ink)
								}
							}
							ui.Text(c, cl.ID).Font(monoFont).FontSize(11).FontWeight(500).TextColor(ink).SingleLine().Ellipsis("…")
						})
						ui.Text(c, shortNum(cl.V)).Font(monoFont).FontSize(10.5).TextColor(alpha(ink, 0.7)).SingleLine()
					})
				}
			})
		}
		if hover >= 0 && tip != nil {
			cl := cells[hover]
			title, rows := tip(cl)
			p.tooltip(c, cl.X+cl.W/2, cl.Y+8, b.W, title, rows)
		}
	})
	return box
}

// ── Sankey: sources → targets ──

type flow struct {
	From, To string
	V        float64
}

type sankeyNode struct {
	ID, Label string
	Color     ui.Color
}

func (p palette) sankey(c *ui.Context, key string, left, right []sankeyNode, flows []flow, linkColor func(to string) ui.Color, tip func(f flow) (string, []tipRow)) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(60)
	b := box.Bounds()
	const nodeW, gap, lw, rw = 6, 6, 84, 120
	total := 0.0
	for _, f := range flows {
		total += f.V
	}
	nmax := max(len(left), len(right))
	scale := float32(0)
	if total > 0 {
		scale = max(0, b.H-gap*float32(nmax-1)) / float32(total)
	}
	type span struct{ y, h, off float32 }
	L, R := map[string]*span{}, map[string]*span{}
	y := float32(0)
	for _, n := range left {
		v := 0.0
		for _, f := range flows {
			if f.From == n.ID {
				v += f.V
			}
		}
		L[n.ID] = &span{y: y, h: float32(v) * scale}
		y += float32(v)*scale + gap
	}
	y = 0
	for _, n := range right {
		v := 0.0
		for _, f := range flows {
			if f.To == n.ID {
				v += f.V
			}
		}
		R[n.ID] = &span{y: y, h: float32(v) * scale}
		y += float32(v)*scale + gap
	}
	type link struct {
		f       flow
		a, b, h float32
	}
	var links []link
	for _, n := range left {
		for _, m := range right {
			for _, f := range flows {
				if f.From == n.ID && f.To == m.ID && f.V > 0 {
					h := float32(f.V) * scale
					links = append(links, link{f, L[n.ID].y + L[n.ID].off, R[m.ID].y + R[m.ID].off, h})
					L[n.ID].off += h
					R[m.ID].off += h
				}
			}
		}
	}
	x0, x1 := float32(lw), b.W-rw
	hover := -1
	if px, py, over := box.PointerPosition(); over && x1 > x0 {
		t := (px - x0 - nodeW) / (x1 - x0 - nodeW)
		if t >= 0 && t <= 1 {
			e := t * t * (3 - 2*t)
			for i, l := range links {
				yy := l.a + (l.b-l.a)*e
				if py >= yy && py < yy+l.h {
					hover = i
				}
			}
		}
	}
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 600 * time.Millisecond, Ease: ui.EaseOut})
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		xa, xb := r.X+x0+nodeW, r.X+x1
		cx := (xa + xb) / 2
		for i, l := range links {
			var path ui.Path
			ya, yb := r.Y+l.a, r.Y+l.b
			path.MoveTo(xa, ya).CubeTo(cx, ya, cx, yb, xb, yb).LineTo(xb, yb+l.h).CubeTo(cx, yb+l.h, cx, ya+l.h, xa, ya+l.h).Close()
			on := hover < 0 || hover == i || links[hover].f.From == l.f.From || links[hover].f.To == l.f.To
			a := pick(on, pick(hover >= 0, float32(0.55), 0.32), 0.06) * grow
			pt.FillPath(&path, alpha(linkColor(l.f.To), a))
		}
		// Labels keep at least a line apart: small nodes at the bottom push their labels down instead of piling up.
		const lineH = 13
		last := float32(-1e9)
		for _, n := range left {
			s := L[n.ID]
			pt.Fill(ui.Rect{X: r.X + x0, Y: r.Y + s.y, W: nodeW, H: max(1, s.h)}, n.Color, 1.5)
			sp := ui.Span{Text: n.Label, Font: monoFont, Size: 11, Color: p.T2}
			w, h := pt.MeasureText(0, sp)
			y := max(r.Y+s.y+s.h/2-h/2, last+lineH)
			last = y
			pt.RichText(r.X+x0-8-w, y, 0, sp)
		}
		last = -1e9
		for _, n := range right {
			s := R[n.ID]
			pt.Fill(ui.Rect{X: r.X + x1, Y: r.Y + s.y, W: nodeW, H: max(1, s.h)}, n.Color, 1.5)
			sp := ui.Span{Text: n.Label, Font: monoFont, Size: 11, Color: p.T2}
			_, h := pt.MeasureText(0, sp)
			y := max(r.Y+s.y+s.h/2-h/2, last+lineH)
			last = y
			pt.RichText(r.X+x1+nodeW+8, y, 0, sp)
		}
	})
	if hover >= 0 && tip != nil {
		box.Children(func() {
			title, rows := tip(links[hover].f)
			p.tooltip(c, (x0+x1)/2-80, links[hover].a, b.W, title, rows)
		})
	}
	return box
}

// ── Calendar and punchcard ──

type calCell struct {
	Date time.Time
	V    float64
}

// calendarDots draws weekly columns of dots, five quintile steps of col; today ringed.
func (p palette) calendarDots(c *ui.Context, key string, cells []calCell, col ui.Color, tip func(i int) (string, []tipRow)) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(50)
	if len(cells) == 0 {
		return box
	}
	var nz []float64
	for _, cl := range cells {
		if cl.V > 0 {
			nz = append(nz, cl.V)
		}
	}
	sort.Float64s(nz)
	var q [4]float64
	for i, f := range []float64{0.2, 0.4, 0.6, 0.8} {
		if len(nz) > 0 {
			q[i] = nz[int(f*float64(len(nz)-1))]
		}
	}
	step := func(v float64) int {
		if v <= 0 {
			return 0
		}
		s := 1
		for _, t := range q {
			if v > t {
				s++
			}
		}
		return s
	}
	start := cells[0].Date.AddDate(0, 0, -int(cells[0].Date.Weekday()))
	weeks := int(cells[len(cells)-1].Date.Sub(start).Hours()/24)/7 + 1
	const labW = 18
	b := box.Bounds()
	cell := min((b.W-labW)/float32(weeks), b.H/7)
	posOf := func(i int) (int, int) {
		d := int(math.Round(cells[i].Date.Sub(start).Hours() / 24))
		return d / 7, int(cells[i].Date.Weekday())
	}
	hover := -1
	if px, py, over := box.PointerPosition(); over && cell > 0 {
		cw, rr := int((px-labW)/cell), int(py/cell)
		for i := range cells {
			if wk, wd := posOf(i); wk == cw && wd == rr {
				hover = i
			}
		}
	}
	tones := [6]float32{0, 0.26, 0.45, 0.66, 0.84, 1}
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 500 * time.Millisecond, Ease: ui.EaseOut})
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		for i, l := range []string{"M", "W", "F"} {
			p.axisText(pt, r.X, r.Y+float32(1+i*2)*cell+cell/2-6, l, 0)
		}
		rad := max(1.4, cell*0.36)
		shown := int(float32(weeks) * grow)
		for i, cl := range cells {
			wk, wd := posOf(i)
			if wk > shown {
				continue
			}
			s := step(cl.V)
			col2 := p.DotOff
			if s > 0 {
				col2 = p.L2.Mix(col, tones[s])
			}
			rr := rad + pick(i == hover, float32(1), 0)
			x, y := r.X+labW+float32(wk)*cell+cell/2, r.Y+float32(wd)*cell+cell/2
			d := ui.Rect{X: x - rr, Y: y - rr, W: 2 * rr, H: 2 * rr}
			pt.Fill(d, col2, rr)
			if i == len(cells)-1 {
				pt.Stroke(ui.Rect{X: d.X - 1.5, Y: d.Y - 1.5, W: d.W + 3, H: d.H + 3}, p.T1, rr+1.5, 1.2)
			}
		}
	})
	if hover >= 0 && tip != nil {
		box.Children(func() {
			wk, _ := posOf(hover)
			title, rows := tip(hover)
			p.tooltip(c, labW+float32(wk)*cell, -4, b.W, title, rows)
		})
	}
	return box
}

// heatScale is the Less → More legend.
func (p palette) heatScale(c *ui.Context, col ui.Color) ui.Element {
	return ui.Row(c).Gap(4).AlignItems(ui.Center).Shrink(0).Children(func() {
		p.mono(c, "Less", 9.5, p.T4)
		for _, t := range []float32{0, 0.26, 0.45, 0.66, 0.84, 1} {
			ui.Box(c).Size(7, 7).Radius(3.5).Background(pick(t == 0, p.DotOff, p.L2.Mix(col, t)))
		}
		p.mono(c, "More", 9.5, p.T4)
	})
}

// punchcard is weekday × hour, dot area ∝ usage. grid[0] is Monday.
func (p palette) punchcard(c *ui.Context, key string, grid [7][24]float64, col ui.Color, tip func(wd, hr int) (string, []tipRow)) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).FillWidth().MinHeight(60)
	maxV := 1e-9
	for _, row := range grid {
		for _, v := range row {
			maxV = math.Max(maxV, v)
		}
	}
	const labW, labH = 26, 14
	b := box.Bounds()
	cw, ch := (b.W-labW)/24, (b.H-labH)/7
	hr, wd := -1, -1
	if px, py, over := box.PointerPosition(); over && cw > 0 && ch > 0 {
		hr, wd = int((px-labW)/cw), int(py/ch)
		if hr < 0 || hr > 23 || wd < 0 || wd > 6 {
			hr, wd = -1, -1
		}
	}
	grow := box.AnimateTo("grow", 1, ui.Animation{Duration: 500 * time.Millisecond, Ease: ui.EaseOut})
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		cw, ch := (r.W-labW)/24, (r.H-labH)/7
		R := min(cw, ch)/2 - 0.6
		for i, d := range []string{"Mon", "", "Wed", "", "Fri", "", "Sun"} {
			if d != "" {
				p.axisText(pt, r.X, r.Y+float32(i)*ch+ch/2-6, d, 0)
			}
		}
		for _, h := range []int{0, 6, 12, 18} {
			p.axisText(pt, r.X+labW+float32(h)*cw+cw/2, r.Y+r.H-12, itoa(h), 1)
		}
		for w := range 7 {
			for h := range 24 {
				v := grid[w][h]
				x, y := r.X+labW+float32(h)*cw+cw/2, r.Y+float32(w)*ch+ch/2
				if v <= 0 {
					pt.Fill(ui.Rect{X: x - 1, Y: y - 1, W: 2, H: 2}, p.DotOff, 1)
					continue
				}
				f := math.Sqrt(v / maxV)
				rr := max(1, float32(f)*R*grow)
				a := float32(0.35 + 0.65*f)
				if w == wd && h == hr {
					a = 1
				}
				pt.Fill(ui.Rect{X: x - rr, Y: y - rr, W: 2 * rr, H: 2 * rr}, alpha(col, a), rr)
			}
		}
	})
	if hr >= 0 && tip != nil {
		box.Children(func() {
			title, rows := tip(wd, hr)
			p.tooltip(c, labW+float32(hr)*cw, float32(wd)*ch-44, b.W, title, rows)
		})
	}
	return box
}

// shortNum is the short form used by axis ticks and chart labels (always short).
func shortNum(v float64) string {
	a := math.Abs(v)
	trim := func(s string) string {
		for len(s) > 1 && s[len(s)-1] == '0' && containsDot(s) {
			s = s[:len(s)-1]
		}
		if len(s) > 0 && s[len(s)-1] == '.' {
			s = s[:len(s)-1]
		}
		return s
	}
	switch {
	case a >= 1e9:
		return trim(ftoa(v/1e9, pick(a >= 1e10, 1, 2))) + "B"
	case a >= 1e6:
		return trim(ftoa(v/1e6, pick(a >= 1e8, 0, 1))) + "M"
	case a >= 1e3:
		return trim(ftoa(v/1e3, pick(a >= 1e5, 0, 1))) + "K"
	}
	return ftoa(v, 0)
}

func containsDot(s string) bool {
	for i := range len(s) {
		if s[i] == '.' {
			return true
		}
	}
	return false
}

// luminance is a colour's relative luminance (0 black … 1 white), to pick legible text on a fill.
func luminance(c ui.Color) float64 {
	lin := func(v uint8) float64 {
		x := float64(v) / 255
		if x <= 0.04045 {
			return x / 12.92
		}
		return math.Pow((x+0.055)/1.055, 2.4)
	}
	return 0.2126*lin(c.R) + 0.7152*lin(c.G) + 0.0722*lin(c.B)
}
