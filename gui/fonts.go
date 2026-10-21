package gui

import (
	"embed"
	"log"
	"sync"

	"github.com/egoist/mygo/ui"
)

// Fonts: Geist (UI), Geist Mono (labels, numbers, model ids) and Geist Pixel Circle (dot face for the defining
// numbers). Vercel's open fonts, SIL OFL 1.1 (fonts/OFL.txt); the pixel face keeps basic Latin only.
//
//go:embed fonts/*.ttf
var fontFiles embed.FS

const (
	uiFont   = "Geist, PingFang SC"
	monoFont = "Geist Mono, PingFang SC"
	dotFont  = "Geist Pixel Circle, Geist Mono"
)

var fontsOnce sync.Once

// registerFonts registers the embedded fonts once, before the first view draws.
func registerFonts() {
	fontsOnce.Do(func() {
		for _, f := range []struct{ file, family string }{
			{"Geist-Regular.ttf", "Geist"}, {"Geist-Medium.ttf", "Geist"}, {"Geist-SemiBold.ttf", "Geist"},
			{"GeistMono-Regular.ttf", "Geist Mono"}, {"GeistMono-Medium.ttf", "Geist Mono"}, {"GeistMono-SemiBold.ttf", "Geist Mono"},
			{"GeistPixel-Circle.ttf", "Geist Pixel Circle"},
		} {
			data, err := fontFiles.ReadFile("fonts/" + f.file)
			if err == nil {
				err = ui.RegisterFont(data, f.family)
			}
			if err != nil {
				log.Println("font", f.file, err)
			}
		}
	})
}
