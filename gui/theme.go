// Package gui is SimpleToken's UI (mygo native UI): the menu bar item, the drop-down panel and the main window.
// It is the only package that imports mygo; collection, limits and analytics live in internal/ and know nothing
// about the toolkit.
package gui

import (
	"math"

	"github.com/egoist/mygo/ui"
)

// Design language (SimpleToggle, Graphite): colour lives in the data, the interface stays neutral. Hierarchy
// comes only from the ink's opacity; one signal colour marks what is happening now (the live end point, the
// elapsed-time needle, a refresh), and only that and an over-threshold limit glow. The panel is the Console
// surface (// captions), windows are the softened Signal surface (▪ captions, › selection). Values follow
// designs/simpletoken-v3/project/theme.css; the light variants of the data colours were validated on white
// with the dataviz palette validator, the dark ones on #161616.

// Pal names an interface palette (Settings → Appearance); each has a dark and a light variant.
type Pal string

const (
	PalGraphite Pal = "graphite" // neutral greys, the signal is the ink itself (default)
	PalPaper    Pal = "paper"    // warm neutrals, orange signal
	PalIce      Pal = "ice"      // neutral greys, blue signal
)

var palettes = []Pal{PalGraphite, PalPaper, PalIce}

// Seven base colours per palette: bg, bg2 (sidebar), card, elev (popover), fg (ink), signal, on-signal.
var palDark = map[Pal][7]string{
	PalGraphite: {"#0a0a0a", "#111111", "#161616", "#1c1c1c", "#ededed", "#f2f2f2", "#0a0a0a"},
	PalPaper:    {"#14120b", "#1b1913", "#1f1d16", "#25231b", "#edecec", "#ff6a2b", "#ffffff"},
	PalIce:      {"#0a0a0a", "#111111", "#161616", "#1c1c1c", "#ededed", "#52a8ff", "#00142b"},
}
var palLight = map[Pal][7]string{
	PalGraphite: {"#fafafa", "#f2f2f2", "#ffffff", "#ffffff", "#171717", "#171717", "#ffffff"},
	PalPaper:    {"#f7f7f4", "#f0efea", "#fbfbf9", "#ffffff", "#26251e", "#f54e00", "#ffffff"},
	PalIce:      {"#ffffff", "#f7f7f7", "#ffffff", "#ffffff", "#171717", "#006bff", "#ffffff"},
}

// normalizePal maps unknown names, and the six palettes of the first v2 builds, onto the three that remain.
func normalizePal(p Pal) Pal {
	switch p {
	case PalGraphite, PalPaper, PalIce:
		return p
	case "peach":
		return PalPaper
	}
	return PalGraphite
}

// Surface is the look of a window: the panel (Console) or a window (softened Signal).
type Surface int

const (
	surfaceWork Surface = iota
	surfacePanel
)

// palette is every colour the views use, derived from the seven base colours.
type palette struct {
	Dark                    bool
	BG, BG2, Surf, Elev, FG ui.Color
	L1, L2, L3, L4          ui.Color // ink 4 / 8 / 13 / 22 %: hairlines and fills
	T1, T2, T3, T4          ui.Color // ink 94 / 64 / 42 / 26 %: text levels
	Sig, OnSig              ui.Color
	Green, Red, Amber       ui.Color
	DotOff                  ui.Color
	// Ink is the series ladder when colour is off: the ink at 92 / 62 / 42 / 26 / 14 % over the card, opaque so
	// stacked marks never show through.
	Ink     [5]ui.Color
	Vendor  vendorColors
	Model   modelColors
	Tool    toolColors
	Accent  accentColors
	Surface Surface
}

// vendorColors mark a vendor: its logo and its limit gauges. xAI (Grok Bot, Cursor) is the ink.
type vendorColors struct{ Anthropic, OpenAI, Google, XAI, Other ui.Color }

// modelColors are the fixed series colours: colour follows the model family, never its rank. Past these, models
// fold into Other (neutral). Validated as one categorical set in this order (adjacent stack neighbours).
type modelColors struct{ Opus, Sonnet, Codex, Gemini, Haiku, Fable, Other ui.Color }

// toolColors: Claude Code clay, Codex slate, Gemini CLI violet; Cursor stays ink.
type toolColors struct{ Claude, Codex, Gemini, Cursor ui.Color }

// accentColors are the single-series accents with their sequential ramps (one hue, light→dark on light, dark→
// light on dark: index 0 is always the lowest value).
type accentColors struct {
	Slate, Clay, Violet, Rose ui.Color
	SlateR, ClayR, VioletR    [4]ui.Color
}

func newPalette(dark bool, p Pal) palette {
	p = normalizePal(p)
	v := palLight[p]
	if dark {
		v = palDark[p]
	}
	pl := palette{Dark: dark, Surface: surfaceWork}
	pl.BG, pl.BG2, pl.Surf, pl.Elev, pl.FG = ui.Hex(v[0]), ui.Hex(v[1]), ui.Hex(v[2]), ui.Hex(v[3]), ui.Hex(v[4])
	pl.Sig, pl.OnSig = ui.Hex(v[5]), ui.Hex(v[6])
	pl.L1, pl.L2, pl.L3, pl.L4 = alpha(pl.FG, 0.04), alpha(pl.FG, 0.08), alpha(pl.FG, 0.13), alpha(pl.FG, 0.22)
	pl.T1, pl.T2, pl.T3, pl.T4 = alpha(pl.FG, 0.94), alpha(pl.FG, 0.64), alpha(pl.FG, 0.42), alpha(pl.FG, 0.26)
	pl.DotOff = alpha(pl.FG, 0.09)
	for i, a := range []float32{0.92, 0.62, 0.42, 0.26, 0.14} {
		pl.Ink[i] = mix(pl.Surf, pl.FG, a)
	}
	hex := func(dark, light string) ui.Color { return ui.Hex(pick(pl.Dark, dark, light)) }
	if dark {
		pl.Green, pl.Red, pl.Amber = ui.Hex("#46c08a"), ui.Hex("#ff5f57"), ui.Hex("#e8a73c")
	} else {
		pl.Green, pl.Red, pl.Amber = ui.Hex("#1f8a65"), ui.Hex("#d1383d"), ui.Hex("#b7791f")
	}
	pl.Model = modelColors{
		Opus: hex("#c87f59", "#be6e46"), Sonnet: hex("#9a5032", "#843c1c"), Codex: hex("#7093d4", "#6390e0"),
		Gemini: hex("#835895", "#713787"), Haiku: hex("#c37077", "#c9607a"), Fable: hex("#7d72c2", "#7a5fb0"),
		Other: pl.Ink[3],
	}
	pl.Vendor = vendorColors{Anthropic: pl.Model.Opus, OpenAI: pl.Model.Codex, Google: pl.Model.Gemini, XAI: pl.Ink[0], Other: pl.Ink[2]}
	pl.Tool = toolColors{Claude: pl.Model.Opus, Codex: pl.Model.Codex, Gemini: pl.Model.Gemini, Cursor: pl.Ink[2]}
	pl.Accent = accentColors{
		Slate: pl.Model.Codex, Clay: pl.Model.Opus, Violet: hex("#8670b8", "#7a5fb0"), Rose: pl.Model.Haiku,
	}
	if dark {
		pl.Accent.SlateR = hexes("#3e4f78", "#566fa6", "#7093d4", "#a9bfe9")
		pl.Accent.ClayR = hexes("#723c25", "#97532f", "#c87f59", "#e6b093")
		pl.Accent.VioletR = hexes("#544579", "#6a5893", "#8670b8", "#bcaee0")
	} else {
		pl.Accent.SlateR = hexes("#9ab0e2", "#7a99d8", "#5579c4", "#34549a")
		pl.Accent.ClayR = hexes("#e2a985", "#c97f55", "#a85d35", "#7a3d1c")
		pl.Accent.VioletR = hexes("#b8a6dd", "#9479c4", "#7457a8", "#4f3780")
	}
	return pl
}

func hexes(a, b, c, d string) [4]ui.Color {
	return [4]ui.Color{ui.Hex(a), ui.Hex(b), ui.Hex(c), ui.Hex(d)}
}

// panelStyle returns the palette for the Console surface.
func (p palette) panelStyle() palette { p.Surface = surfacePanel; return p }

func (p palette) sigSoft() ui.Color  { return alpha(p.Sig, 0.14) }
func (p palette) sigLine() ui.Color  { return alpha(p.Sig, 0.55) }
func (p palette) glow() ui.Color     { return alpha(p.Sig, 0.55) }
func (p palette) glowSoft() ui.Color { return alpha(p.Sig, 0.24) }

// dim is a series colour's "where it is heading" tone: the same hue at 30 %.
func dim(c ui.Color) ui.Color { return alpha(c, 0.3) }

// Radii: panel (Console) 5 / 8 / 12, windows (softened Signal) 4 / 8 / 10. Cards are 8 on both (theme.css .w).
func (p palette) rCtl() float32 {
	if p.Surface == surfacePanel {
		return 5
	}
	return 4
}
func (p palette) rCard() float32 { return 8 }

// theme maps the palette onto mygo's controls.
func (p palette) theme(base *ui.Theme) *ui.Theme {
	registerFonts()
	t := *base
	t.Dark = p.Dark
	t.Background, t.Surface = p.BG, p.Surf
	t.SurfaceHover, t.SurfacePressed = alpha(p.FG, 0.06), alpha(p.FG, 0.10)
	t.Border = p.L3
	t.Text, t.TextMuted = p.T1, p.T2
	t.Accent, t.AccentHover, t.AccentPressed, t.AccentText = p.Sig, alpha(p.Sig, 0.88), alpha(p.Sig, 0.78), p.OnSig
	t.Danger, t.Warning, t.Success = p.Red, p.Amber, p.Green
	t.Selection, t.Focus = alpha(p.Sig, 0.22), alpha(p.Sig, 0.45)
	t.Inverse, t.InverseText = p.FG, p.BG
	t.Radius = p.rCtl()
	t.Font = uiFont
	return &t
}

func alpha(c ui.Color, a float32) ui.Color { return ui.RGBA(c.R, c.G, c.B, a) }

// mix blends a toward b by t, opaque (for series fills that must not show through when stacked).
func mix(a, b ui.Color, t float32) ui.Color {
	ch := func(x, y uint8) uint8 { return uint8(float32(x) + (float32(y)-float32(x))*t + 0.5) }
	return ui.RGBA(ch(a.R, b.R), ch(a.G, b.G), ch(a.B, b.B), 1)
}

func pick[T any](cond bool, a, b T) T {
	if cond {
		return a
	}
	return b
}

func clamp01(v float64) float64 { return math.Max(0, math.Min(1, v)) }
