package gui

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
	"sync"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// The menu bar item is one image redrawn when its values change (and every 30 s for clock-bound items). It is a
// template image (black + alpha, tinted by macOS) unless a value is at or over the top alert threshold: then it
// is drawn in full colour for the bar's appearance, with that value in the alert red.

type mbStyle string

const (
	mbText    mbStyle = "text"    // single line
	mbStacked mbStyle = "stacked" // label over value
	mbDense   mbStyle = "dense"   // two items per column
	mbRing    mbStyle = "ring"    // a ring per limit
	mbRings   mbStyle = "rings"   // up to three limits nested
	mbBar     mbStyle = "bar"     // value over a thin bar
)

// mbSeg is one item: a limit (Pct ≥ 0), a number (Value), or mini bars (Bars).
type mbSeg struct {
	Label string
	Value string
	Pct   float64 // −1 when not a limit
	Pace  float64 // 0…1, for the pace tick and projection
	Hot   bool    // at or over the top alert threshold
	Bars  []float64
	Now   int // highlighted bar; bars after it are future (dots)
}

type mbOpts struct {
	Style  mbStyle
	Labels bool
	Pace   bool
	Icon   bool
	Red    bool // turn red near the limit
	Dark   bool // the menu bar's appearance (only used for the colour image)
	// Preview draws in the bar's ink instead of a template (Settings previews; macOS tints real templates).
	Preview bool
}

const mbScale = 2 // @2x pixels per point; the image is 18 pt tall

var (
	mbFontOnce             sync.Once
	mbFace, mbSmall, mbMid font.Face
)

func mbFonts() {
	mbFontOnce.Do(func() {
		load := func(file string, size float64) font.Face {
			data, err := fontFiles.ReadFile("fonts/" + file)
			if err != nil {
				return nil
			}
			f, err := opentype.Parse(data)
			if err != nil {
				return nil
			}
			face, _ := opentype.NewFace(f, &opentype.FaceOptions{Size: size * mbScale, DPI: 72, Hinting: font.HintingNone})
			return face
		}
		mbFace = load("Geist-Medium.ttf", 13)
		mbMid = load("Geist-Medium.ttf", 11)
		mbSmall = load("Geist-SemiBold.ttf", 8.5)
	})
}

// mbCanvas is an alpha mask per colour role, composed into the final image.
type mbCanvas struct {
	ink, alert, dim *image.Alpha
	w, h            int
	x               float64 // pen position in pixels
}

func newMBCanvas(w int) *mbCanvas {
	h := 18 * mbScale
	r := image.Rect(0, 0, w, h)
	return &mbCanvas{ink: image.NewAlpha(r), alert: image.NewAlpha(r), dim: image.NewAlpha(r), w: w, h: h}
}

func (cv *mbCanvas) layer(hot, dim bool) *image.Alpha {
	if hot {
		return cv.alert
	}
	if dim {
		return cv.dim
	}
	return cv.ink
}

// coverage paints a shape with 4 × 4 supersampling.
func (cv *mbCanvas) coverage(dst *image.Alpha, x0, y0, x1, y1 float64, inside func(x, y float64) bool, a float64) {
	const ss = 4
	for y := max(0, int(y0)); y < min(cv.h, int(math.Ceil(y1))); y++ {
		for x := max(0, int(x0)); x < min(cv.w, int(math.Ceil(x1))); x++ {
			n := 0
			for sy := range ss {
				for sx := range ss {
					if inside(float64(x)+(float64(sx)+0.5)/ss, float64(y)+(float64(sy)+0.5)/ss) {
						n++
					}
				}
			}
			if n > 0 {
				v := float64(dst.AlphaAt(x, y).A) + float64(n)*255*a/(ss*ss)
				dst.SetAlpha(x, y, color.Alpha{A: uint8(math.Min(255, v))})
			}
		}
	}
}

func (cv *mbCanvas) text(face font.Face, s string, x, baseline float64, dst *image.Alpha) float64 {
	if face == nil {
		return 0
	}
	d := &font.Drawer{Dst: dst, Src: image.Opaque, Face: face, Dot: fixed.P(int(math.Round(x)), int(math.Round(baseline)))}
	d.DrawString(s)
	return float64(d.Dot.X.Round()) - math.Round(x)
}

func measure(face font.Face, s string) float64 {
	if face == nil {
		return float64(len(s)) * 14
	}
	return float64(font.MeasureString(face, s).Round())
}

// ring paints an arc band of radius r (pixels) from the top clockwise over frac, thickness th.
func (cv *mbCanvas) ring(dst *image.Alpha, cx, cy, r, th, frac, a float64) {
	cv.coverage(dst, cx-r-th, cy-r-th, cx+r+th, cy+r+th, func(x, y float64) bool {
		dx, dy := x-cx, y-cy
		d := math.Hypot(dx, dy)
		if math.Abs(d-r) > th/2 {
			return false
		}
		ang := math.Atan2(dx, -dy)
		if ang < 0 {
			ang += 2 * math.Pi
		}
		return ang <= frac*2*math.Pi
	}, a)
}

func (cv *mbCanvas) dot(dst *image.Alpha, cx, cy, r, a float64) {
	cv.coverage(dst, cx-r, cy-r, cx+r, cy+r, func(x, y float64) bool { return math.Hypot(x-cx, y-cy) <= r }, a)
}

func (cv *mbCanvas) rect(dst *image.Alpha, x0, y0, x1, y1, rad, a float64) {
	cv.coverage(dst, x0, y0, x1, y1, func(x, y float64) bool {
		cx := math.Min(math.Max(x, x0+rad), x1-rad)
		cy := math.Min(math.Max(y, y0+rad), y1-rad)
		return math.Hypot(x-cx, y-cy) <= rad
	}, a)
}

// glyph is the dotted ¾ gauge, the app icon in the menu bar.
func (cv *mbCanvas) glyph(x float64) float64 {
	const n = 10
	s := 15.0 * mbScale
	cx, cy := x+s/2, float64(cv.h)/2
	r := 5.6 * mbScale
	for i := range n {
		a := (-225 + float64(i)*270/(n-1)) * math.Pi / 180
		cv.dot(cv.layer(false, i >= 8), cx+r*math.Cos(a), cy+r*math.Sin(a), 1.05*mbScale, 1)
	}
	return s
}

// renderMenuBar draws the item. It returns the PNG and whether it is a template image.
func renderMenuBar(segs []mbSeg, o mbOpts) ([]byte, bool) {
	mbFonts()
	// Measure with a generous canvas, then crop to the drawn width.
	cv := newMBCanvas(1600)
	x := 2.0 * mbScale
	gap := 7.0 * mbScale
	if o.Icon || len(segs) == 0 {
		x += cv.glyph(x) + 5*mbScale
	}
	mid := float64(cv.h) / 2
	base := mid + 4.6*mbScale // text baseline for 13 pt in an 18 pt bar
	limitIdx := []int{}
	for i, s := range segs {
		if s.Pct >= 0 {
			limitIdx = append(limitIdx, i)
		}
	}
	drawRing := func(items []mbSeg, size float64) float64 {
		cx, cy := x+size/2, mid
		th := pick(len(items) > 1, 1.8, 2.2) * mbScale
		for k, it := range items {
			r := size/2 - th/2 - float64(k)*(th+1.2*mbScale)
			cv.ring(cv.dim, cx, cy, r, th, 1, 1)
			cv.ring(cv.layer(it.Hot && o.Red, false), cx, cy, r, th, it.Pct/100, 1)
			if o.Pace && it.Pace > 0 {
				a := it.Pace * 2 * math.Pi
				cv.dot(cv.ink, cx+r*math.Sin(a), cy-r*math.Cos(a), 0.9*mbScale, 1)
			}
		}
		return size
	}
	piece := func(s mbSeg) float64 {
		start := x
		hot := s.Hot && o.Red
		switch {
		case len(s.Bars) > 0:
			maxV := 1e-9
			for _, v := range s.Bars {
				maxV = math.Max(maxV, v)
			}
			n := len(s.Bars)
			bw := pick(n > 10, 2.0, 3.2) * mbScale
			bg := pick(n > 10, 1.0, 1.6) * mbScale
			h := 13.0 * mbScale
			top := mid - h/2
			for i, v := range s.Bars {
				bx := x + float64(i)*(bw+bg)
				if n > 10 && i > s.Now {
					cv.dot(cv.dim, bx+bw/2, top+h-0.7*mbScale, 0.7*mbScale, 1)
					continue
				}
				bh := math.Max(1.2*mbScale, v/maxV*h)
				cv.rect(cv.layer(false, i != s.Now), bx, top+h-bh, bx+bw, top+h, 0.6*mbScale, 1)
			}
			x += float64(n) * (bw + bg)
		case s.Pct >= 0 && (o.Style == mbRing || o.Style == mbRings):
			x += drawRing([]mbSeg{s}, 14*mbScale) + 4*mbScale
			x = x + cv.labelValue(s, o, x, base, hot)
		case s.Pct >= 0 && o.Style == mbBar:
			lw := measure(mbMid, labelText(s, o)+s.Value)
			top := mid - 7*mbScale
			cv.labelValueFace(mbMid, s, o, x, top+9*mbScale, hot)
			w := math.Max(lw, 30*mbScale)
			barY := top + 11.5*mbScale
			cv.rect(cv.dim, x, barY, x+w, barY+2.5*mbScale, 1.25*mbScale, 1)
			cv.rect(cv.layer(hot, false), x, barY, x+w*s.Pct/100, barY+2.5*mbScale, 1.25*mbScale, 1)
			if o.Pace && s.Pace > 0 {
				px := x + w*s.Pace
				cv.rect(cv.ink, px-0.5*mbScale, barY-1.5*mbScale, px+0.5*mbScale, barY+4*mbScale, 0.3*mbScale, 1)
			}
			x += w
		case o.Style == mbStacked:
			lw, vw := measure(mbSmall, s.Label), measure(mbMid, s.Value)
			w := math.Max(lw, vw)
			cv.text(mbSmall, s.Label, x+(w-lw)/2, mid-1.5*mbScale, cv.dim)
			cv.text(mbMid, s.Value, x+(w-vw)/2, mid+8*mbScale, cv.layer(hot, false))
			x += w
		default:
			x += cv.labelValue(s, o, x, base, hot)
		}
		return x - start
	}
	switch o.Style {
	case mbRings:
		if len(limitIdx) > 0 {
			items := []mbSeg{}
			for _, i := range limitIdx[:min(3, len(limitIdx))] {
				items = append(items, segs[i])
			}
			x += drawRing(items, 17*mbScale) + 5*mbScale
			for k, i := range limitIdx[:min(2, len(limitIdx))] {
				if k > 0 {
					x += gap
				}
				x += cv.labelValue(segs[i], o, x, base, segs[i].Hot && o.Red)
			}
			for _, s := range segs {
				if s.Pct < 0 {
					x += gap
					piece(s)
				}
			}
			break
		}
		fallthrough
	default:
		if o.Style == mbDense {
			o2 := o
			o2.Style = mbText
			for i := 0; i < len(segs); i += 2 {
				if i > 0 {
					x += gap
				}
				w := 0.0
				for k, s := range segs[i:min(i+2, len(segs))] {
					y := mid - 1*mbScale + float64(k)*8.5*mbScale
					if i+1 >= len(segs) {
						y = base - 1*mbScale
					}
					w = math.Max(w, cv.labelValueFace(mbMid, s, o2, x, y, s.Hot && o.Red))
				}
				x += w
			}
			break
		}
		for i, s := range segs {
			if i > 0 {
				if o.Style == mbText && !o.Labels {
					x += 4 * mbScale
					cv.text(mbFace, "·", x, base, cv.dim)
					x += measure(mbFace, "·") + 4*mbScale
				} else {
					x += gap
				}
			}
			piece(s)
		}
	}
	w := int(math.Ceil(x + 2*mbScale))
	return composeMenuBar(cv, w, o)
}

func labelText(s mbSeg, o mbOpts) string {
	if o.Labels && s.Label != "" {
		return s.Label + " "
	}
	return ""
}

func (cv *mbCanvas) labelValue(s mbSeg, o mbOpts, x, base float64, hot bool) float64 {
	return cv.labelValueFace(mbFace, s, o, x, base, hot)
}

// labelValueFace draws "label value" (label dimmed) and returns its width.
func (cv *mbCanvas) labelValueFace(face font.Face, s mbSeg, o mbOpts, x, base float64, hot bool) float64 {
	w := 0.0
	if l := labelText(s, o); l != "" {
		w += cv.text(face, l, x, base, cv.dim)
	}
	w += cv.text(face, s.Value, x+w, base, cv.layer(hot, false))
	return w
}

// composeMenuBar crops and colours the layers. Without an alert it is a template (black + alpha, dimmed parts at
// lower alpha); with one, ink follows the bar's appearance and the alert layer is red.
func composeMenuBar(cv *mbCanvas, w int, o mbOpts) ([]byte, bool) {
	w = max(2, min(cv.w, w))
	img := image.NewNRGBA(image.Rect(0, 0, w, cv.h))
	hasAlert := false
	for _, a := range cv.alert.Pix {
		if a > 0 {
			hasAlert = true
			break
		}
	}
	ink := color.NRGBA{A: 255}
	if hasAlert || o.Preview {
		ink = pick(o.Dark, color.NRGBA{R: 255, G: 255, B: 255, A: 255}, color.NRGBA{R: 17, G: 17, B: 17, A: 255})
	}
	red := color.NRGBA{R: 240, G: 115, B: 102, A: 255}
	for y := range cv.h {
		for x := range w {
			ai := float64(cv.ink.AlphaAt(x, y).A) / 255
			ad := float64(cv.dim.AlphaAt(x, y).A) / 255 * 0.42
			ar := float64(cv.alert.AlphaAt(x, y).A) / 255
			// Over-composite: dim under ink under alert.
			col := [3]float64{}
			a := 0.0
			over := func(c color.NRGBA, sa float64) {
				if sa <= 0 {
					return
				}
				na := sa + a*(1-sa)
				for k, v := range []uint8{c.R, c.G, c.B} {
					col[k] = (float64(v)*sa + col[k]*a*(1-sa)) / na
				}
				a = na
			}
			over(ink, ad)
			over(ink, ai)
			if hasAlert {
				over(red, ar)
			} else {
				over(ink, ar)
			}
			if a > 0 {
				img.SetNRGBA(x, y, color.NRGBA{R: uint8(col[0]), G: uint8(col[1]), B: uint8(col[2]), A: uint8(math.Min(255, a*255+0.5))})
			}
		}
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes(), !hasAlert && !o.Preview
}
