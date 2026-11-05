package gui

import (
	"math"

	"github.com/egoist/mygo/ui"
)

// The limit gauge (designs/simpletoken-v3 Limits board): a 270° arc of ticks with three marks. Solid ticks in the
// vendor colour are used; dim ticks (the same hue at 30 %) are where usage lands by the reset at this pace; the
// glowing needle is the share of the window gone. Only the needle glows: it is the one thing that moves on its
// own. Over the alert threshold the used ticks turn red and glow too. The figure is centred on its own digits,
// its % hanging off the right. Geometry is the board's: a 132 × 124 view box, ticks from radius 43 to 53, the
// needle from 37 to 56 with its ring at 59.5.

type gaugeSpec struct {
	Used    float64  // % used
	Elapsed float64  // share of the window gone, 0…1; < 0 when unknown (no needle)
	Proj    float64  // % by the reset at this pace; < 0 when there is no forecast
	Col     ui.Color // vendor colour
	Hot     bool     // over the alert threshold
	None    bool     // no data: dotted ticks and a dash
	Ticks   int      // 42 on the dashboard, 32 in small cards
	Stroke  float32  // tick width in view-box units
	Num     float32  // figure size in DIPs
	Ground  ui.Color // fill inside the needle's ring (the card or panel ground)
}

const gaugeVW, gaugeVH = 132, 124

// gauge draws a limit gauge width DIPs wide.
func (p palette) gauge(c *ui.Context, key string, g gaugeSpec, width float32) ui.Element {
	h := width * gaugeVH / gaugeVW
	box := ui.Box(c.Key(key)).Size(width, h).Shrink(0)
	used := float64(box.AnimateTo("used", float32(g.Used), animData))
	col, dimCol := g.Col, dim(g.Col)
	if g.Hot {
		col, dimCol = p.Red, alpha(p.Red, 0.35)
	}
	n := max(8, g.Ticks)
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		s := r.W / gaugeVW
		at := func(a float64, rad float32) (float32, float32) {
			return r.X + (60+6)*s + rad*s*float32(math.Cos(a)), r.Y + (62+6)*s + rad*s*float32(math.Sin(a))
		}
		angle := func(f float64) float64 { return (135 + 270*f) * math.Pi / 180 }
		var usedT, projT, restT [][2]float32
		for i := range n {
			f := float64(i) / float64(n-1) * 100
			x0, y0 := at(angle(f/100), 43)
			x1, y1 := at(angle(f/100), 53)
			seg := [][2]float32{{x0, y0}, {x1, y1}, {float32(math.NaN()), 0}}
			switch {
			case g.None:
				restT = append(restT, seg...)
			case used > 0 && f <= used+0.01:
				usedT = append(usedT, seg...)
			case g.Proj > used && f <= g.Proj:
				projT = append(projT, seg...)
			default:
				restT = append(restT, seg...)
			}
		}
		w := g.Stroke * s
		if g.None {
			for i := range n {
				x, y := at(angle(float64(i)/float64(n-1)), 48)
				pt.Fill(ui.Rect{X: x - w/2, Y: y - w/2, W: w, H: w}, p.L3, w/2)
			}
		} else {
			pt.StrokePolyline(restT, w, p.L3)
		}
		pt.StrokePolyline(projT, w, dimCol)
		if g.Hot && len(usedT) > 0 {
			pt.StrokePolyline(usedT, w+3*s, alpha(p.Red, 0.25))
		}
		pt.StrokePolyline(usedT, w, col)
		if !g.None && g.Elapsed >= 0 {
			a := angle(clamp01(g.Elapsed))
			x0, y0 := at(a, 37)
			x1, y1 := at(a, 56)
			needle := [][2]float32{{x0, y0}, {x1, y1}}
			nw := max(1.2, w*0.68)
			pt.StrokePolyline(needle, nw+3, alpha(p.Sig, 0.12))
			pt.StrokePolyline(needle, nw+1.4, alpha(p.Sig, 0.22))
			pt.StrokePolyline(needle, nw, p.Sig)
			cx, cy := at(a, 59.5)
			rr := max(2.2, 2.6*s*1.15)
			ring := ui.Rect{X: cx - rr, Y: cy - rr, W: 2 * rr, H: 2 * rr}
			pt.Fill(ring, g.Ground, rr)
			pt.Stroke(ring, p.Sig, rr, max(1, nw*0.85))
		}
		// The figure, centred on its digits; the unit hangs off the right edge
		num := "—"
		numCol := pick(g.Hot, p.Red, p.T1)
		if g.None {
			numCol = p.T3
		} else {
			num = itoa(int(math.Round(g.Used)))
		}
		sp := bigSpan(num, g.Num, numCol)
		nw, nh := pt.MeasureText(0, sp)
		x := r.X + r.W*(66.0/gaugeVW) - nw/2
		y := r.Y + r.H*0.40 - nh*0.1
		pt.RichText(x, y, 0, sp)
		if !g.None {
			pt.RichText(x+nw+2, y+g.Num*0.12, 0, ui.Span{Text: "%", Font: monoFont, Size: max(9, g.Num*0.32), Color: p.T3})
		}
	})
	return box
}

// gaugeLine is the gauge's three marks in a line (the M size and the panel's bar style): ticks for used and for
// the projection, the needle for time gone.
func (p palette) gaugeLine(c *ui.Context, key string, g gaugeSpec, height float32) ui.Element {
	box := ui.Box(c.Key(key)).Grow(1).MinWidth(60).Height(height)
	used := float64(box.AnimateTo("used", float32(g.Used), animData))
	col, dimCol := g.Col, dim(g.Col)
	if g.Hot {
		col, dimCol = p.Red, alpha(p.Red, 0.35)
	}
	n := max(8, g.Ticks)
	box.Draw(func(pt *ui.Painter, r ui.Rect) {
		top, bot := r.Y+r.H*0.25, r.Y+r.H*0.75
		var usedT, projT, restT [][2]float32
		for i := range n {
			f := float64(i) / float64(n-1) * 100
			x := r.X + 2 + float32(i)*(r.W-4)/float32(n-1)
			seg := [][2]float32{{x, top}, {x, bot}, {float32(math.NaN()), 0}}
			switch {
			case g.None:
				restT = append(restT, seg...)
			case used > 0 && f <= used+0.01:
				usedT = append(usedT, seg...)
			case g.Proj > used && f <= g.Proj:
				projT = append(projT, seg...)
			default:
				restT = append(restT, seg...)
			}
		}
		pt.StrokePolyline(restT, 2, p.L3)
		pt.StrokePolyline(projT, 2, dimCol)
		pt.StrokePolyline(usedT, 2, col)
		if !g.None && g.Elapsed >= 0 {
			x := r.X + 2 + float32(clamp01(g.Elapsed))*(r.W-4)
			needle := [][2]float32{{x, r.Y + 1}, {x, r.Y + r.H - 1}}
			pt.StrokePolyline(needle, 3.5, alpha(p.Sig, 0.18))
			pt.StrokePolyline(needle, 1.5, p.Sig)
		}
	})
	return box
}
