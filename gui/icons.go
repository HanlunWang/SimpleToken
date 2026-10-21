package gui

import (
	"bytes"
	"compress/gzip"
	"embed"
	"encoding/json"
	"io"
	"strings"
	"sync"

	"github.com/egoist/mygo/ui"
)

// icons/lucide.json.gz is every icon of lucide-static 0.469.0 (name → compact SVG), ISC (icons/LUCIDE_LICENSE).
//
//go:embed icons/lucide.json.gz
var lucideGz []byte

// logos/*.svg are the mono brand marks (yldm-tech/ai-logo, see THIRD_PARTY_NOTICES), tinted by the UI.
//
//go:embed logos/*.svg
var logoFiles embed.FS

var (
	lucideOnce sync.Once
	lucideSrc  map[string]string
	svgMu      sync.Mutex
	svgCache   = map[string]*ui.SVG{}
)

func lucide() map[string]string {
	lucideOnce.Do(func() {
		lucideSrc = map[string]string{}
		r, err := gzip.NewReader(bytes.NewReader(lucideGz))
		if err != nil {
			return
		}
		data, err := io.ReadAll(r)
		if err != nil {
			return
		}
		_ = json.Unmarshal(data, &lucideSrc)
	})
	return lucideSrc
}

// svgNamed parses (once) a Lucide icon ("rotate-cw") or a logo ("logo:claude").
func svgNamed(name string) *ui.SVG {
	svgMu.Lock()
	defer svgMu.Unlock()
	if s, ok := svgCache[name]; ok {
		return s
	}
	var src []byte
	if logo, ok := strings.CutPrefix(name, "logo:"); ok {
		src, _ = logoFiles.ReadFile("logos/" + logo + ".svg")
	} else if s, ok := lucide()[name]; ok {
		src = []byte(s)
	}
	var parsed *ui.SVG
	if len(src) > 0 {
		parsed, _ = ui.ParseSVG(src)
	}
	svgCache[name] = parsed
	return parsed
}

// icon draws a Lucide icon in the current text colour.
func icon(c *ui.Context, name string, size float32) ui.Element {
	if s := svgNamed(name); s != nil {
		return ui.Icon(c, s).FontSize(size)
	}
	return ui.Box(c).Size(size, size)
}
