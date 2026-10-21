package gui

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func demoSegs() map[string][]mbSeg {
	hours := []float64{0, 0, 0, 0, 0, 0, 0, 0, 2, 5, 9, 8, 4, 6, 9, 11, 7, 0, 0, 0, 0, 0, 0, 0}
	return map[string][]mbSeg{
		"claude": {{Label: "5h", Value: "38%", Pct: 38, Pace: 0.52}, {Label: "wk", Value: "57%", Pct: 57, Pace: 0.62}},
		"three":  {{Label: "Claude 5h", Value: "38%", Pct: 38, Pace: 0.52}, {Label: "Codex 5h", Value: "12%", Pct: 12, Pace: 0.39}, {Label: "Cursor wk", Value: "44%", Pct: 44, Pace: 0.48}},
		"today":  {{Label: "5h", Value: "38%", Pct: 38, Pace: 0.52}, {Label: "wk", Value: "57%", Pct: 57, Pace: 0.62}, {Label: "today", Value: "89.5M", Pct: -1}},
		"hot":    {{Label: "5h", Value: "86%", Pct: 86, Pace: 0.7, Hot: true}, {Label: "wk", Value: "57%", Pct: 57, Pace: 0.62}},
		"hours":  {{Bars: hours, Now: 15, Pct: -1}, {Label: "today", Value: "$55", Pct: -1}},
		"empty":  nil,
	}
}

// TestMenuBarRenders checks every style draws something; with SIMPLETOKEN_SHOTS it also writes a contact sheet.
func TestMenuBarRenders(t *testing.T) {
	styles := []mbStyle{mbText, mbStacked, mbDense, mbRing, mbRings, mbBar}
	names := []string{"claude", "three", "today", "hot", "hours", "empty"}
	var rows []image.Image
	for _, dark := range []bool{true, false} {
		for _, n := range names {
			for _, st := range styles {
				o := mbOpts{Style: st, Labels: n == "three", Pace: true, Icon: true, Red: true, Dark: dark}
				data, tmpl := renderMenuBar(demoSegs()[n], o)
				img, err := png.Decode(bytes.NewReader(data))
				if err != nil {
					t.Fatalf("%s/%s: %v", n, st, err)
				}
				if img.Bounds().Dy() != 36 || img.Bounds().Dx() < 20 {
					t.Fatalf("%s/%s: size %v", n, st, img.Bounds())
				}
				if n == "hot" && tmpl {
					t.Errorf("%s/%s: an over-threshold value must not be a template image", n, st)
				}
				if n != "hot" && !tmpl {
					t.Errorf("%s/%s: expected a template image", n, st)
				}
				rows = append(rows, onBar(img, dark, tmpl))
			}
		}
	}
	dir := os.Getenv("SIMPLETOKEN_SHOTS")
	if dir == "" {
		return
	}
	sheet := image.NewNRGBA(image.Rect(0, 0, 6*300, len(rows)/6*44))
	for i, im := range rows {
		x, y := (i%6)*300, (i/6)*44
		draw.Draw(sheet, image.Rect(x, y, x+300, y+44), im, image.Point{}, draw.Src)
	}
	f, _ := os.Create(filepath.Join(dir, "menubar.png"))
	defer f.Close()
	_ = png.Encode(f, sheet)
}

// onBar composes an item on a menu bar strip as macOS would tint a template image.
func onBar(img image.Image, dark, tmpl bool) image.Image {
	bg := pick(dark, color.NRGBA{30, 30, 32, 255}, color.NRGBA{236, 236, 238, 255})
	out := image.NewNRGBA(image.Rect(0, 0, 300, 44))
	draw.Draw(out, out.Bounds(), &image.Uniform{bg}, image.Point{}, draw.Src)
	ink := pick(dark, color.NRGBA{255, 255, 255, 255}, color.NRGBA{0, 0, 0, 255})
	b := img.Bounds()
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < min(b.Dx(), 290); x++ {
			r, g, bb, a := img.At(x, y).RGBA()
			if a == 0 {
				continue
			}
			src := color.NRGBA{uint8(r * 255 / a), uint8(g * 255 / a), uint8(bb * 255 / a), uint8(a >> 8)}
			if tmpl {
				src = color.NRGBA{ink.R, ink.G, ink.B, uint8(a >> 8)}
			}
			d := out.NRGBAAt(x+5, y+4)
			fa := float64(src.A) / 255
			out.SetNRGBA(x+5, y+4, color.NRGBA{uint8(float64(src.R)*fa + float64(d.R)*(1-fa)), uint8(float64(src.G)*fa + float64(d.G)*(1-fa)), uint8(float64(src.B)*fa + float64(d.B)*(1-fa)), 255})
		}
	}
	return out
}
