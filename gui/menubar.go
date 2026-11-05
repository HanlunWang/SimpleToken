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

// The three styles of the v3 design.
const (
	mbGauge   mbStyle = "gauge"   // the first limit as a tick gauge glyph, then the values
	mbNumbers mbStyle = "numbers" // the values alone
	mbBars    mbStyle = "bars"    // today's hours as bars, then the values
)

// mbSeg is one item: a limit (Pct ≥ 0), a number (Value), or mini bars (Bars).
type mbSeg struct {
	Label string
	Value string
	After string  // drawn after the value, softer (the session's reset countdown)
	Pct   float64 // −1 when not a limit
	Pace  float64 // 0…1, share of the window gone
	Hot   bool    // at or over the top alert threshold
	Bars  []float64
	Now   int // highlighted bar; bars after it are future (dots)
}

type mbOpts struct {
	Style mbStyle
	Pace  bool
	Icon  bool
	Red   bool // turn red near the limit
	Dark  bool // the menu bar's appearance (only used for the colour image)
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
		mbFace = load("GeistMono-Medium.ttf", 12)
		mbMid = load("GeistMono-Medium.ttf", 10.5)
		mbSmall = load("Geist-SemiBold.ttf", 8.5)
	})
}

// mbCanvas is an alpha mask per colour role, composed into the final image.
type mbCanvas struct {
	ink, alert, dim, soft *image.Alpha // soft: secondary values (62 %); dim: the gauge's rest (35 %)
	w, h                  int
	x                     float64 // pen position in pixels
}

func newMBCanvas(w int) *mbCanvas {
	h := 18 * mbScale
	r := image.Rect(0, 0, w, h)
	return &mbCanvas{ink: image.NewAlpha(r), alert: image.NewAlpha(r), dim: image.NewAlpha(r), soft: image.NewAlpha(r), w: w, h: h}
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

// tickGauge is the limit gauge as a glyph: 22 ticks on a 270° arc, the used ones in ink (the alert red when hot),
// the rest dim. It is 15 pt wide.
func (cv *mbCanvas) tickGauge(x float64, s mbSeg, hot bool) float64 {
	const n = 22
	size := 15.0 * mbScale
	k := size / 132 // the board's 132-unit view box
	cx, cy := x+(60+6)*k, float64(cv.h)/2+(62+6-62)*k-1*mbScale
	for i := range n {
		f := float64(i) / (n - 1)
		a := (135 + 270*f) * math.Pi / 180
		x0, y0 := cx+43*k*math.Cos(a), cy+43*k*math.Sin(a)
		x1, y1 := cx+53*k*math.Cos(a), cy+53*k*math.Sin(a)
		dst := cv.dim
		if s.Pct > 0 && f*100 <= s.Pct+0.01 {
			dst = cv.layer(hot, false)
		}
		cv.line(dst, x0, y0, x1, y1, 7*k)
	}
	return size
}

// line paints a round-capped segment of width w.
func (cv *mbCanvas) line(dst *image.Alpha, x0, y0, x1, y1, w float64) {
	dx, dy := x1-x0, y1-y0
	l2 := dx*dx + dy*dy
	cv.coverage(dst, math.Min(x0, x1)-w, math.Min(y0, y1)-w, math.Max(x0, x1)+w, math.Max(y0, y1)+w, func(x, y float64) bool {
		t := 0.0
		if l2 > 0 {
			t = math.Max(0, math.Min(1, ((x-x0)*dx+(y-y0)*dy)/l2))
		}
		return math.Hypot(x-(x0+t*dx), y-(y0+t*dy)) <= w/2
	}, 1)
}

// renderMenuBar draws the item. It returns the PNG and whether it is a template image.
func renderMenuBar(segs []mbSeg, o mbOpts) ([]byte, bool) {
	mbFonts()
	// Measure with a generous canvas, then crop to the drawn width.
	cv := newMBCanvas(1600)
	x := 2.0 * mbScale
	gap := 6.0 * mbScale
	mid := float64(cv.h) / 2
	base := mid + 4.3*mbScale // text baseline for 12 pt in an 18 pt bar
	firstLimit, bars := -1, -1
	for i, s := range segs {
		if s.Pct >= 0 && firstLimit < 0 {
			firstLimit = i
		}
		if len(s.Bars) > 0 && bars < 0 {
			bars = i
		}
	}
	glyph := false
	switch {
	case o.Style == mbGauge && firstLimit >= 0:
		x += cv.tickGauge(x, segs[firstLimit], segs[firstLimit].Hot && o.Red) + gap
		glyph = true
	case o.Style == mbBars && bars >= 0:
		x += cv.miniBars(x, segs[bars]) + gap
		glyph = true
	case o.Icon || len(segs) == 0:
		x += cv.glyph(x) + 5*mbScale
	}
	n := 0
	for i, s := range segs {
		if len(s.Bars) > 0 {
			if glyph && i == bars {
				continue
			}
			if n > 0 {
				x += gap
			}
			x += cv.miniBars(x, s)
			n++
			continue
		}
		if n > 0 {
			x += gap
		}
		hot := s.Hot && o.Red
		layer := cv.layer(hot, false)
		if s.Pct < 0 && !hot {
			layer = cv.soft
		}
		x += cv.text(mbFace, s.Value, x, base, layer)
		if s.After != "" {
			x += 4 * mbScale
			x += cv.text(mbFace, s.After, x, base, cv.soft)
		}
		n++
	}
	w := int(math.Ceil(x + 2*mbScale))
	return composeMenuBar(cv, w, o)
}

// miniBars paints a bars item (today by hour, the last 7 days): the current bar in ink, the rest dim, future
// slots dots.
func (cv *mbCanvas) miniBars(x float64, s mbSeg) float64 {
	mid := float64(cv.h) / 2
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
	return float64(n) * (bw + bg)
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
			ad := float64(cv.dim.AlphaAt(x, y).A) / 255 * 0.35
			as := float64(cv.soft.AlphaAt(x, y).A) / 255 * 0.62
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
			over(ink, as)
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
