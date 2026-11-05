package gui

import (
	"embed"
	"log"
	"sync"

	"github.com/egoist/mygo/ui"
)

// Fonts: Geist (UI and the big figures) and Geist Mono (labels, numbers, model ids). Vercel's open fonts, SIL OFL
// 1.1 (fonts/OFL.txt).
//
//go:embed fonts/*.ttf
var fontFiles embed.FS

const (
	uiFont   = "Geist, PingFang SC"
	monoFont = "Geist Mono, PingFang SC"
)

var fontsOnce sync.Once

// registerFonts registers the embedded fonts once, before the first view draws.
func registerFonts() {
	fontsOnce.Do(func() {
		for _, f := range []struct{ file, family string }{
			{"Geist-Regular.ttf", "Geist"}, {"Geist-Medium.ttf", "Geist"}, {"Geist-SemiBold.ttf", "Geist"},
			{"GeistMono-Regular.ttf", "Geist Mono"}, {"GeistMono-Medium.ttf", "Geist Mono"}, {"GeistMono-SemiBold.ttf", "Geist Mono"},
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
