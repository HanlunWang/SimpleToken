package gui

import (
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
)

// Shared motion: one rhythm everywhere. With Reduce Motion, mygo puts positions and sizes in place at once.
var (
	animHover = ui.Animation{Duration: 120 * time.Millisecond}
	animColor = ui.Animation{Duration: 180 * time.Millisecond}
	animKnob  = ui.Animation{Spring: ui.SpringOptions{Duration: 340 * time.Millisecond, Bounce: 0.22}}
	animPress = ui.Animation{Spring: ui.SpringOptions{Duration: 220 * time.Millisecond, Bounce: 0.1}}
	animSlide = ui.Animation{Spring: ui.SpringOptions{Duration: 300 * time.Millisecond, Bounce: 0.08}}
	animData  = ui.Animation{Duration: 320 * time.Millisecond, Ease: ui.EaseOut}
)

func b2f(b bool) float32 {
	if b {
		return 1
	}
	return 0
}

// pressPose shrinks a pressed element slightly and springs it back (paint only, no layout).
func pressPose(e ui.Element, scale float32) ui.Element {
	pose := ui.Pose{}
	if e.Pressed() {
		pose.Scale = scale
	}
	return e.AnimatePose(pose, animPress)
}

// enterOnce is an element's entrance progress (0 → 1) on its first build; 1 afterwards, asking for no frames.
func enterOnce(e ui.Element, d, delay time.Duration) float32 {
	return e.Keyframes("enter", []ui.Keyframe{{Value: 0}, {At: d, Value: 1, Ease: ui.EaseOut}}, ui.KeyframeOptions{Delay: delay})
}

// ── Text ──

// caption is a section label: mono, upper case, tracked. Panel: "//" before it; windows: a signal square.
func (p palette) caption(c *ui.Context, text string) ui.Element {
	return ui.Row(c).Gap(5).AlignItems(ui.Center).Shrink(0).Children(func() {
		if p.Surface == surfacePanel {
			ui.Text(c, "//").Font(monoFont).FontSize(10.5).TextColor(p.T4)
		} else {
			ui.Box(c).Size(4, 4).Radius(0.5).Background(p.Sig)
		}
		ui.Text(c, strings.ToUpper(text)).Font(monoFont).FontSize(10.5).FontWeight(500).LetterSpacing(0.9).
			TextColor(p.T3).SingleLine()
	})
}

// mono is small monospaced text.
func (p palette) mono(c *ui.Context, text string, size float32, col ui.Color) ui.Element {
	return ui.Text(c, text).Font(monoFont).FontSize(size).TextColor(col).SingleLine()
}

// hint is explanatory body text.
func (p palette) hint(c *ui.Context, text string) ui.Element {
	return ui.Text(c, text).FontSize(11).TextColor(p.T3).Wrap()
}

// bigNum is a defining number in the dot face with its unit small in mono beside it; it rolls when it changes.
func (p palette) bigNum(c *ui.Context, key, value, unit string, size float32, col ui.Color) ui.Element {
	return ui.Row(c.Key(key)).AlignItems(ui.End).Gap(size * 0.12).Shrink(0).Children(func() {
		ui.Text(c.Key("v"), value).Font(dotFont).FontSize(size).LetterSpacing(size * 0.02).TextColor(col).SingleLine().
			ContentTransition(ui.ContentTransition{Numeric: true})
		if unit != "" {
			ui.Text(c.Key("u"), unit).Font(monoFont).FontSize(max(10, size*0.36)).TextColor(p.T3).SingleLine().Margin(0, 0, size*0.08)
		}
	})
}

// hair is a 1 px divider.
func (p palette) hair(c *ui.Context) ui.Element {
	return ui.Box(c).FillWidth().Height(1).Shrink(0).Background(p.L2)
}

// ── Controls ──

type btnKind int

const (
	btnPlain btnKind = iota
	btnPrimary
	btnGhost
)

// button is a small button with an optional icon; mono label on both surfaces.
func (p palette) button(c *ui.Context, key, label, iconName string, kind btnKind) ui.Element {
	b := ui.Row(c.Key(key)).Height(26).Padding(0, 10).Radius(p.rCtl()).Gap(6).AlignItems(ui.Center).Label(label).Shrink(0)
	hover := b.Hovered()
	fg, bg, bd := p.T1, ui.Transparent, p.L3
	switch kind {
	case btnPrimary:
		bg, bd, fg = p.FG, p.FG, p.BG
		if hover {
			bg = alpha(p.FG, 0.88)
		}
	case btnGhost:
		bd, fg = ui.Transparent, p.T2
		if hover {
			bg, fg = p.L2, p.T1
		}
	default:
		if hover {
			bg, bd = p.L1, p.L4
		}
	}
	b.Background(b.AnimateColor("bg", bg, animHover)).Border(1, b.AnimateColor("bd", bd, animHover))
	pressPose(b, 0.96)
	col := b.AnimateColor("fg", fg, animHover)
	b.Children(func() {
		if iconName != "" {
			icon(c, iconName, 13).TextColor(col)
		}
		if label != "" {
			ui.Text(c, label).Font(monoFont).FontSize(11.5).TextColor(col).SingleLine()
		}
	})
	return b
}

// iconBtn is a 26 × 26 icon button; active gives it a fill.
func (p palette) iconBtn(c *ui.Context, key, name, tip string, active bool) ui.Element {
	b := ui.Row(c.Key(key)).Size(26, 26).Radius(p.rCtl() + 1).AlignItems(ui.Center).Justify(ui.Center).Tooltip(tip).Label(tip).Shrink(0)
	on := active || b.Hovered()
	b.Background(b.AnimateColor("bg", pick(on, p.L2, ui.Transparent), animHover))
	col := b.AnimateColor("fg", pick(on, p.T1, p.T2), animHover)
	pressPose(b, 0.92)
	b.Children(func() { icon(c, name, 14).TextColor(col) })
	return b
}

// badge is a short mono label. tone: "" neutral, "up", "sig".
func (p palette) badge(c *ui.Context, text, tone string) ui.Element {
	fg, bg := p.T2, p.L2
	switch tone {
	case "up":
		fg, bg = p.Green, alpha(p.Green, 0.13)
	case "sig":
		fg, bg = p.Sig, p.sigSoft()
	}
	return ui.Row(c).Height(18).Padding(0, 6).Radius(3).Background(bg).AlignItems(ui.Center).Shrink(0).Children(func() {
		ui.Text(c, text).Font(monoFont).FontSize(10).LetterSpacing(0.3).TextColor(fg).SingleLine()
	})
}

// segmented is a mono segmented control; the thumb springs between segments. Returns the chosen index.
func (p palette) segmented(c *ui.Context, key string, selected int, labels ...string) int {
	out := selected
	n := len(labels)
	r := p.rCtl()
	track := ui.Row(c.Key(key)).Height(26).Padding(2).Radius(r).Border(1, p.L3).Gap(2).Shrink(0)
	pos := track.AnimateTo("thumb", float32(selected), animSlide)
	panel := p.Surface == surfacePanel
	widths := make([]float32, n)
	track.Draw(func(pt *ui.Painter, rr ui.Rect) {
		if n == 0 || selected < 0 {
			return
		}
		// Thumb between the measured segments: interpolate x and width across the fractional position.
		const pad, gap = 3, 2
		xs := make([]float32, n)
		x := rr.X + pad
		for i := range n {
			xs[i] = x
			x += widths[i] + gap
		}
		i0 := int(math.Floor(float64(pos)))
		i0 = max(0, min(n-1, i0))
		i1 := min(n-1, i0+1)
		f := pos - float32(i0)
		tx := xs[i0] + (xs[i1]-xs[i0])*f
		tw := widths[i0] + (widths[i1]-widths[i0])*f
		thumb := ui.Rect{X: tx, Y: rr.Y + pad, W: tw, H: rr.H - 2*pad}
		if panel {
			pt.Fill(thumb, p.L3, r-2)
			return
		}
		pt.Fill(thumb, p.L2, r-2)
		pt.Fill(ui.Rect{X: thumb.X + 2, Y: thumb.Y + thumb.H - 2, W: thumb.W - 4, H: 2}, p.Sig, 1)
	})
	track.Children(func() {
		for i, l := range labels {
			s := ui.Row(c.Key(i)).FillHeight().Padding(0, 9).Radius(r - 2).AlignItems(ui.Center).Justify(ui.Center).Label(l)
			widths[i] = s.Bounds().W
			col := p.T3
			if i == selected || s.Hovered() {
				col = p.T1
			}
			s.Children(func() {
				ui.Text(c, l).Font(monoFont).FontSize(11).TextColor(s.AnimateColor("fg", col, animHover)).SingleLine()
			})
			if s.Clicked() {
				out = i
			}
		}
	})
	return out
}

// segValue is segmented for string values.
func (p palette) segValue(c *ui.Context, key string, value *string, opts [][2]string) bool {
	sel := -1
	labels := make([]string, len(opts))
	for i, o := range opts {
		labels[i] = o[1]
		if o[0] == *value {
			sel = i
		}
	}
	if n := p.segmented(c, key, sel, labels...); n != sel && n >= 0 {
		*value = opts[n][0]
		return true
	}
	return false
}

// toggle is the glowing switch (SimpleToggle's): an outlined capsule; on, the knob turns solid signal and glows.
func (p palette) toggle(c *ui.Context, key string, on *bool) ui.Element {
	w, h := float32(32), float32(18)
	sw := ui.SwitchBase(c.Key(key), on).Size(w, h).Radius(h / 2).Shrink(0)
	pos := sw.AnimateTo("knob", b2f(*on), animKnob)
	lit := max(0, min(sw.AnimateTo("lit", b2f(*on), animColor), 1))
	press := sw.AnimateTo("press", b2f(sw.Pressed()), animHover)
	hover := sw.AnimateTo("hover", b2f(sw.Hovered()), animHover)
	glow := p.Sig
	sw.Draw(func(pt *ui.Painter, r ui.Rect) {
		rad := r.H / 2
		if lit > 0 {
			pt.Shadow(r, rad, 0, 0, 9, 0, alpha(glow, 0.24*lit))
		}
		pt.Fill(r, alpha(p.FG, 0.03+0.03*hover).Mix(alpha(glow, 0.14), lit), rad)
		pt.Stroke(r, alpha(p.FG, 0.30+0.12*hover).Mix(alpha(glow, 0.6), lit), rad, 1)
		in := float32(4)
		d := r.H - 2*in
		kw := d + 4*press
		x := r.X + in + pos*(r.W-2*in-kw)
		knob := ui.Rect{X: x, Y: r.Y + in, W: kw, H: d}
		if lit > 0 {
			pt.Shadow(knob, d/2, 0, 0, 10, 0, alpha(glow, 0.45*lit))
			pt.Shadow(knob, d/2, 0, 0, 4, 0, alpha(glow, 0.85*lit))
		}
		pt.Fill(knob, alpha(glow, lit), d/2)
		if lit < 1 {
			pt.Stroke(knob, alpha(p.FG, (0.45+0.15*hover)*(1-lit)), d/2, 1)
		}
	})
	return sw
}

// chip is a small selectable pill (thresholds, providers).
func (p palette) chip(c *ui.Context, key, label string, on bool) ui.Element {
	b := ui.Row(c.Key(key)).Height(24).Padding(0, 9).Radius(p.rCtl()).Gap(5).AlignItems(ui.Center).Label(label).Shrink(0)
	bd := pick(on, p.sigLine(), pick(b.Hovered(), p.L4, p.L3))
	b.Border(1, b.AnimateColor("bd", bd, animHover)).Background(b.AnimateColor("bg", pick(on, p.sigSoft(), ui.Transparent), animHover))
	pressPose(b, 0.95)
	b.Children(func() {
		if on {
			ui.Box(c).Size(5, 5).Radius(2.5).Background(p.Sig)
		}
		ui.Text(c, label).Font(monoFont).FontSize(11).TextColor(p.T1).SingleLine()
	})
	return b
}

// swatch is a small colour square (a series' identity in legends and rows).
func swatch(c *ui.Context, col ui.Color, size float32) ui.Element {
	return ui.Box(c).Size(size, size).Radius(1.5).Background(col).Shrink(0)
}

// logo is a mono brand mark tinted with col.
func logo(c *ui.Context, name string, size float32, col ui.Color) ui.Element {
	if s := svgNamed("logo:" + name); s != nil {
		return ui.Icon(c, s).Size(size, size).TextColor(col).Shrink(0)
	}
	return ui.Box(c).Size(size, size).Shrink(0)
}

// dotRun is "in progress": a 3 × 3 dot matrix lighting from the corners inward, then dimming (1.4 s loop).
// Painted from Draw so it costs no rebuilds.
func (p palette) dotRun(c *ui.Context, size float32) ui.Element {
	d := size / 3.8
	g := (size - 3*d) / 2
	layers := [9]int{0, 1, 0, 1, 2, 1, 0, 1, 0}
	return ui.Box(c).Size(size, size).Shrink(0).Draw(func(pt *ui.Painter, r ui.Rect) {
		const period = 1400 * time.Millisecond
		t := pt.Now()
		for i, layer := range layers {
			el := t.Add(-time.Duration(layer) * 200 * time.Millisecond)
			ph := float64(el.UnixNano()%int64(period)) / float64(period)
			a := inward(ph)
			dot := ui.Rect{X: r.X + float32(i%3)*(d+g), Y: r.Y + float32(i/3)*(d+g), W: d, H: d}
			if a > 0.5 {
				pt.Shadow(dot, d/2, 0, 0, 3, 0, alpha(p.Sig, 0.3*a))
			}
			pt.Fill(dot, alpha(p.Sig, a), d/2)
		}
		pt.After(50 * time.Millisecond)
	})
}

func inward(phase float64) float32 {
	switch {
	case phase < 0.12:
		return float32(0.16 + 0.84*phase/0.12)
	case phase < 0.58:
		return 1
	case phase < 0.74:
		return float32(1 - 0.84*(phase-0.58)/0.16)
	}
	return 0.16
}

// brand is the logo: SimpleToken's ¾ gauge as a ring of dots (lit in the signal colour) + "simpletoken" in mono.
// lamp plays the lamp-on flicker once, dot by dot.
func (p palette) brand(c *ui.Context, size float32, lamp bool) ui.Element {
	return ui.Row(c.Key("brand")).Gap(7).AlignItems(ui.Center).Shrink(0).Children(func() {
		s := size + 3
		g := ui.Box(c.Key("gauge")).Size(s, s).Shrink(0)
		k := float32(1)
		if lamp {
			k = g.Keyframes("on", []ui.Keyframe{{Value: 0}, {At: 950 * time.Millisecond, Value: 1, Ease: ui.Linear}})
		}
		g.Draw(func(pt *ui.Painter, r ui.Rect) { p.gaugeDots(pt, r, 12, 0.75, float64(k)) })
		ui.Text(c, "simpletoken").Font(monoFont).FontSize(size - 0.5).FontWeight(600).LetterSpacing(-0.1).TextColor(p.T1).SingleLine()
	})
}

// gaugeDots paints n dots on a 270° arc; the first lit fraction in the signal colour, the rest off.
// k (0…1) is the lamp-on progress.
func (p palette) gaugeDots(pt *ui.Painter, r ui.Rect, n int, lit float64, k float64) {
	cx, cy := r.X+r.W/2, r.Y+r.H/2
	rad := r.W/2 - r.W*0.1
	dot := max(1.6, r.W/7.2)
	for i := range n {
		a := (-225 + float64(i)*270/float64(n-1)) * math.Pi / 180
		x := cx + rad*float32(math.Cos(a)) - dot/2
		y := cy + rad*float32(math.Sin(a)) - dot/2
		d := ui.Rect{X: x, Y: y, W: dot, H: dot}
		if float64(i)/float64(n-1) <= lit+1e-6 {
			on := lampOn((k - rand01(i, 3)*0.4) / 0.59)
			pt.Shadow(d, dot/2, 0, 0, 3, 0, alpha(p.Sig, 0.5*on))
			pt.Fill(d, alpha(p.Sig, on), dot/2)
		} else {
			pt.Fill(d, p.DotOff, dot/2)
		}
	}
}

func rand01(i, salt int) float64 {
	x := math.Sin(float64(i+1)*12.9898+float64(salt)*78.233) * 43758.5453
	return x - math.Floor(x)
}

// lampOn is an old indicator lamp powering up: two flickers, then steady (t 0…1).
func lampOn(t float64) float32 {
	keys := [][2]float64{{0, 0}, {.10, .9}, {.18, .15}, {.30, 1}, {.42, .5}, {.58, 1}, {1, 1}}
	if t <= 0 {
		return 0
	}
	for i := 1; i < len(keys); i++ {
		if t <= keys[i][0] {
			a, b := keys[i-1], keys[i]
			return float32(a[1] + (b[1]-a[1])*(t-a[0])/(b[0]-a[0]))
		}
	}
	return 1
}

func itoa(n int) string { return strconv.Itoa(n) }

func ftoa(v float64, prec int) string { return strconv.FormatFloat(v, 'f', prec, 64) }
