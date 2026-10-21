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
	"time"

	"github.com/egoist/mygo/ui"
)

// TestReadmeImages writes the README screenshots (demo data, 2x) into $SIMPLETOKEN_README_IMAGES:
//
//	SIMPLETOKEN_README_IMAGES=docs/images go test ./gui/ -run TestReadmeImages
func TestReadmeImages(t *testing.T) {
	dir := os.Getenv("SIMPLETOKEN_README_IMAGES")
	if dir == "" {
		t.Skip("set SIMPLETOKEN_README_IMAGES to write the README screenshots")
	}
	if !filepath.IsAbs(dir) {
		dir = filepath.Join("..", dir) // tests run in gui/
	}
	render := func(name string, view func(*ui.Context), w, h int, trim bool) {
		tt := ui.NewTester(view, w, h)
		tt.SetScale(2)
		tt.Frame()
		tt.Frame()
		tt.Advance(2 * time.Second)
		var img image.Image = tt.Image()
		if trim {
			img = trimBottom(img)
		}
		writePNG(t, filepath.Join(dir, name+".png"), img)
	}

	for _, theme := range []string{"dark", "light"} {
		a := newDemoCtrl(t)
		a.m.s.Theme = theme
		name := "dashboard"
		if theme == "light" {
			name = "dashboard-light"
		}
		render(name, a.windowView, 1240, 860, false)
	}

	p := newDemoCtrl(t)
	render("panel", p.panelView, 360, 1000, true)

	s := newDemoCtrl(t)
	s.w.settings, s.w.tab = true, "appearance"
	render("settings", s.windowView, 1080, 460, false)

	// Menu bar: every style on the same values, dark and light menu bars side by side.
	styles := []mbStyle{mbText, mbStacked, mbDense, mbRing, mbRings, mbBar}
	const cell = 420
	sheet := image.NewNRGBA(image.Rect(0, 0, 2*cell, len(styles)*44))
	for i, st := range styles {
		for j, dark := range []bool{true, false} {
			o := mbOpts{Style: st, Pace: true, Icon: true, Red: true, Dark: dark}
			data, tmpl := renderMenuBar(demoSegs()["today"], o)
			img, err := png.Decode(bytes.NewReader(data))
			if err != nil {
				t.Fatal(err)
			}
			r := image.Rect(j*cell, i*44, j*cell+cell, i*44+44)
			draw.Draw(sheet, r, &image.Uniform{pick(dark, color.NRGBA{30, 30, 32, 255}, color.NRGBA{236, 236, 238, 255})}, image.Point{}, draw.Src)
			draw.Draw(sheet, r, onBar(img, dark, tmpl), image.Point{}, draw.Src)
		}
	}
	writePNG(t, filepath.Join(dir, "menubar.png"), sheet)
}

// trimBottom cuts the rows at the bottom that are the same colour as the last one.
func trimBottom(img image.Image) image.Image {
	b := img.Bounds()
	last := func(y int) bool {
		for x := b.Min.X; x < b.Max.X; x++ {
			if img.At(x, y) != img.At(x, b.Max.Y-1) {
				return false
			}
		}
		return true
	}
	y := b.Max.Y - 1
	for y > b.Min.Y && last(y) {
		y--
	}
	end := min(b.Max.Y, y+1+24) // keep a little of the background
	return img.(interface {
		SubImage(image.Rectangle) image.Image
	}).SubImage(image.Rect(b.Min.X, b.Min.Y, b.Max.X, end))
}

func writePNG(t *testing.T, path string, img image.Image) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}
