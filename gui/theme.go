// Package gui is SimpleToken's UI (mygo native UI): the menu bar item, the drop-down panel and the main window.
// It is the only package that imports mygo; collection, limits and analytics live in internal/ and know nothing
// about the toolkit.
package gui

import (
	"math"

	"github.com/egoist/mygo/ui"
)

// Design language (shared with SimpleToggle v2): "quiet data, lit limits". Monochrome ground, hierarchy only
// from the ink's opacity, one signal colour for what is happening now (the live end point, a limit over its
// alert threshold, a refresh in progress). The panel is the Console surface (// captions), windows are the
// softened Signal surface (▪ captions, › selection).

// Pal names a palette (Settings → Appearance).
type Pal string

const (
	PalPaper    Pal = "paper"    // Cursor: warm neutrals + orange (default)
	PalGraphite Pal = "graphite" // Vercel: pure neutral, the signal is the ink itself
	PalSignal   Pal = "signal"   // Nothing: black and white + one red
	PalIce      Pal = "ice"      // Vercel blue
	PalPeach    Pal = "peach"    // opencode peach
	PalPhosphor Pal = "phosphor" // terminal green
)

var palettes = []Pal{PalPaper, PalGraphite, PalSignal, PalIce, PalPeach, PalPhosphor}

// Seven base colours per palette: bg, bg2 (sidebar), surf (card), elev (popover), fg (ink), signal, on-signal.
var palDark = map[Pal][7]string{
	PalPaper:    {"#14120b", "#1a1812", "#1d1b15", "#25231b", "#edecec", "#ff6a2b", "#ffffff"},
	PalGraphite: {"#0a0a0a", "#111111", "#141414", "#1c1c1c", "#ededed", "#f2f2f2", "#0a0a0a"},
	PalSignal:   {"#000000", "#0b0b0b", "#0f0f0f", "#191919", "#f5f5f5", "#ff2a1f", "#ffffff"},
	PalIce:      {"#0a0a0a", "#111111", "#141414", "#1c1c1c", "#ededed", "#52a8ff", "#00142b"},
	PalPeach:    {"#0a0a0a", "#141414", "#171717", "#1e1e1e", "#eeeeee", "#fab283", "#1a1009"},
	PalPhosphor: {"#060907", "#0b100c", "#0e140f", "#141d16", "#d9e8dc", "#7fd88f", "#06120a"},
}
var palLight = map[Pal][7]string{
	PalPaper:    {"#f7f7f4", "#f0efea", "#fbfbf9", "#ffffff", "#26251e", "#f54e00", "#ffffff"},
	PalGraphite: {"#fafafa", "#f2f2f2", "#ffffff", "#ffffff", "#171717", "#171717", "#ffffff"},
	PalSignal:   {"#ffffff", "#f3f3f3", "#ffffff", "#ffffff", "#000000", "#d71921", "#ffffff"},
	PalIce:      {"#ffffff", "#f7f7f7", "#ffffff", "#ffffff", "#171717", "#006bff", "#ffffff"},
	PalPeach:    {"#ffffff", "#fafafa", "#ffffff", "#ffffff", "#1a1a1a", "#d07a2d", "#ffffff"},
	PalPhosphor: {"#f4f7f3", "#ebf0ea", "#fbfdfb", "#ffffff", "#13201a", "#1f8a4c", "#ffffff"},
}

func normalizePal(p Pal) Pal {
	if _, ok := palDark[p]; ok {
		return p
	}
	return PalPaper
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
	Ink                     [4]ui.Color // opaque series ladder (ink mixed into the card colour)
	Vendor                  vendorColors
	Surface                 Surface
}

// vendorColors are the vendor ladders (validated for colour-blind separation). xAI (Grok Bot, Cursor) is
// deliberately black and white: its colour is the ink.
type vendorColors struct {
	Anthropic, Anthropic2, Anthropic3, OpenAI, OpenAI2, Google, Google2, XAI, XAI2, Other ui.Color
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
	pl.Ink = [4]ui.Color{mix(pl.Surf, pl.FG, 0.86), mix(pl.Surf, pl.FG, 0.58), mix(pl.Surf, pl.FG, 0.36), mix(pl.Surf, pl.FG, 0.20)}
	if dark {
		pl.Green, pl.Red, pl.Amber = ui.Hex("#46c08a"), ui.Hex("#ff5f57"), ui.Hex("#e8a73c")
		pl.Vendor = vendorColors{Anthropic: ui.Hex("#c17755"), Anthropic2: ui.Hex("#f8d7be"), Anthropic3: ui.Hex("#6e3a28"),
			OpenAI: ui.Hex("#209993"), OpenAI2: ui.Hex("#b3e6e2"), Google: ui.Hex("#505ba7"), Google2: ui.Hex("#8fa3e0"), Other: ui.Hex("#6a6a6e")}
	} else {
		pl.Green, pl.Red, pl.Amber = ui.Hex("#1f8a65"), ui.Hex("#d1383d"), ui.Hex("#b7791f")
		pl.Vendor = vendorColors{Anthropic: ui.Hex("#b4663f"), Anthropic2: ui.Hex("#e9b48f"), Anthropic3: ui.Hex("#6e3a28"),
			OpenAI: ui.Hex("#008c82"), OpenAI2: ui.Hex("#7cc8c2"), Google: ui.Hex("#4a58b2"), Google2: ui.Hex("#8495d6"), Other: ui.Hex("#8a8a8e")}
	}
	pl.Vendor.XAI, pl.Vendor.XAI2 = pl.Ink[0], pl.Ink[1]
	if p == PalSignal {
		pl.Red = pl.Sig // Nothing: red is the only signal; errors are told apart by their ✕ mark
	}
	return pl
}

// panelStyle returns the palette for the Console surface.
func (p palette) panelStyle() palette { p.Surface = surfacePanel; return p }

func (p palette) sigSoft() ui.Color  { return alpha(p.Sig, 0.14) }
func (p palette) sigLine() ui.Color  { return alpha(p.Sig, 0.55) }
func (p palette) glow() ui.Color     { return alpha(p.Sig, 0.55) }
func (p palette) glowSoft() ui.Color { return alpha(p.Sig, 0.24) }

// Radii: panel (Console) 5 / 8 / 12, windows (softened Signal) 4 / 6 / 10.
func (p palette) rCtl() float32 {
	if p.Surface == surfacePanel {
		return 5
	}
	return 4
}
func (p palette) rCard() float32 {
	if p.Surface == surfacePanel {
		return 8
	}
	return 6
}

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
