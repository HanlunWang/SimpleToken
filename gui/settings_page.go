package gui

import (
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
	"github.com/HanlunWang/SimpleToken/internal/paths"
	"github.com/HanlunWang/SimpleToken/internal/settings"
)

var settingsTabs = [][3]string{
	{"general", "General", "sliders-horizontal"}, {"appearance", "Appearance", "palette"}, {"menubar", "Menu Bar", "panel-top"},
	{"panel", "Panel", "panel-top-open"}, {"widgets", "Widgets", "layout-grid"}, {"models", "Models & Tools", "boxes"},
	{"limits", "Limits & Alerts", "gauge"}, {"data", "Data", "database"},
}

// navItem is a sidebar row: mono label, › and the signal colour when selected, no fill.
func (p palette) navItem(c *ui.Context, key, iconName, label string, selected bool) ui.Element {
	r := ui.Row(c.Key(key)).FillWidth().Height(28).Padding(0, 8, 0, 14).Radius(p.rCtl()).Gap(9).AlignItems(ui.Center).Label(label)
	r.Background(r.AnimateColor("hover", pick(r.Hovered() && !selected, p.L1, ui.Transparent), animHover))
	col := pick(selected, p.Sig, pick(r.Hovered(), p.T1, p.T2))
	col = r.AnimateColor("fg", col, animColor)
	r.Children(func() {
		if selected {
			ui.Text(c.Key("sel"), "›").Font(monoFont).FontSize(13).FontWeight(600).TextColor(p.Sig).Absolute().Left(2).Top(5).PassThrough()
		}
		icon(c, iconName, 15).TextColor(col)
		ui.Text(c, label).Font(monoFont).FontSize(12.5).TextColor(col).SingleLine().Grow(1)
	})
	return r
}

// sGroup is a framed group of rows with its caption on the frame.
func (p palette) sGroup(c *ui.Context, key, title string, right func(), body func()) {
	ui.Column(c.Key(key)).FillWidth().Margin(18, 0, 0).Padding(8, 16).Radius(p.rCard()).Border(1, p.L2).Children(func() {
		ui.Row(c.Key("t")).Absolute().Top(-8).Left(10).Padding(0, 6).Background(p.BG).Children(func() { p.caption(c, title) })
		if right != nil {
			ui.Row(c.Key("r")).Absolute().Top(-11).Right(10).Padding(0, 6).Background(p.BG).Gap(6).Children(right)
		}
		body()
	})
}

// sRow is one setting: label and detail on the left, the control on the right, a hairline below.
func (p palette) sRow(c *ui.Context, key, label, detail string, control func()) {
	ui.Row(c.Key(key)).FillWidth().Padding(11, 0).Gap(16).AlignItems(ui.Center).Children(func() {
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(3).Children(func() {
			ui.Text(c, label).FontSize(12.5).TextColor(p.T1).Wrap()
			if detail != "" {
				ui.Text(c, detail).FontSize(11).TextColor(p.T3).LineHeight(1.5).Wrap()
			}
		})
		ui.Row(c).Gap(6).AlignItems(ui.Center).Shrink(0).Children(control)
	})
}

func (a *ctrl) settingsPage(c *ui.Context, p palette) {
	w := a.w
	ui.Row(c.Key("sp")).Fill().Children(func() {
		ui.Column(c.Key("nav")).Width(200).FillHeight().Background(p.BG2).Padding(14, 10).Gap(1).Shrink(0).Children(func() {
			ui.Box(c).Absolute().Right(0).Top(0).Width(1).FillHeight().Background(p.L2)
			for _, t := range settingsTabs {
				if p.navItem(c, t[0], t[2], L(t[1]), w.tab == t[0]).Clicked() {
					w.tab = t[0]
				}
			}
		})
		ui.Scroll(c.Key("body")).Grow(1).FillHeight().Children(func() {
			ui.Column(c.Key(w.tab)).FillWidth().MaxWidth(760).Padding(8, 36, 40).
				Transition(ui.ElementTransition{Duration: 180 * time.Millisecond, Enter: &ui.Motion{Y: 6}}).Children(func() {
				switch w.tab {
				case "general":
					a.setGeneral(c, p)
				case "appearance":
					a.setAppearance(c, p)
				case "menubar":
					a.setMenuBar(c, p)
				case "panel":
					a.setPanel(c, p)
				case "widgets":
					a.setWidgets(c, p)
				case "models":
					a.setModels(c, p)
				case "limits":
					a.setLimits(c, p)
				case "data":
					a.setData(c, p)
				}
			})
		})
	})
}

// toggleRow binds a bool setting.
func (a *ctrl) toggleRow(c *ui.Context, p palette, key, label, detail string, v *bool) {
	p.sRow(c, key, label, detail, func() {
		if p.toggle(c, "t", v).Changed() {
			a.saveSettings()
		}
	})
}

// segRow binds a string setting to a segmented control.
func (a *ctrl) segRow(c *ui.Context, p palette, key, label, detail string, v *string, opts [][2]string) {
	for i := range opts {
		opts[i][1] = L(opts[i][1])
	}
	p.sRow(c, key, label, detail, func() {
		if p.segValue(c, "s", v, opts) {
			a.saveSettings()
		}
	})
}

// intSeg binds an int setting.
func (a *ctrl) intSeg(c *ui.Context, p palette, key, label, detail string, v *int, opts []int, name func(int) string) {
	p.sRow(c, key, label, detail, func() {
		sel := slices.Index(opts, *v)
		labels := make([]string, len(opts))
		for i, o := range opts {
			labels[i] = name(o)
		}
		if n := p.segmented(c, "s", sel, labels...); n != sel && n >= 0 {
			*v = opts[n]
			a.saveSettings()
		}
	})
}

func (a *ctrl) setGeneral(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "numbers", L("Numbers"), nil, func() {
		p.sRow(c, "exact", L("Token numbers"), L("Axis ticks are always short"), func() {
			sel := pick(s.ExactNumbers, 1, 0)
			if n := p.segmented(c, "s", sel, L("Short 4.96 B"), L("Exact 4,959,084,551")); n != sel {
				s.ExactNumbers = n == 1
				a.saveSettings()
			}
		})
		a.segRow(c, p, "metric", L("Main metric"), "", &s.Metric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}, {"messages", "Messages"}})
	})
	p.sGroup(c, "window", L("Window"), nil, func() {
		a.toggleRow(c, p, "ontop", L("Keep main window on top"), "", &s.FloatingWindow)
		p.sRow(c, "login", L("Open at login"), L("macOS may ask you to approve it in System Settings → General → Login Items"), func() {
			if a.w.login == nil {
				on := a.loginGet()
				a.w.login = &on
			}
			if p.toggle(c, "t", a.w.login).Changed() {
				a.loginSet(*a.w.login)
			}
		})
		a.updateRows(c, p)
		p.sRow(c, "quit", L("Quit"), L("SimpleToken keeps running in the menu bar when the window is closed"), func() {
			if p.button(c, "q", L("Quit SimpleToken"), "", btnPlain).Clicked() {
				mygo.App.Quit()
			}
		})
	})
}

func (a *ctrl) setAppearance(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "theme", L("Theme"), nil, func() {
		a.segRow(c, p, "theme", L("Appearance"), "", &s.Theme, [][2]string{{"dark", "Dark"}, {"light", "Light"}, {"system", "System"}})
		p.sRow(c, "pal", L("Palette"), L("Shared with SimpleToggle: one signal colour marks what is live, focused or over a limit"), func() {
			for _, id := range palettes {
				sw := newPalette(true, id)
				sel := Pal(s.Palette) == id
				b := ui.Box(c.Key(string(id))).Size(30, 30).Radius(6).Background(sw.BG).Label(L(string(id))).Tooltip(palName(id))
				b.Border(pick(sel, float32(2), 1), pick(sel, p.T1, p.L3))
				b.Draw(func(pt *ui.Painter, r ui.Rect) {
					d := ui.Rect{X: r.X + r.W/2 - 4, Y: r.Y + r.H/2 - 4, W: 8, H: 8}
					pt.Shadow(d, 4, 0, 0, 6, 0, sw.glow())
					pt.Fill(d, sw.Sig, 4)
				})
				pressPose(b, 0.92)
				if b.Clicked() {
					s.Palette = string(id)
					a.saveSettings()
				}
			}
		})
		a.segRow(c, p, "material", L("Panel material"), L("Glass uses the system vibrancy behind the panel; Solid is opaque"), &s.PanelMaterial, [][2]string{{"glass", "Glass"}, {"solid", "Solid"}})
	})
	p.sGroup(c, "charts", L("Charts"), nil, func() {
		a.segRow(c, p, "series", L("Series colours"), L("Ink: a monochrome ladder ranked by the last 30 days. Vendor: Anthropic terracotta, OpenAI teal, Google indigo, xAI in black and white."), &s.SeriesColors, [][2]string{{"ink", "Ink"}, {"vendor", "Vendor"}})
		a.segRow(c, p, "marks", L("Vendor marks"), L("Brand logos beside model and tool names, and a thin vendor band on the donut, map and flow"), &s.VendorMarks, [][2]string{{"color", "Colour"}, {"mono", "Mono"}})
	})
}

func palName(id Pal) string {
	switch id {
	case PalPaper:
		return "Paper · Cursor"
	case PalGraphite:
		return "Graphite · Vercel"
	case PalSignal:
		return "Signal · Nothing"
	case PalIce:
		return "Ice"
	case PalPeach:
		return "Peach"
	}
	return "Phosphor"
}

var menuBarItems = [][2]string{
	{"claude.session", "Claude session limit"}, {"claude.weekly", "Claude weekly limit"}, {"claude.fable", "Claude Fable limit"},
	{"codex.session", "Codex 5-hour limit"}, {"codex.weekly", "Codex weekly limit"}, {"cursor.weekly", "Cursor weekly limit"},
	{"today.tokens", "Today's tokens"}, {"today.cost", "Today's cost"}, {"month.cost", "This month's cost"},
	{"claude.reset", "Session reset countdown"}, {"today.hours", "Today by hour (Claude Code)"}, {"week.days", "Last 7 days"},
}

// orderedList edits an ordered selection: numbered rows with up / down / remove, and an Add menu.
func (a *ctrl) orderedList(c *ui.Context, p palette, key string, items *[]string, all [][2]string, empty string) {
	label := func(k string) string {
		for _, x := range all {
			if x[0] == k {
				return L(x[1])
			}
		}
		return k
	}
	ui.Column(c.Key(key)).Width(340).Gap(2).Padding(10, 0).Children(func() {
		if len(*items) == 0 {
			p.mono(c, empty, 11, p.T4)
		}
		for i, k := range slices.Clone(*items) {
			ui.Row(c.Key(k)).FillWidth().Height(28).Padding(0, 4).Gap(4).AlignItems(ui.Center).Children(func() {
				ui.Text(c, pad2(i+1)).Font(monoFont).FontSize(10.5).TextColor(p.T4).Width(22).SingleLine()
				ui.Text(c, label(k)).FontSize(12).TextColor(p.T1).Grow(1).SingleLine()
				if p.iconBtn(c, "up", "chevron-up", L("Move Up"), false).Clicked() && i > 0 {
					(*items)[i-1], (*items)[i] = (*items)[i], (*items)[i-1]
					a.saveSettings()
				}
				if p.iconBtn(c, "down", "chevron-down", L("Move Down"), false).Clicked() && i < len(*items)-1 {
					(*items)[i+1], (*items)[i] = (*items)[i], (*items)[i+1]
					a.saveSettings()
				}
				if p.iconBtn(c, "rm", "minus", L("Remove"), false).Clicked() {
					*items = slices.DeleteFunc(*items, func(x string) bool { return x == k })
					a.saveSettings()
				}
			})
		}
		add := p.button(c, "add", L("Add"), "plus", btnGhost)
		add.Menu(func(m *ui.Menu) {
			n := 0
			for _, x := range all {
				if slices.Contains(*items, x[0]) {
					continue
				}
				n++
				if m.Item(L(x[1])).Chosen() {
					*items = append(*items, x[0])
					a.saveSettings()
				}
			}
			if n == 0 {
				m.Item(L("Everything is added")).Disabled(true)
			}
		})
	})
}

func (a *ctrl) setMenuBar(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "preview", L("Preview"), nil, func() {
		ui.Column(c.Key("strips")).FillWidth().Gap(8).Padding(12, 0).Children(func() {
			for _, dark := range []bool{true, false} {
				png, tmpl := renderMenuBar(a.menuBarSegs(), mbOpts{Style: mbStyle(s.MenuBarStyle), Labels: s.MenuBarShowLabels || s.MenuBarStyle == "stacked",
					Pace: s.MenuBarShowPace, Icon: s.MenuBarShowIcon, Red: s.MenuBarAlertColor, Dark: dark, Preview: true})
				a.menuBarPreview(c, pick(dark, "dark", "light"), png, tmpl, dark)
			}
		})
	})
	p.sGroup(c, "items", L("Items"), nil, func() {
		a.orderedList(c, p, "list", &s.MenuBarItems, menuBarItems, L("Icon only"))
	})
	p.sGroup(c, "style", L("Style"), nil, func() {
		ui.Grid(c.Key("gallery")).FillWidth().Columns(3).Gap(8).Padding(12, 0).Children(func() {
			for _, st := range [][2]string{{"text", "Single line"}, {"stacked", "Two lines"}, {"dense", "Compact"}, {"ring", "Ring"}, {"rings", "Nested rings"}, {"bar", "Bar"}} {
				sel := s.MenuBarStyle == st[0]
				card := ui.Column(c.Key(st[0])).Padding(10).Gap(8).Radius(6).Label(L(st[1]))
				card.Border(1, pick(sel, p.sigLine(), p.L2)).Background(pick(sel, p.sigSoft(), ui.Transparent))
				pressPose(card, 0.98)
				card.Children(func() {
					png, _ := renderMenuBar(a.menuBarSegs(), mbOpts{Style: mbStyle(st[0]), Labels: s.MenuBarShowLabels || st[0] == "stacked", Pace: s.MenuBarShowPace, Icon: s.MenuBarShowIcon, Red: false, Dark: true, Preview: true})
					a.menuBarPreview(c, "img", png, true, true)
					p.mono(c, L(st[1]), 11, p.T1)
				})
				if card.Clicked() {
					s.MenuBarStyle = st[0]
					a.saveSettings()
				}
			}
		})
	})
	p.sGroup(c, "details", L("Details"), nil, func() {
		a.toggleRow(c, p, "labels", L("Show labels"), pick(s.MenuBarStyle == "stacked", L("Two lines always shows labels"), ""), &s.MenuBarShowLabels)
		a.toggleRow(c, p, "pace", L("Pace and projection"), L("Ring, nested rings and bar: a pace tick and how far the current pace will go"), &s.MenuBarShowPace)
		a.toggleRow(c, p, "icon", L("Show SimpleToken icon"), "", &s.MenuBarShowIcon)
		p.sRow(c, "used", L("Limit numbers"), "", func() {
			sel := pick(s.LimitShowUsed, 0, 1)
			if n := p.segmented(c, "s", sel, L("Used"), L("Left")); n != sel {
				s.LimitShowUsed = n == 0
				a.saveSettings()
			}
		})
		a.toggleRow(c, p, "red", L("Turn red near the limit"), L("The item stays a template image until a value passes the top alert threshold"), &s.MenuBarAlertColor)
		p.sRow(c, "click", L("Clicking the icon opens"), L("Right-click shows Open, Settings, Refresh and Quit"), func() {
			sel := pick(s.ClickOpensPanel, 0, 1)
			if n := p.segmented(c, "s", sel, L("Panel"), L("Main window")); n != sel {
				s.ClickOpensPanel = n == 0
				a.saveSettings()
			}
		})
	})
}

// menuBarPreview shows a rendered item on a strip of the bar's colour (a template image is tinted like macOS does).
func (a *ctrl) menuBarPreview(c *ui.Context, key string, png []byte, tmpl, dark bool) {
	bmp, err := a.w.bitmap(png)
	ink := pick(dark, ui.Hex("#ffffff"), ui.Hex("#111111"))
	ui.Row(c.Key(key)).FillWidth().Height(30).Radius(5).Background(pick(dark, ui.Hex("#1c1c1e"), ui.Hex("#ececec"))).Justify(ui.Center).AlignItems(ui.Center).Children(func() {
		if err != nil || bmp == nil {
			return
		}
		w, h := bmp.Size()
		dw := float32(w) / 2
		ui.Box(c).Size(dw, float32(h)/2).Draw(func(pt *ui.Painter, r ui.Rect) {
			o := ui.ImageOptions{}
			if tmpl {
				o.Tint = ink
			}
			pt.ImageRegion(bmp, ui.Rect{W: float32(w), H: float32(h)}, r, o)
		})
	})
}

func (a *ctrl) setPanel(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "sections", L("Sections"), nil, func() {
		a.orderedList(c, p, "list", &s.PanelSections, panelSections, L("Only the header row is shown"))
	})
	p.sGroup(c, "layout", L("Layout"), nil, func() {
		a.intSeg(c, p, "width", L("Panel width"), "", &s.PanelWidth, []int{320, 360, 400}, func(v int) string {
			return map[int]string{320: L("Compact"), 360: L("Standard"), 400: L("Wide")}[v]
		})
		a.segRow(c, p, "lstyle", L("Limit style"), L("Meters are denser; dot gauges echo the app icon"), &s.PanelLimitStyle, [][2]string{{"meters", "Meters"}, {"gauges", "Dot gauges"}})
		a.toggleRow(c, p, "resets", L("Show reset times"), "", &s.PanelShowResets)
		a.segRow(c, p, "trend", L("Today's trend"), "", &s.PanelTodayStyle, [][2]string{{"cumulative", "Cumulative line"}, {"bars", "Hourly bars"}})
		a.intSeg(c, p, "rows", L("Models / tools shown"), "", &s.PanelListCount, []int{3, 4, 6}, itoa)
	})
}

func (a *ctrl) setWidgets(c *ui.Context, p palette) {
	s := &a.m.s
	right := func() {
		if p.button(c, "rl", L("Reset Layout Only"), "", btnGhost).Clicked() {
			d := settings.Default()
			s.CardOrder, s.HiddenCards, s.CardSizes = d.CardOrder, d.HiddenCards, d.CardSizes
			a.saveSettings()
		}
		if p.button(c, "ra", L("Reset All Widget Settings"), "", btnGhost).Clicked() {
			d := settings.Default()
			s.CardOrder, s.HiddenCards, s.CardSizes, s.CardAccents = d.CardOrder, d.HiddenCards, d.CardSizes, d.CardAccents
			s.HeroShowPrevious, s.UsageStack, s.UsageShowAverage, s.PunchcardDays = d.HeroShowPrevious, d.UsageStack, d.UsageShowAverage, d.PunchcardDays
			s.CalendarMetric, s.CalendarWeeks, s.CompositionPeriod, s.CompositionShowHitRate = d.CalendarMetric, d.CalendarWeeks, d.CompositionPeriod, d.CompositionShowHitRate
			s.CostShowLastMonth, s.CostShowProjection, s.CostShowDailyBars, s.ModelsShowSparklines, s.ModelsMetric = d.CostShowLastMonth, d.CostShowProjection, d.CostShowDailyBars, d.ModelsShowSparklines, d.ModelsMetric
			a.saveSettings()
		}
	}
	p.sGroup(c, "widgets", L("Widgets"), right, func() {
		for i, id := range slices.Clone(s.CardOrder) {
			def := cardDefs[id]
			ui.Row(c.Key(id)).FillWidth().Padding(6, 0).Gap(10).AlignItems(ui.Center).Children(func() {
				ui.Text(c, pad2(i+1)).Font(monoFont).FontSize(10.5).TextColor(p.T4).Width(22).SingleLine()
				on := !slices.Contains(s.HiddenCards, id)
				ui.Text(c, L(def.Title)).FontSize(12.5).TextColor(pick(on, p.T1, p.T3)).Grow(1).SingleLine()
				if len(def.Sizes) > 1 {
					cur := a.cardSize(id)
					opts := make([]string, len(def.Sizes))
					sel := 0
					for k, sz := range def.Sizes {
						opts[k] = string(sz)
						if sz == cur {
							sel = k
						}
					}
					if n := p.segmented(c, "size", sel, opts...); n != sel {
						a.setCardSize(id, def.Sizes[n])
					}
				}
				if p.iconBtn(c, "up", "chevron-up", L("Move Earlier"), false).Clicked() {
					a.shiftCard(id, -1)
				}
				if p.iconBtn(c, "down", "chevron-down", L("Move Later"), false).Clicked() {
					a.shiftCard(id, 1)
				}
				v := on
				if p.toggle(c, "on", &v).Changed() {
					if v {
						s.HiddenCards = slices.DeleteFunc(s.HiddenCards, func(x string) bool { return x == id })
					} else {
						s.HiddenCards = append(s.HiddenCards, id)
					}
					a.saveSettings()
				}
			})
		}
	})
}

func (a *ctrl) setModels(c *ui.Context, p palette) {
	m := a.m
	s := &m.s
	rep := m.report("ALL", "tokens")
	p.sGroup(c, "models", L("Models"), nil, func() {
		a.segRow(c, p, "scheme", L("Color scheme"), L("Ranked by the last 30 days, never the selected range"), &s.SeriesColors, [][2]string{{"ink", "Ink"}, {"vendor", "By vendor"}})
		p.sRow(c, "sep", L("Models shown separately"), L("The rest are grouped as Other"), func() {
			if p.iconBtn(c, "minus", "minus", L("Fewer"), false).Clicked() && s.SeparateModels > 2 {
				s.SeparateModels--
				a.saveSettings()
			}
			ui.Text(c, itoa(s.SeparateModels)).Font(monoFont).FontSize(13).TextColor(p.T1).Width(18).TextAlign(ui.Center)
			if p.iconBtn(c, "plus", "plus", L("More"), false).Clicked() && s.SeparateModels < 8 {
				s.SeparateModels++
				a.saveSettings()
			}
		})
		models := make([]string, 0, len(rep.Models))
		for _, sh := range rep.Models {
			models = append(models, sh.Key)
		}
		for _, x := range s.ExcludedModels {
			if !slices.Contains(models, x) {
				models = append(models, x)
			}
		}
		for _, id := range models {
			var tokens int64
			last := ""
			for _, sh := range rep.Models {
				if sh.Key == id {
					tokens = sh.Tokens
				}
			}
			for i := len(rep.Days) - 1; i >= 0 && last == ""; i-- {
				if rep.Days[i].ByModel[id] > 0 {
					last = format.ShortDate(rep.Days[i].Date)
				}
			}
			v := vendorOf(id)
			inc := !slices.Contains(s.ExcludedModels, id)
			ui.Row(c.Key(id)).FillWidth().Padding(8, 0).Gap(10).AlignItems(ui.Center).Children(func() {
				a.colorWell(c, p, s.ModelColorOverrides, id, m.modelColor(p, id))
				logo(c, vendorLogo(v), 16, m.vendorTint(p, v))
				ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
					ui.Text(c, id).Font(monoFont).FontSize(12).TextColor(pick(inc, p.T1, p.T3)).SingleLine().Ellipsis("…")
					p.mono(c, vendorName(v)+" · "+shortNum(float64(tokens))+" · "+L("last used %@", last), 10, p.T4)
				})
				alias := s.ModelAliases[id]
				if ui.TextInput(c.Key("alias"), &alias).Placeholder(L("Alias")).Width(150).Changed() {
					if strings.TrimSpace(alias) == "" {
						delete(s.ModelAliases, id)
					} else {
						s.ModelAliases[id] = alias
					}
					a.saveSettings()
				}
				if p.toggle(c, "inc", &inc).Changed() {
					a.setExcluded(&s.ExcludedModels, id, !inc)
				}
			})
		}
		ui.Row(c.Key("actions")).Gap(6).Padding(10, 0).Children(func() {
			if p.button(c, "rc", L("Reset Colors"), "", btnGhost).Clicked() {
				s.ModelColorOverrides, s.ToolColorOverrides = map[string]string{}, map[string]string{}
				a.saveSettings()
			}
			if p.button(c, "ra", L("Clear All Aliases"), "", btnGhost).Clicked() {
				s.ModelAliases = map[string]string{}
				a.saveSettings()
			}
		})
	})
	p.sGroup(c, "tools", L("Tools"), nil, func() {
		for _, sh := range rep.Clients {
			id := sh.Key
			inc := !slices.Contains(s.ExcludedClients, id)
			ui.Row(c.Key(id)).FillWidth().Padding(8, 0).Gap(10).AlignItems(ui.Center).Children(func() {
				a.colorWell(c, p, s.ToolColorOverrides, id, m.toolColor(p, id))
				logo(c, vendorLogo(id), 16, m.vendorTint(p, id))
				ui.Column(c).Grow(1).Gap(2).Children(func() {
					ui.Text(c, toolName(id)).FontSize(12.5).TextColor(pick(inc, p.T1, p.T3)).SingleLine()
					p.mono(c, L("%@ all time", shortNum(float64(sh.Tokens))), 10, p.T4)
				})
				if p.toggle(c, "inc", &inc).Changed() {
					a.setExcluded(&s.ExcludedClients, id, !inc)
				}
			})
		}
	})
}

func (a *ctrl) setExcluded(list *[]string, id string, excluded bool) {
	*list = slices.DeleteFunc(*list, func(x string) bool { return x == id })
	if excluded {
		*list = append(*list, id)
	}
	a.saveSettings()
}

func (a *ctrl) setLimits(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "limits", L("Limits"), nil, func() {
		p.sRow(c, "used", L("Numbers show"), "", func() {
			sel := pick(s.LimitShowUsed, 0, 1)
			if n := p.segmented(c, "s", sel, L("Used"), L("Left")); n != sel {
				s.LimitShowUsed = n == 0
				a.saveSettings()
			}
		})
		for _, prov := range limits.Providers {
			e := a.lim.Get(prov)
			detail := a.statusText(e)
			if e.Snapshot != nil && e.Snapshot.AccountLabel != "" {
				detail = e.Snapshot.AccountLabel + " · " + detail
			}
			show := !slices.Contains(s.HiddenLimitProviders, string(prov))
			p.sRow(c, string(prov), L("Show %@", prov.DisplayName()), detail, func() {
				if p.toggle(c, "t", &show).Changed() {
					a.setExcluded(&s.HiddenLimitProviders, string(prov), !show)
				}
			})
		}
		a.claudeKeyRow(c, p)
		a.toggleRow(c, p, "buckets", L("Per-model extra limits"), L("Fable, Codex model buckets, Cursor on-demand"), &s.LimitShowModelBuckets)
		a.toggleRow(c, p, "pace", L("Even-pace line"), L("Hollow cells and dots show where the current pace ends"), &s.LimitShowPace)
		p.sRow(c, "refresh", L("Refresh"), "", func() {
			if p.button(c, "r", L("Refresh Now"), "rotate-cw", btnPlain).Clicked() {
				a.lim.RefreshNow()
			}
		})
	})
	p.sGroup(c, "alerts", L("Alerts"), nil, func() {
		p.sRow(c, "thr", L("Thresholds"), L("One notification per window period per threshold"), func() {
			for _, t := range []float64{50, 60, 70, 80, 90, 95} {
				on := slices.Contains(s.AlertThresholds, t)
				if p.chip(c, itoa(int(t)), itoa(int(t))+"%", on).Clicked() {
					if on {
						s.AlertThresholds = slices.DeleteFunc(s.AlertThresholds, func(x float64) bool { return x == t })
					} else {
						s.AlertThresholds = append(s.AlertThresholds, t)
						slices.Sort(s.AlertThresholds)
					}
					a.saveSettings()
				}
			}
		})
		a.toggleRow(c, p, "notif", L("System notifications"), "", &s.LimitNotifications)
	})
}

// claudeKeyRow stores the owner-pasted Claude sessionKey (needed for the Fable and per-model windows). The key is
// never shown again; only whether one is saved.
func (a *ctrl) claudeKeyRow(c *ui.Context, p palette) {
	has := a.creds.ClaudeCookie() != ""
	p.sRow(c, "key", L("Claude session key"), pick(has, L("Saved. Paste a new one to replace it."), L("Paste sessionKey (sk-ant-…) from claude.ai")), func() {
		ui.TextInput(c.Key("in"), &a.w.keyDraft).Password().Placeholder("sk-ant-…").Width(220)
		if p.button(c, "save", pick(has, L("Replace"), L("Save")), "", btnPlain).Clicked() && a.w.keyDraft != "" {
			if _, err := limits.NormalizeSessionKey(a.w.keyDraft); err == nil {
				_ = a.creds.SetClaudeCookie(a.w.keyDraft)
				a.lim.RefreshNow()
			}
			a.w.keyDraft = ""
		}
		if has && p.button(c, "clear", L("Clear"), "", btnGhost).Clicked() {
			_ = a.creds.SetClaudeCookie("")
			a.lim.RefreshNow()
		}
	})
}

func (a *ctrl) setData(c *ui.Context, p palette) {
	s := &a.m.s
	p.sGroup(c, "refresh", L("Refresh"), nil, func() {
		a.intSeg(c, p, "live", L("Today's usage refresh"), L("Throttled; paused when no window, panel or menu bar number needs it"), &s.LiveRefreshSeconds, []int{15, 30, 60, 120}, fmtr.Seconds)
		a.intSeg(c, p, "full", L("Full rescan"), "", &s.FullRefreshMinutes, []int{10, 15, 30}, func(v int) string { return L("%lld min", v) })
		p.sRow(c, "all", L("Refresh All Now"), "", func() {
			if p.button(c, "r", L("Refresh All Now"), "rotate-cw", btnPlain).Clicked() {
				a.refreshAll()
			}
		})
	})
	p.sGroup(c, "storage", L("Storage"), nil, func() {
		h := a.m.d.History
		since := "—"
		if len(h) > 0 {
			since = format.LongDate(h[0].Date)
		}
		p.sRow(c, "hist", L("History"), L("Daily totals per tool and model"), func() { p.mono(c, L("%lld days", len(h))+" · "+since, 12, p.T1) })
		p.sRow(c, "intra", L("Intraday data"), L("Half-hour Claude Code totals, kept 90 days"), func() { p.mono(c, L("%lld days", len(a.m.d.Intra.Days())), 12, p.T1) })
		p.sRow(c, "dir", L("Data folder"), "~/Library/Application Support/SimpleToken", func() {
			if p.button(c, "show", L("Show in Finder"), "folder-open", btnPlain).Clicked() {
				_ = mygo.Shell.OpenPath(paths.Dir())
			}
		})
	})
}

// cardBack is a card's settings: size, its own options, its colour.
func (a *ctrl) cardBack(c *ui.Context, p palette, pl placed) {
	m := a.m
	s := &m.s
	def := cardDefs[pl.id]
	ui.Scroll(c.Key("opts")).Grow(1).FillWidth().Children(func() {
		ui.Column(c).FillWidth().Children(func() {
			if len(def.Sizes) > 1 {
				p.sRow(c, "size", L("Size"), "", func() {
					sel := slices.Index(def.Sizes, pl.size)
					labels := make([]string, len(def.Sizes))
					for i, sz := range def.Sizes {
						labels[i] = map[cardSize]string{sizeS: L("Small"), sizeM: L("Medium"), sizeL: L("Large"), sizeW: L("Wide")}[sz]
					}
					if n := p.segmented(c, "s", sel, labels...); n != sel && n >= 0 {
						a.setCardSize(pl.id, def.Sizes[n])
					}
				})
			}
			series := func() {
				a.segRow(c, p, "series", L("Series colours"), L("Applies to every chart"), &s.SeriesColors, [][2]string{{"ink", "Ink"}, {"vendor", "Vendor"}})
			}
			switch pl.id {
			case "hero":
				a.segRow(c, p, "metric", L("Metric"), L("Shared with the main metric in General"), &s.Metric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}, {"messages", "Messages"}})
				a.toggleRow(c, p, "prev", L("Previous period line"), "", &s.HeroShowPrevious)
			case "limits":
				p.sRow(c, "used", L("Numbers show"), "", func() {
					sel := pick(s.LimitShowUsed, 0, 1)
					if n := p.segmented(c, "s", sel, L("Used"), L("Left")); n != sel {
						s.LimitShowUsed = n == 0
						a.saveSettings()
					}
				})
				p.sRow(c, "providers", L("Providers"), "", func() {
					for _, prov := range limits.Providers {
						on := !slices.Contains(s.HiddenLimitProviders, string(prov))
						if p.chip(c, string(prov), prov.DisplayName(), on).Clicked() {
							a.setExcluded(&s.HiddenLimitProviders, string(prov), on)
						}
					}
				})
				a.toggleRow(c, p, "buckets", L("Per-model extra limits"), "", &s.LimitShowModelBuckets)
				a.toggleRow(c, p, "pace", L("Even-pace line"), "", &s.LimitShowPace)
				p.sRow(c, "refresh", L("Refresh Now"), "", func() {
					if p.button(c, "r", L("Refresh Now"), "rotate-cw", btnPlain).Clicked() {
						a.lim.RefreshNow()
					}
				})
			case "models":
				a.segRow(c, p, "share", L("Share by"), "", &s.ModelsMetric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}})
				a.toggleRow(c, p, "spark", L("Sparklines"), "", &s.ModelsShowSparklines)
				series()
			case "usage":
				a.segRow(c, p, "stack", L("Stacking"), "", &s.UsageStack, [][2]string{{"model", "By model"}, {"tool", "By tool"}, {"none", "Unstacked"}})
				a.intSeg(c, p, "interval", L("1D interval"), L("Today and single days, from Claude Code's logs"), &s.IntradayMinutes, []int{60, 30}, func(v int) string {
					return pick(v == 60, L("Hourly"), L("Every 30 min"))
				})
				a.toggleRow(c, p, "avg", L("Average line"), "", &s.UsageShowAverage)
				series()
			case "calendar":
				a.segRow(c, p, "metric", L("Shade by"), "", &s.CalendarMetric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}, {"messages", "Messages"}})
				a.intSeg(c, p, "weeks", L("Show up to"), "", &s.CalendarWeeks, []int{0, 13, 26, 53}, func(v int) string {
					return map[int]string{0: L("Fill"), 13: L("13 wk"), 26: L("26 wk"), 53: L("1 year")}[v]
				})
			case "punchcard":
				a.intSeg(c, p, "days", L("Range"), "", &s.PunchcardDays, []int{7, 30, 90}, func(v int) string { return L("%lld days", v) })
			case "composition":
				a.segRow(c, p, "period", L("Period"), "", &s.CompositionPeriod, [][2]string{{"auto", "Match range"}, {"today", "Today"}, {"month", "This month"}, {"allTime", "All time"}})
				a.toggleRow(c, p, "hit", L("Hit rate in center"), "", &s.CompositionShowHitRate)
				series()
			case "cost":
				a.toggleRow(c, p, "proj", L("Month-end projection"), "", &s.CostShowProjection)
				a.toggleRow(c, p, "last", L("Last month's total line"), "", &s.CostShowLastMonth)
				a.toggleRow(c, p, "bars", L("Daily cost bars"), "", &s.CostShowDailyBars)
			case "tools":
				series()
				for _, sh := range m.report("ALL", "tokens").Clients {
					id := sh.Key
					inc := !slices.Contains(s.ExcludedClients, id)
					ui.Row(c.Key("tool-"+id)).FillWidth().Padding(6, 0).Gap(10).AlignItems(ui.Center).Children(func() {
						a.colorWell(c, p, s.ToolColorOverrides, id, m.toolColor(p, id))
						logo(c, vendorLogo(id), 14, m.vendorTint(p, id))
						ui.Text(c, toolName(id)).FontSize(12).TextColor(pick(inc, p.T1, p.T3)).Grow(1).SingleLine()
						if p.toggle(c, "inc", &inc).Changed() {
							a.setExcluded(&s.ExcludedClients, id, !inc)
						}
					})
				}
			case "map", "flow":
				series()
			}
			if pl.id == "hero" || pl.id == "usage" || pl.id == "cost" || pl.id == "calendar" || pl.id == "punchcard" || def.Stat {
				p.sRow(c, "accent", L("Color"), "", func() {
					cur := s.CardAccents[pl.id]
					if cur == "" {
						cur = "ink"
					}
					for _, o := range accentOptions {
						save := s.CardAccents[pl.id]
						s.CardAccents[pl.id] = o[0]
						col := a.accent(p, pl.id)
						s.CardAccents[pl.id] = save
						if save == "" {
							delete(s.CardAccents, pl.id)
						}
						b := ui.Box(c.Key(o[0])).Size(18, 18).Radius(9).Background(col).Label(L(o[1])).Tooltip(L(o[1]))
						if cur == o[0] {
							b.Border(2, p.T1)
						} else {
							b.Border(1, p.L3)
						}
						if b.Clicked() {
							s.CardAccents[pl.id] = o[0]
							a.saveSettings()
						}
					}
				})
			}
		})
	})
}

// colorWell edits a model's or tool's colour override; a reset button appears once one is set.
func (a *ctrl) colorWell(c *ui.Context, p palette, overrides map[string]string, id string, cur ui.Color) {
	ui.Row(c.Key("color")).Gap(2).AlignItems(ui.Center).Shrink(0).Children(func() {
		col := cur
		if ui.ColorWell(c.Key("well"), &col).Label(L("Color")).Size(22, 22).Changed() {
			overrides[id] = hexColor(col)
			a.saveSettings()
		}
		if overrides[id] != "" {
			if p.iconBtn(c, "reset", "rotate-ccw", L("Restore default color"), false).Clicked() {
				delete(overrides, id)
				a.saveSettings()
			}
		}
	})
}

func hexColor(c ui.Color) string {
	const digits = "0123456789abcdef"
	b := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i, v := range []uint8{c.R, c.G, c.B} {
		b[1+2*i], b[2+2*i] = digits[v>>4], digits[v&15]
	}
	return string(b)
}

// updateRows are the update settings: automatic install, check now, restart once a version is installed.
func (a *ctrl) updateRows(c *ui.Context, p palette) {
	s := &a.m.s
	enabled := mygo.Updater.Enabled()
	detail := L("Version %@", mygo.App.Version())
	if !enabled {
		detail += " · " + L("This build does not update itself")
	}
	a.toggleRow(c, p, "auto", L("Download and install updates"), detail, &s.AutoUpdate)
	if !enabled {
		return
	}
	busy, ready, checked, errText := a.upd.state()
	status := L("Not checked yet")
	switch {
	case busy:
		status = L("Checking…")
	case ready != "":
		status = L("Version %@ is installed and runs at the next launch", ready)
	case errText != "":
		status = errText
	case !checked.IsZero():
		status = L("Up to date") + " · " + fmtr.Ago(checked, a.m.now())
	}
	p.sRow(c, "check", L("Updates"), status, func() {
		if ready != "" {
			if p.button(c, "restart", L("Restart Now"), "rotate-cw", btnPrimary).Clicked() {
				mygo.App.Relaunch()
			}
			return
		}
		if p.button(c, "now", L("Check Now"), "", btnPlain).Clicked() && !busy {
			go a.installUpdate()
		}
	})
}
