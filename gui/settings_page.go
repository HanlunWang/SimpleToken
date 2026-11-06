package gui

import (
	"math"
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

// Settings live in the main window (designs/simpletoken-v3 Settings boards): a sidebar of sections, then groups
// of rows in two columns, each with its heading above it.

var settingsTabs = [][2]string{
	{"general", "General"}, {"menubar", "Menu bar & panel"}, {"dashboard", "Dashboard"}, {"limits", "Limits"},
	{"data", "Data sources"}, {"appearance", "Appearance"}, {"updates", "Updates"},
}

// navItem is a sidebar row: mono label, › and the signal colour when selected, no fill; trail on the right.
func (p palette) navItem(c *ui.Context, key, label string, selected bool, trail func()) ui.Element {
	r := ui.Row(c.Key(key)).FillWidth().Height(28).Padding(0, 8, 0, 14).Radius(p.rCtl()).Gap(9).AlignItems(ui.Center).Label(label)
	r.Background(r.AnimateColor("hover", pick(r.Hovered() && !selected, p.L1, ui.Transparent), animHover))
	col := pick(selected, p.Sig, pick(r.Hovered(), p.T1, p.T2))
	col = r.AnimateColor("fg", col, animColor)
	r.Children(func() {
		if selected {
			ui.Text(c.Key("sel"), "›").Font(monoFont).FontSize(13).FontWeight(600).TextColor(p.Sig).Absolute().Left(2).Top(5).PassThrough()
		}
		ui.Text(c, label).Font(monoFont).FontSize(12.5).FontWeight(pick(selected, 500, 400)).TextColor(col).SingleLine().Grow(1)
		if trail != nil {
			trail()
		}
	})
	return r
}

// sHead is a group's heading: a title and a quiet description beside it.
func (p palette) sHead(c *ui.Context, title, desc string) {
	ui.Row(c.Key("h" + title)).FillWidth().Gap(10).AlignItems(ui.Baseline).Shrink(0).Children(func() {
		ui.Text(c, title).FontSize(15).FontWeight(600).TextColor(p.T1).SingleLine()
		if desc != "" {
			ui.Text(c, desc).FontSize(11).TextColor(p.T3).SingleLine().MinWidth(0).Ellipsis("…")
		}
	})
}

// sGroup is a group of rows on the card ground (theme.css .sgroup); rows draw a hairline above all but the first.
func (a *ctrl) sGroup(c *ui.Context, p palette, key string, body func()) {
	ui.Column(c.Key(key)).FillWidth().Padding(4, 16).Radius(8).Border(1, p.L2).Background(p.Surf).Shrink(0).Children(func() {
		a.w.firstRow = true
		body()
	})
}

// sRow is one setting (theme.css .srow): label and detail on the left, the control on the right.
func (a *ctrl) sRow(c *ui.Context, p palette, key, label, detail string, control func()) {
	first := a.w.firstRow
	a.w.firstRow = false
	ui.Row(c.Key(key)).FillWidth().MinHeight(48).Padding(8, 0).Gap(16).AlignItems(ui.Center).Children(func() {
		if !first {
			ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
		}
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(3).Children(func() {
			ui.Text(c, label).FontSize(13).FontWeight(500).TextColor(p.T1).Wrap()
			if detail != "" {
				ui.Text(c, detail).FontSize(11).TextColor(p.T3).LineHeight(1.4).Wrap()
			}
		})
		ui.Row(c).Gap(8).AlignItems(ui.Center).Shrink(0).Children(control)
	})
}

func (a *ctrl) settingsPage(c *ui.Context, p palette) {
	w := a.w
	if !slices.ContainsFunc(settingsTabs, func(t [2]string) bool { return t[0] == w.tab }) {
		w.tab = settingsTabs[0][0]
	}
	ui.Row(c.Key("sp")).Fill().Children(func() {
		ui.Column(c.Key("nav")).Width(236).FillHeight().Background(p.BG2).Padding(14, 8, 8).Gap(1).Shrink(0).Children(func() {
			ui.Box(c).Absolute().Right(0).Top(0).Width(1).FillHeight().Background(p.L2)
			for _, t := range settingsTabs {
				var trail func()
				switch t[0] {
				case "limits":
					trail = func() { p.mono(c, itoa(a.limitWindowCount()), 11, p.T4) }
				case "data":
					trail = func() { p.mono(c, itoa(len(a.m.report("1M", "tokens").Clients)), 11, p.T4) }
				case "updates":
					if _, ready, _, _ := a.upd.state(); ready != "" {
						trail = func() { p.badge(c, L("NEW"), "sig").Height(16) }
					}
				}
				if p.navItem(c, t[0], L(t[1]), w.tab == t[0], trail).Clicked() {
					w.tab = t[0]
				}
			}
			ui.Box(c).Grow(1)
			if a.running {
				p.mono(c, "v"+mygo.App.Version(), 10.5, p.T4).Padding(8, 14)
			}
		})
		ui.Scroll(c.Key("body")).Grow(1).FillHeight().Children(func() {
			ui.Column(c.Key(w.tab)).FillWidth().Padding(22, 28, 40).
				Transition(ui.ElementTransition{Duration: 180 * time.Millisecond, Enter: &ui.Motion{Y: 6}}).Children(func() {
				switch w.tab {
				case "general":
					a.setGeneral(c, p)
				case "menubar":
					a.setMenuBar(c, p)
				case "dashboard":
					a.setDashboard(c, p)
				case "limits":
					a.setLimits(c, p)
				case "data":
					a.setData(c, p)
				case "appearance":
					a.setAppearance(c, p)
				case "updates":
					a.setUpdates(c, p)
				}
			})
		})
	})
}

// columns lays groups out in two columns, one below the other when the window is narrow.
func (a *ctrl) columns(c *ui.Context, left, right func()) {
	if a.w.winW > 0 && a.w.winW < 980 {
		ui.Column(c.Key("cols")).FillWidth().Gap(24).Children(func() {
			ui.Column(c.Key("l")).FillWidth().Gap(12).Children(left)
			ui.Column(c.Key("r")).FillWidth().Gap(12).Children(right)
		})
		return
	}
	ui.Row(c.Key("cols")).FillWidth().Gap(24).AlignItems(ui.Start).Children(func() {
		ui.Column(c.Key("l")).Grow(1).Basis(0).MinWidth(0).Gap(12).Children(left)
		ui.Column(c.Key("r")).Grow(1).Basis(0).MinWidth(0).Gap(12).Children(right)
	})
}

func (a *ctrl) limitWindowCount() int {
	n := 0
	for _, e := range a.m.d.Limits {
		if e.Snapshot != nil && !slices.Contains(a.m.s.HiddenLimitProviders, string(e.Provider)) {
			n += len(e.Snapshot.Windows)
		}
	}
	return n
}

// toggleRow binds a bool setting.
func (a *ctrl) toggleRow(c *ui.Context, p palette, key, label, detail string, v *bool) {
	a.sRow(c, p, key, label, detail, func() {
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
	a.sRow(c, p, key, label, detail, func() {
		if p.segValue(c, "s", v, opts) {
			a.saveSettings()
		}
	})
}

// intSeg binds an int setting.
func (a *ctrl) intSeg(c *ui.Context, p palette, key, label, detail string, v *int, opts []int, name func(int) string) {
	a.sRow(c, p, key, label, detail, func() {
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

// ── General ──

func (a *ctrl) setGeneral(c *ui.Context, p palette) {
	s := &a.m.s
	a.columns(c, func() {
		p.sHead(c, L("Numbers"), L("Axis ticks stay short either way"))
		a.sGroup(c, p, "numbers", func() {
			a.sRow(c, p, "exact", L("Token numbers"), "", func() {
				p.mono(c, pick(s.ExactNumbers, format.Grouped(1094118320), "1.09B"), 11, p.T3)
				sel := pick(s.ExactNumbers, 1, 0)
				if n := p.segmented(c, "s", sel, L("Short"), L("Exact")); n != sel {
					s.ExactNumbers = n == 1
					a.saveSettings()
				}
			})
			a.segRow(c, p, "metric", L("Dashboard metric"), L("Also in the top bar"), &s.Metric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}})
		})
	}, func() {
		p.sHead(c, L("Window"), "")
		a.sGroup(c, p, "window", func() {
			a.toggleRow(c, p, "ontop", L("Keep the window on top"), "", &s.FloatingWindow)
			a.toggleRow(c, p, "dock", L("Show in the Dock"), L("While the window is open; off keeps SimpleToken in the menu bar only"), &s.ShowInDock)
			a.sRow(c, p, "login", L("Launch at login"), L("macOS may ask you to approve it in System Settings → General → Login Items"), func() {
				if a.w.login == nil {
					on := a.loginGet()
					a.w.login = &on
				}
				if p.toggle(c, "t", a.w.login).Changed() {
					a.loginSet(*a.w.login)
				}
			})
			a.sRow(c, p, "click", L("Clicking the menu bar item opens"), L("⌥-click opens the other one"), func() {
				sel := pick(s.ClickOpensPanel, 0, 1)
				if n := p.segmented(c, "s", sel, L("Panel"), L("Window")); n != sel {
					s.ClickOpensPanel = n == 0
					a.saveSettings()
				}
			})
			a.sRow(c, p, "quit", L("Quit"), L("SimpleToken stays in the menu bar when the window is closed"), func() {
				if p.button(c, "q", L("Quit SimpleToken"), "", btnPlain).Clicked() && a.running {
					mygo.App.Quit()
				}
			})
		})
	})
}

// ── Menu bar & panel ──

var menuBarItems = [][2]string{
	{"claude.session", "Claude session"}, {"claude.weekly", "Claude weekly"}, {"claude.fable", "Claude Fable"},
	{"codex.session", "Codex 5-hour"}, {"codex.weekly", "Codex weekly"}, {"cursor.weekly", "Cursor weekly"},
	{"today.tokens", "Today's tokens"}, {"today.cost", "Today's cost"}, {"month.cost", "This month's cost"},
	{"claude.reset", "Session reset"}, {"today.hours", "Today by hour"}, {"week.days", "Last 7 days"},
}

// itemColor is a menu bar item's or panel section's mark colour in the lists.
func (a *ctrl) itemColor(p palette, id string) ui.Color {
	prov, _, _ := cutDot(id)
	switch prov {
	case "claude", "codex", "cursor":
		if id != "claude.reset" {
			return a.m.vendorTint(p, prov)
		}
	case "today", "week":
		return a.accent(p, "stat.average")
	case "month":
		return a.accent(p, "cost")
	}
	return p.Ink[2]
}

// orderList edits an ordered, switchable selection: every option is a row with a grip (drag to reorder) and a
// switch; the switched-on rows come first, in their order. limit caps how many can be on (0: no cap).
func (a *ctrl) orderList(c *ui.Context, p palette, key string, items *[]string, all [][2]string, limit int, mark func(id string)) {
	rows := slices.Clone(*items)
	for _, x := range all {
		if !slices.Contains(rows, x[0]) {
			rows = append(rows, x[0])
		}
	}
	label := func(id string) string {
		for _, x := range all {
			if x[0] == id {
				return L(x[1])
			}
		}
		return id
	}
	ui.Column(c.Key(key)).Width(260).Children(func() {
		for i, id := range rows {
			on := slices.Contains(*items, id)
			r := ui.Row(c.Key(id)).FillWidth().Height(34).Gap(10).AlignItems(ui.Center)
			if on {
				r.Drag("o:" + id)
			}
			if got, ok := ui.Drop[string](r); ok && on && strings.HasPrefix(got, "o:") {
				from := strings.TrimPrefix(got, "o:")
				if from != id {
					list := slices.DeleteFunc(slices.Clone(*items), func(x string) bool { return x == from })
					list = slices.Insert(list, slices.Index(list, id), from)
					*items = list
					a.saveSettings()
				}
			}
			if _, over := ui.DragOver[string](r); over && on {
				r.Background(p.L1)
			}
			r.Children(func() {
				if i > 0 {
					ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
				}
				ui.Box(c).Opacity(pick(on, float32(1), 0.4)).Children(func() { grip(c, p) })
				mark(id)
				ui.Text(c, label(id)).FontSize(12).TextColor(pick(on, p.T1, p.T2)).Grow(1).SingleLine().Ellipsis("…")
				v := on
				if p.toggleCompact(c, "t", &v).Changed() {
					switch {
					case v && (limit == 0 || len(*items) < limit):
						*items = append(*items, id)
					case !v:
						*items = slices.DeleteFunc(*items, func(x string) bool { return x == id })
					}
					a.saveSettings()
				}
			})
		}
	})
}

func (a *ctrl) setMenuBar(c *ui.Context, p palette) {
	s := &a.m.s
	a.columns(c, func() {
		p.sHead(c, L("Menu bar"), L("One image, tinted by macOS"))
		ui.Row(c.Key("preview")).FillWidth().Height(30).Padding(0, 12).Gap(14).Radius(6).Background(ui.Hex("#1d1d1d")).Border(1, p.L2).
			AlignItems(ui.Center).Children(func() {
			ui.Text(c, L("PREVIEW")).Font(monoFont).FontSize(10).TextColor(ui.RGBA(255, 255, 255, 0.3)).Grow(1).SingleLine()
			png, tmpl := renderMenuBar(a.menuBarSegs(), a.mbOptions(true, true))
			a.menuBarPreview(c, "img", png, tmpl, true)
			p.mono(c, fmtr.Weekday(a.m.now())+" "+format.Clock(a.m.now()), 12, ui.Hex("#ffffff"))
		})
		a.sGroup(c, p, "mb", func() {
			a.segRow(c, p, "style", L("Style"), L("Gauge glyph, plain numbers, or today's hours as bars"), &s.MenuBarStyle, [][2]string{{"gauge", "Gauge"}, {"numbers", "Numbers"}, {"bars", "Bars"}})
			a.intSeg(c, p, "rows", L("Layout"), L("Two rows stack the values with short labels and take less width"), &s.MenuBarRows, []int{2, 1}, func(v int) string { return pick(v == 1, L("One line"), L("Two rows")) })
			a.sRow(c, p, "items", L("Items"), L("Up to four; two rows fill each column top to bottom. Drag to reorder."), func() {
				a.orderList(c, p, "list", &s.MenuBarItems, menuBarItems, 4, func(id string) { swatch(c, a.itemColor(p, id), 7) })
			})
			a.thresholdRow(c, p)
			a.toggleRow(c, p, "reset", L("Show reset countdown"), L("Adds “2h 12m” after a session value"), &s.MenuBarShowReset)
		})
	}, func() {
		p.sHead(c, L("Drop-down panel"), L("Opens on click · ⌥-click opens the window"))
		a.sGroup(c, p, "panel", func() {
			a.sRow(c, p, "sections", L("Sections"), L("Shown top to bottom"), func() {
				a.orderList(c, p, "list", &s.PanelSections, panelSections, 0, func(id string) {
					switch id {
					case "claude", "codex", "cursor":
						logo(c, vendorLogo(id), 12, a.itemColor(p, id))
					default:
						swatch(c, a.itemColor(p, id), 7)
					}
				})
			})
			a.segRow(c, p, "lstyle", L("Limit style"), L("Gauges show all three marks; bars fit more windows"), &s.PanelLimitStyle, [][2]string{{"gauges", "Gauges"}, {"meters", "Bars"}})
			a.intSeg(c, p, "rows", L("Rows per list"), L("Today's models and tools"), &s.PanelListCount, []int{3, 5, 0}, func(v int) string { return pick(v == 0, L("All"), itoa(v)) })
			a.segRow(c, p, "material", L("Material"), L("Glass follows the desktop; solid keeps contrast steady"), &s.PanelMaterial, [][2]string{{"glass", "Glass"}, {"solid", "Solid"}})
		})
	})
}

// thresholdRow is the alert threshold: a slider from 50 to 100 %, past it the red that values turn.
func (a *ctrl) thresholdRow(c *ui.Context, p palette) {
	s := &a.m.s
	a.sRow(c, p, "thr", L("Alert threshold"), L("Over it, the item turns red and a notification posts once per window"), func() {
		v := s.TopThreshold()
		sl := ui.SliderBase(c.Key("sl"), &v, 50, 100).Size(200, 20).Label(L("Alert threshold"))
		sl.Draw(func(pt *ui.Painter, r ui.Rect) {
			f := float32((v - 50) / 50)
			y := r.Y + r.H/2 - 1
			pt.Fill(ui.Rect{X: r.X, Y: y, W: r.W, H: 2}, p.L3, 1)
			pt.Fill(ui.Rect{X: r.X, Y: y, W: r.W * f, H: 2}, p.T1, 1)
			pt.Fill(ui.Rect{X: r.X + r.W*f, Y: y, W: r.W * (1 - f), H: 2}, alpha(p.Red, 0.5), 0)
			pt.Fill(ui.Rect{X: r.X + r.W*f - 7, Y: r.Y + r.H/2 - 7, W: 14, H: 14}, p.FG, 7)
		})
		if sl.Changed() {
			t := math.Round(v/5) * 5
			s.AlertThresholds = []float64{t}
			if t < 95 {
				s.AlertThresholds = append(s.AlertThresholds, 95)
			}
			a.saveSettings()
		}
		p.mono(c, itoa(int(v))+"%", 12, p.T1).Width(36)
	})
}

// mbOptions are the renderer's options from the settings.
func (a *ctrl) mbOptions(dark, preview bool) mbOpts {
	s := a.m.s
	return mbOpts{Style: mbStyle(s.MenuBarStyle), Rows: s.MenuBarRows, Pace: s.MenuBarShowPace, Icon: s.MenuBarShowIcon, Red: s.MenuBarAlertColor, Dark: dark, Preview: preview}
}

// menuBarPreview shows a rendered item on a strip of the bar's colour (a template image is tinted like macOS does).
func (a *ctrl) menuBarPreview(c *ui.Context, key string, png []byte, tmpl, dark bool) {
	bmp, err := a.w.bitmap(png)
	ink := pick(dark, ui.Hex("#ffffff"), ui.Hex("#111111"))
	ui.Row(c.Key(key)).Height(22).Padding(0, 7).Radius(4).Background(ui.RGBA(255, 255, 255, 0.08)).Justify(ui.Center).AlignItems(ui.Center).Children(func() {
		if err != nil || bmp == nil {
			return
		}
		w, h := bmp.Size()
		ui.Box(c).Size(float32(w)/2, float32(h)/2).Draw(func(pt *ui.Painter, r ui.Rect) {
			o := ui.ImageOptions{}
			if tmpl {
				o.Tint = ink
			}
			pt.ImageRegion(bmp, ui.Rect{W: float32(w), H: float32(h)}, r, o)
		})
	})
}

// ── Dashboard ──

func (a *ctrl) setDashboard(c *ui.Context, p palette) {
	s := &a.m.s
	p.sHead(c, L("Widgets"), L("Order, size and visibility; each widget's own options are on its back"))
	ui.Box(c).Height(12)
	a.sGroup(c, p, "widgets", func() {
		for _, id := range slices.Clone(s.CardOrder) {
			def, ok := cardDefs[id]
			if !ok {
				continue
			}
			on := !slices.Contains(s.HiddenCards, id)
			a.sRow(c, p, id, L(def.Title), "", func() {
				for _, sz := range def.Sizes {
					if p.chip(c, "sz"+string(sz), string(sz), sz == a.cardSize(id)).Tooltip(sizeName(sz)).Clicked() {
						a.setCardSize(id, sz)
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
						a.showCard(id)
					} else {
						a.hideCard(id)
					}
				}
			})
		}
	})
	ui.Row(c.Key("reset")).Gap(8).Padding(12, 0).Children(func() {
		if p.button(c, "rl", L("Reset layout"), "", btnPlain).Clicked() {
			d := settings.Default()
			s.CardOrder, s.HiddenCards, s.CardSizes = d.CardOrder, d.HiddenCards, d.CardSizes
			a.saveSettings()
		}
		if p.button(c, "ra", L("Reset every widget option"), "", btnGhost).Clicked() {
			d := settings.Default()
			s.CardOrder, s.HiddenCards, s.CardSizes, s.CardAccents = d.CardOrder, d.HiddenCards, d.CardSizes, d.CardAccents
			s.HeroShowPrevious, s.UsageStack, s.UsageShowAverage, s.PunchcardDays = d.HeroShowPrevious, d.UsageStack, d.UsageShowAverage, d.PunchcardDays
			s.CalendarMetric, s.CalendarWeeks, s.CompositionPeriod, s.CompositionShowHitRate = d.CalendarMetric, d.CalendarWeeks, d.CompositionPeriod, d.CompositionShowHitRate
			s.CostShowLastMonth, s.CostShowProjection, s.CostShowDailyBars, s.ModelsShowSparklines, s.ModelsMetric = d.CostShowLastMonth, d.CostShowProjection, d.CostShowDailyBars, d.ModelsShowSparklines, d.ModelsMetric
			a.saveSettings()
		}
	})
}

// ── Limits ──

func (a *ctrl) setLimits(c *ui.Context, p palette) {
	s := &a.m.s
	a.columns(c, func() {
		p.sHead(c, L("Limits"), L("Probed every few minutes while something shows them"))
		a.sGroup(c, p, "providers", func() {
			for _, prov := range limits.Providers {
				e := a.lim.Get(prov)
				detail := a.statusText(e)
				if e.Snapshot != nil && e.Snapshot.AccountLabel != "" {
					detail = e.Snapshot.AccountLabel + " · " + detail
				}
				show := !slices.Contains(s.HiddenLimitProviders, string(prov))
				a.sRow(c, p, string(prov), prov.DisplayName(), detail, func() {
					logo(c, vendorLogo(string(prov)), 14, a.m.vendorTint(p, string(prov)))
					if p.toggle(c, "t", &show).Changed() {
						a.setExcluded(&s.HiddenLimitProviders, string(prov), !show)
					}
				})
			}
			a.claudeKeyRow(c, p)
		})
	}, func() {
		p.sHead(c, L("Gauges and alerts"), "")
		a.sGroup(c, p, "gauges", func() {
			a.sRow(c, p, "used", L("Numbers show"), "", func() {
				sel := pick(s.LimitShowUsed, 0, 1)
				if n := p.segmented(c, "s", sel, L("Used"), L("Left")); n != sel {
					s.LimitShowUsed = n == 0
					a.saveSettings()
				}
			})
			a.toggleRow(c, p, "buckets", L("Per-model windows"), L("Adds Fable and other model buckets"), &s.LimitShowModelBuckets)
			a.toggleRow(c, p, "pace", L("Pace and forecast"), L("The needle for time gone, dim ticks for where usage lands by the reset"), &s.LimitShowPace)
			a.thresholdRow(c, p)
			a.toggleRow(c, p, "notif", L("Notify at the alert threshold"), L("Once per window, at the threshold and at 95%"), &s.LimitNotifications)
			a.sRow(c, p, "refresh", L("Refresh"), "", func() {
				if p.button(c, "r", L("Refresh Now"), "rotate-cw", btnPlain).Clicked() {
					a.lim.RefreshNow()
				}
			})
		})
	})
}

func (a *ctrl) setExcluded(list *[]string, id string, excluded bool) {
	*list = slices.DeleteFunc(*list, func(x string) bool { return x == id })
	if excluded {
		*list = append(*list, id)
	}
	a.saveSettings()
}

// claudeKeyRow stores the owner-pasted Claude sessionKey. The key is never shown again; only whether one is saved.
func (a *ctrl) claudeKeyRow(c *ui.Context, p palette) {
	has := a.creds.ClaudeCookie() != ""
	a.sRow(c, p, "key", L("claude.ai key"), pick(has, L("Saved. Paste a new one to replace it."), L("Paste sessionKey (sk-ant-…) from claude.ai")), func() {
		ui.TextInput(c.Key("in"), &a.w.keyDraft).Password().Placeholder("sk-ant-…").Width(180)
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

// ── Data sources ──

func (a *ctrl) setData(c *ui.Context, p palette) {
	m := a.m
	s := &m.s
	a.columns(c, func() {
		p.sHead(c, L("Data sources"), L("Read from local logs; nothing leaves this Mac"))
		a.sGroup(c, p, "refresh", func() {
			a.intSeg(c, p, "live", L("Live refresh"), L("Throttled while the window or panel is open; paused when nothing is visible"), &s.LiveRefreshSeconds, []int{15, 30, 60}, func(v int) string { return itoa(v) + " s" })
			a.intSeg(c, p, "full", L("Full rescan"), L("Rebuilds history and syncs Cursor"), &s.FullRefreshMinutes, []int{5, 15, 60}, func(v int) string { return itoa(v) + " m" })
			a.sRow(c, p, "excluded", L("Excluded"), L("Left out of every number, live and history"), func() { a.excludedChips(c, p) })
			h := m.d.History
			since := "—"
			if len(h) > 0 {
				since = L("since %@", fmtr.LongDate(h[0].Date))
			}
			a.sRow(c, p, "dir", L("History"), "~/Library/Application Support/SimpleToken · "+since, func() {
				if p.button(c, "show", L("Reveal"), "folder-open", btnPlain).Clicked() && a.running {
					_ = mygo.Shell.OpenPath(paths.Dir())
				}
			})
		})
	}, func() {
		p.sHead(c, L("Models and tools"), L("Colour, alias and whether it counts"))
		a.sGroup(c, p, "models", func() { a.modelRows(c, p) })
		ui.Row(c.Key("actions")).Gap(8).Children(func() {
			if p.button(c, "rc", L("Reset colours"), "", btnGhost).Clicked() {
				s.ModelColorOverrides, s.ToolColorOverrides = map[string]string{}, map[string]string{}
				a.saveSettings()
			}
			if p.button(c, "ra", L("Clear aliases"), "", btnGhost).Clicked() {
				s.ModelAliases = map[string]string{}
				a.saveSettings()
			}
		})
	})
}

// excludedChips lists what is left out, each a chip that brings it back, and a menu to leave more out.
func (a *ctrl) excludedChips(c *ui.Context, p palette) {
	m := a.m
	s := &m.s
	ui.Row(c.Key("chips")).Wrap().Gap(6).MaxWidth(300).Justify(ui.End).Children(func() {
		for _, id := range s.ExcludedModels {
			if p.chip(c, "m"+id, m.modelName(id)+" ×", true).Tooltip(L("Count it again")).Clicked() {
				a.setExcluded(&s.ExcludedModels, id, false)
			}
		}
		for _, id := range s.ExcludedClients {
			if p.chip(c, "t"+id, toolName(id)+" ×", true).Tooltip(L("Count it again")).Clicked() {
				a.setExcluded(&s.ExcludedClients, id, false)
			}
		}
		add := p.chip(c, "add", "+ "+L("Exclude…"), false)
		add.Menu(func(menu *ui.Menu) {
			rep := m.report("ALL", "tokens")
			for _, sh := range rep.Clients {
				if !slices.Contains(s.ExcludedClients, sh.Key) && menu.Item(toolName(sh.Key)).Chosen() {
					a.setExcluded(&s.ExcludedClients, sh.Key, true)
				}
			}
			menu.Separator()
			for _, sh := range rep.Models {
				if !slices.Contains(s.ExcludedModels, sh.Key) && menu.Item(sh.Key).Chosen() {
					a.setExcluded(&s.ExcludedModels, sh.Key, true)
				}
			}
		})
	})
}

// modelRows lists every model and tool with its colour well, alias (models) and include switch.
func (a *ctrl) modelRows(c *ui.Context, p palette) {
	m := a.m
	s := &m.s
	rep := m.report("ALL", "tokens")
	for _, sh := range rep.Clients {
		id := sh.Key
		inc := !slices.Contains(s.ExcludedClients, id)
		a.sRow(c, p, "t"+id, toolName(id), L("%@ all time", shortNum(float64(sh.Tokens))), func() {
			a.colorWell(c, p, s.ToolColorOverrides, id, m.toolColor(p, id))
			if p.toggleCompact(c, "inc", &inc).Changed() {
				a.setExcluded(&s.ExcludedClients, id, !inc)
			}
		})
	}
	for _, sh := range rep.Models {
		id := sh.Key
		inc := !slices.Contains(s.ExcludedModels, id)
		v := vendorOf(id)
		a.sRow(c, p, "m"+id, id, vendorName(v)+" · "+shortNum(float64(sh.Tokens)), func() {
			alias := s.ModelAliases[id]
			if ui.TextInput(c.Key("alias"), &alias).Placeholder(L("Alias")).Width(120).Changed() {
				if strings.TrimSpace(alias) == "" {
					delete(s.ModelAliases, id)
				} else {
					s.ModelAliases[id] = alias
				}
				a.saveSettings()
			}
			a.colorWell(c, p, s.ModelColorOverrides, id, m.modelColor(p, id))
			if p.toggleCompact(c, "inc", &inc).Changed() {
				a.setExcluded(&s.ExcludedModels, id, !inc)
			}
		})
	}
}

// ── Appearance ──

func palName(id Pal) string {
	switch id {
	case PalPaper:
		return "Paper"
	case PalIce:
		return "Ice"
	}
	return "Graphite"
}

func (a *ctrl) setAppearance(c *ui.Context, p palette) {
	s := &a.m.s
	a.columns(c, func() {
		p.sHead(c, L("Model colours"), L("Colour follows the model, by its rank over the last 30 days — never the selected range"))
		a.sGroup(c, p, "colours", func() {
			a.sRow(c, p, "series", L("Series"), L("Vendor colours, or the ink ladder"), func() {
				if p.segValue(c, "s", &s.SeriesColors, [][2]string{{"vendor", L("Colour")}, {"ink", L("Ink")}}) {
					a.saveSettings()
				}
			})
			a.sRow(c, p, "families", L("Families"), L("opus · sonnet · gpt / codex · gemini · haiku · fable; the rest Other"), func() {
				for _, col := range []ui.Color{p.Model.Opus, p.Model.Sonnet, p.Model.Codex, p.Model.Gemini, p.Model.Haiku, p.Model.Fable, p.Model.Other} {
					swatch(c, col, 12)
				}
			})
			a.sRow(c, p, "accents", L("Card accents"), L("For cards that draw one series, each with a validated 4-step ramp"), func() {
				for _, r := range [][4]ui.Color{p.Accent.SlateR, p.Accent.ClayR, p.Accent.VioletR} {
					ui.Row(c.Key(hexColor(r[0]))).Gap(2).Children(func() {
						for _, col := range r {
							swatch(c, col, 10)
						}
					})
				}
			})
			a.segRow(c, p, "marks", L("Brand logos"), L("Always mono, tinted by the vendor colour"), &s.VendorMarks, [][2]string{{"color", "Colour"}, {"mono", "Mono"}})
		})
	}, func() {
		p.sHead(c, L("Display"), "")
		a.sGroup(c, p, "display", func() {
			a.segRow(c, p, "theme", L("Appearance"), L("Follows macOS unless set"), &s.Theme, [][2]string{{"system", "System"}, {"dark", "Dark"}, {"light", "Light"}})
			a.segRow(c, p, "size", L("Interface size"), L("Text and controls in the window and the panel"), &s.InterfaceSize, [][2]string{{"small", "Small"}, {"medium", "Medium"}, {"large", "Large"}})
			a.sRow(c, p, "pal", L("Interface palette"), L("SimpleToggle's themes; Graphite keeps the chrome neutral"), func() {
				for _, id := range palettes {
					sw := newPalette(p.Dark, id)
					sel := Pal(s.Palette) == id
					b := ui.Column(c.Key(string(id))).Gap(4).AlignItems(ui.Center).Label(palName(id))
					b.Children(func() {
						ui.Box(c.Key("sw")).Size(34, 24).Radius(5).Background(sw.BG).Border(pick(sel, float32(1.5), 1), pick(sel, p.T1, p.L3)).Draw(func(pt *ui.Painter, r ui.Rect) {
							pt.Fill(ui.Rect{X: r.X + 6, Y: r.Y + 6, W: r.W - 12, H: r.H - 12}, sw.Surf, 3)
							pt.Fill(ui.Rect{X: r.X + r.W - 12, Y: r.Y + r.H/2 - 2, W: 4, H: 4}, sw.Sig, 2)
						})
						p.mono(c, palName(id), 10.5, pick(sel, p.T1, p.T3))
					})
					pressPose(b, 0.94)
					if b.Clicked() {
						s.Palette = string(id)
						a.saveSettings()
					}
				}
			})
			a.sRow(c, p, "numbers", L("Numbers"), L("Axis ticks stay short either way"), func() {
				p.mono(c, pick(s.ExactNumbers, format.Grouped(1094118320), "1.09B"), 11, p.T3)
				sel := pick(s.ExactNumbers, 1, 0)
				if n := p.segmented(c, "s", sel, L("Short"), L("Exact")); n != sel {
					s.ExactNumbers = n == 1
					a.saveSettings()
				}
			})
		})
	})
}

// ── Updates ──

func (a *ctrl) setUpdates(c *ui.Context, p palette) {
	p.sHead(c, L("Updates"), L("Signed, checked and installed in the background"))
	ui.Box(c).Height(12)
	ui.Column(c.Key("u")).MaxWidth(620).FillWidth().Children(func() {
		a.sGroup(c, p, "updates", func() { a.updateRows(c, p) })
	})
}

// updateRows are the update settings: automatic install, check now, restart once a version is installed.
func (a *ctrl) updateRows(c *ui.Context, p palette) {
	s := &a.m.s
	if !a.running {
		a.toggleRow(c, p, "auto", L("Automatic updates"), "", &s.AutoUpdate)
		return
	}
	enabled := mygo.Updater.Enabled()
	detail := L("Version %@", mygo.App.Version())
	if !enabled {
		detail += " · " + L("This build does not update itself")
	}
	a.toggleRow(c, p, "auto", L("Automatic updates"), detail, &s.AutoUpdate)
	if !enabled {
		return
	}
	busy, ready, checked, errText := a.upd.state()
	status := L("Not checked yet")
	switch {
	case busy:
		status = L("Checking…")
	case ready != "":
		status = L("Version %@ is ready", ready)
	case errText != "":
		status = errText
	case !checked.IsZero():
		status = L("Up to date") + " · " + fmtr.Ago(checked, a.m.now())
	}
	a.sRow(c, p, "check", pick(ready != "", L("Restart to update"), L("Check for updates")), status, func() {
		if ready != "" {
			if p.button(c, "restart", L("Restart to update"), "rotate-cw", btnPrimary).Clicked() {
				mygo.App.Relaunch()
			}
			return
		}
		if p.button(c, "now", L("Check now"), "", btnPlain).Clicked() && !busy {
			go a.installUpdate()
		}
	})
}

// ── Card backs ──

// cardBack is a card's options (designs/simpletoken-v3 Edit board): its own settings, then its accent and size.
func (a *ctrl) cardBack(c *ui.Context, p palette, pl placed) {
	m := a.m
	s := &m.s
	def := cardDefs[pl.id]
	ui.Scroll(c.Key("opts")).Grow(1).FillWidth().Children(func() {
		a.sGroup(c, p, "back", func() {
			switch pl.id {
			case "hero":
				a.segRow(c, p, "metric", L("Metric"), L("Follows the top bar"), &s.Metric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}})
				a.toggleRow(c, p, "prev", L("Compare with the previous period"), L("Dashed line, same length as the range"), &s.HeroShowPrevious)
			case "limits":
				a.sRow(c, p, "providers", L("Providers"), "", func() {
					for _, prov := range limits.Providers {
						on := !slices.Contains(s.HiddenLimitProviders, string(prov))
						if p.chip(c, string(prov), prov.DisplayName(), on).Clicked() {
							a.setExcluded(&s.HiddenLimitProviders, string(prov), on)
						}
					}
				})
				a.toggleRow(c, p, "buckets", L("Per-model windows"), "", &s.LimitShowModelBuckets)
				a.toggleRow(c, p, "pace", L("Pace and forecast"), "", &s.LimitShowPace)
			case "models":
				a.segRow(c, p, "share", L("Share by"), "", &s.ModelsMetric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}})
				a.toggleRow(c, p, "spark", L("30-day sparklines"), "", &s.ModelsShowSparklines)
			case "usage":
				a.segRow(c, p, "stack", L("Stacking"), "", &s.UsageStack, [][2]string{{"model", "By model"}, {"tool", "By tool"}, {"none", "Total"}})
				a.intSeg(c, p, "interval", L("Today in"), L("From Claude Code's logs"), &s.IntradayMinutes, []int{60, 30}, func(v int) string {
					return pick(v == 60, L("Hours"), L("Half hours"))
				})
				a.toggleRow(c, p, "avg", L("Average line"), "", &s.UsageShowAverage)
			case "calendar":
				a.segRow(c, p, "metric", L("Shade by"), "", &s.CalendarMetric, [][2]string{{"tokens", "Tokens"}, {"cost", "Cost"}})
				a.intSeg(c, p, "weeks", L("Weeks"), "", &s.CalendarWeeks, []int{0, 17, 26, 53}, func(v int) string {
					return pick(v == 0, L("By size"), itoa(v))
				})
			case "composition":
				a.segRow(c, p, "period", L("Period"), "", &s.CompositionPeriod, [][2]string{{"auto", "Range"}, {"today", "Today"}, {"month", "Month"}, {"allTime", "All"}})
			case "cost":
				a.toggleRow(c, p, "proj", L("Month-end projection"), "", &s.CostShowProjection)
				a.toggleRow(c, p, "last", L("Last month's marker"), "", &s.CostShowLastMonth)
			case "tools":
				for _, sh := range m.report("ALL", "tokens").Clients {
					id := sh.Key
					inc := !slices.Contains(s.ExcludedClients, id)
					a.sRow(c, p, "tool-"+id, toolName(id), "", func() {
						a.colorWell(c, p, s.ToolColorOverrides, id, m.toolColor(p, id))
						if p.toggleCompact(c, "inc", &inc).Changed() {
							a.setExcluded(&s.ExcludedClients, id, !inc)
						}
					})
				}
			}
			if cardAccented(pl.id) {
				a.sRow(c, p, "accent", L("Accent"), L("Single-series cards take their own colour"), func() {
					cur := a.accentName(pl.id)
					for _, o := range accentOptions {
						save, had := s.CardAccents[pl.id]
						s.CardAccents[pl.id] = o[0]
						col := a.accent(p, pl.id)
						if had {
							s.CardAccents[pl.id] = save
						} else {
							delete(s.CardAccents, pl.id)
						}
						b := ui.Box(c.Key(o[0])).Size(22, 22).Radius(11).Background(col).Label(L(o[1])).Tooltip(L(o[1]))
						if cur == o[0] {
							b.Border(1.5, p.T1)
						}
						pressPose(b, 0.92)
						if b.Clicked() {
							s.CardAccents[pl.id] = o[0]
							a.saveSettings()
						}
					}
				})
			}
			if len(def.Sizes) > 1 {
				a.sRow(c, p, "size", L("Size"), L("Each size has its own layout"), func() {
					for _, sz := range def.Sizes {
						if p.chip(c, string(sz), string(sz), sz == pl.size).Tooltip(sizeName(sz)).Clicked() {
							a.setCardSize(pl.id, sz)
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
		if ui.ColorWell(c.Key("well"), &col).Label(L("Colour")).Size(20, 20).Changed() {
			overrides[id] = hexColor(col)
			a.saveSettings()
		}
		if overrides[id] != "" {
			if p.iconBtn(c, "reset", "rotate-ccw", L("Restore the default colour"), false).Clicked() {
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
