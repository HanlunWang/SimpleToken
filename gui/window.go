package gui

import (
	"slices"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/settings"
)

// winState is the main window's view state. It lives as long as the window: closing it drops everything.
type winState struct {
	settings      bool
	tab           string
	editing       bool
	flipped       string // card showing its back
	focus         map[string]string
	manualRefresh time.Time
	gridW         float32
	keyDraft      string // Claude session key being pasted (never shown again once saved)
	login         *bool  // open-at-login state, read once per window
	usageDay      string // the day the 1D usage chart shows ("" today)
	calOpen       bool
	calDate       time.Time
	winW          float32
	bitmaps       map[string]*ui.Bitmap
}

// narrow is a window too small for the top bar's range picker (it moves to a row of its own).
func (w *winState) narrow() bool { return w.winW > 0 && w.winW < 760 }

// bitmap decodes a PNG once per window (menu bar previews redraw every frame).
func (w *winState) bitmap(png []byte) (*ui.Bitmap, error) {
	if w.bitmaps == nil || len(w.bitmaps) > 32 {
		w.bitmaps = map[string]*ui.Bitmap{}
	}
	if b, ok := w.bitmaps[string(png)]; ok {
		return b, nil
	}
	b, err := ui.DecodeBitmap(png)
	if err == nil {
		w.bitmaps[string(png)] = b
	}
	return b, err
}

func newWinState() *winState { return &winState{tab: "general", focus: map[string]string{}} }

const (
	cellH   = 168
	cellGap = 12
	minColW = 200
)

// windowView is the main window: a top bar over the dashboard or the settings page.
func (a *ctrl) windowView(c *ui.Context) {
	p := a.palette()
	c.SetTheme(p.theme(c.Theme()))
	w := a.w
	c.OnShortcut(ui.Cmd, ui.KeyR, a.refreshAll)
	c.OnShortcut(ui.Cmd, ui.KeyComma, func() { w.settings = true })
	if c.Shortcut(0, ui.KeyEscape) {
		switch {
		case w.flipped != "":
			w.flipped = ""
		case w.editing:
			w.editing = false
		case w.settings:
			w.settings = false
		}
	}
	root := ui.Column(c.Key("root")).Fill().Background(p.BG)
	if b := root.Bounds(); b.W > 0 {
		w.winW = b.W
	}
	root.Children(func() {
		a.topBar(c, p)
		if !w.settings && w.narrow() {
			ui.Row(c.Key("range2")).FillWidth().Padding(8, 12).Justify(ui.Center).Shrink(0).Children(func() { a.rangePicker(c, p) })
		}
		if w.settings {
			ui.Column(c.Key("settings")).Grow(1).FillWidth().MinHeight(0).
				Transition(ui.ElementTransition{Duration: 200 * time.Millisecond, Enter: &ui.Motion{X: 16}}).
				Children(func() { a.settingsPage(c, p) })
			return
		}
		ui.Row(c.Key("dash")).Grow(1).FillWidth().MinHeight(0).Children(func() {
			ui.Scroll(c.Key("scroll")).Grow(1).FillHeight().Children(func() {
				ui.Column(c.Key("pad")).FillWidth().Padding(16, 18, 20).Children(func() {
					a.dashboard(c, p)
					a.footer(c, p)
				})
			})
			if w.editing {
				a.widgetDrawer(c, p)
			}
		})
	})
}

func (a *ctrl) topBar(c *ui.Context, p palette) {
	m, w := a.m, a.w
	bar := ui.Row(c.Key("top")).FillWidth().Height(46).Padding(0, 12, 0, 84).Gap(8).AlignItems(ui.Center).Shrink(0).DragWindow()
	bar.Background(alpha(p.BG, 0.94))
	bar.Children(func() {
		ui.Box(c).Absolute().Left(0).Bottom(0).FillWidth().Height(1).Background(p.L2)
		p.brand(c, 12.5, m.d.Refreshing && time.Since(w.manualRefresh) < 5*time.Second)
		p.mono(c, "/", 12, p.T4)
		usage := ui.Text(c.Key("crumb"), L("usage")).Font(monoFont).FontSize(12).TextColor(pick(w.settings, p.T2, p.T1)).SingleLine()
		if w.settings && usage.Clicked() {
			w.settings = false
		}
		if w.settings {
			p.mono(c, "/", 12, p.T4)
			p.mono(c, L("settings"), 12, p.T1)
		}
		ui.Box(c).Grow(1)
		if w.settings {
			if p.button(c, "back", L("Back")+" · esc", "arrow-left", btnGhost).Clicked() {
				w.settings = false
			}
			return
		}
		a.refreshControl(c, p)
		if !w.narrow() {
			a.rangePicker(c, p)
		}
		if p.iconBtn(c, "edit", pick(w.editing, "check", "layout-grid"), pick(w.editing, L("Done"), L("Widgets")), w.editing).Clicked() {
			w.editing = !w.editing
			w.flipped = ""
		}
		if p.iconBtn(c, "settings", "settings-2", L("Settings")+" (⌘,)", false).Clicked() {
			w.settings = true
		}
	})
}

// rangePicker is the 1D … ALL segmented control.
func (a *ctrl) rangePicker(c *ui.Context, p palette) {
	m := a.m
	ranges := make([]string, len(analytics.Ranges))
	sel := 0
	for i, r := range analytics.Ranges {
		ranges[i] = string(r)
		if string(r) == m.s.Range {
			sel = i
		}
	}
	if n := p.segmented(c, "range", sel, ranges...); n != sel {
		m.s.Range = ranges[n]
		a.w.usageDay = ""
		a.saveSettings()
	}
}

// refreshControl shows the last update; only a manual refresh animates it (background ticks never do).
func (a *ctrl) refreshControl(c *ui.Context, p palette) {
	m := a.m
	now := m.now()
	label := fmtr.Updated(m.d.UpdatedAt, now)
	if !m.d.Collected {
		label = L("Not collected yet")
	}
	manual := m.d.Refreshing && time.Since(a.w.manualRefresh) < 2*time.Minute
	if manual {
		label = L("Refreshing")
	}
	b := ui.Row(c.Key("refresh")).Height(26).Padding(0, 9).Radius(p.rCtl()).Gap(7).AlignItems(ui.Center).Shrink(0).
		Label(L("Refresh")).Tooltip(L("Refresh") + " ⌘R · " + L("Today's usage refresh") + " " + fmtr.Seconds(m.s.LiveRefreshSeconds))
	b.Background(b.AnimateColor("bg", pick(b.Hovered(), p.L2, ui.Transparent), animHover))
	b.Children(func() {
		if manual {
			p.dotRun(c, 10)
		} else {
			ui.Box(c).Size(5, 5).Radius(2.5).Background(pick(m.d.Collected, p.Sig, p.L4)).Shadow(0, 0, 5, 0, pick(m.d.Collected, p.glow(), ui.Transparent))
		}
		if !a.w.narrow() {
			p.mono(c, label, 11.5, p.T2)
		}
	})
	if b.Clicked() {
		a.refreshAll()
	}
}

func (a *ctrl) footer(c *ui.Context, p palette) {
	m, w := a.m, a.w
	hidden := 0
	for _, id := range m.s.CardOrder {
		if slices.Contains(m.s.HiddenCards, id) {
			hidden++
		}
	}
	ui.Row(c.Key("footer")).FillWidth().Justify(ui.Center).Gap(10).Padding(18, 0, 0).AlignItems(ui.Center).Children(func() {
		p.mono(c, L("Data from this Mac"), 10.5, p.T4)
		p.mono(c, "·", 10.5, p.T4)
		p.mono(c, L("Drag a widget to move it, right-click to resize"), 10.5, p.T4)
		if m.d.LegacyMerged {
			p.mono(c, "·", 10.5, p.T4)
			p.mono(c, L("Token Monitor history merged"), 10.5, p.T4)
		}
		if n := len(m.s.ExcludedModels) + len(m.s.ExcludedClients); n > 0 {
			p.mono(c, "·", 10.5, p.T4)
			p.mono(c, L("%lld excluded", n), 10.5, p.T4)
		}
		if hidden > 0 {
			p.mono(c, "·", 10.5, p.T4)
			t := ui.Text(c.Key("add"), L("Add widgets (%lld hidden)", hidden)).Font(monoFont).FontSize(10.5).TextColor(p.T2).Underline().SingleLine()
			if t.Clicked() {
				w.editing = true
			}
		}
	})
}

// ── Grid ──

type placed struct {
	id         string
	size       cardSize
	col, row   int
	cols, rows int
}

// pack places cards dense first-fit in a grid of n columns (wide cards fall back to large under 3 columns).
func (a *ctrl) pack(n int) ([]placed, int) {
	var out []placed
	occ := map[[2]int]bool{}
	rows := 0
	for _, id := range a.m.s.CardOrder {
		if slices.Contains(a.m.s.HiddenCards, id) {
			continue
		}
		if _, ok := cardDefs[id]; !ok {
			continue
		}
		size := a.cardSize(id)
		if size == sizeW && n < 3 {
			size = sizeL
		}
		cw, ch := size.span()
		cw = min(cw, n)
		for r := 0; ; r++ {
			found := false
			for col := 0; col+cw <= n; col++ {
				free := true
				for dy := range ch {
					for dx := range cw {
						if occ[[2]int{col + dx, r + dy}] {
							free = false
						}
					}
				}
				if free {
					for dy := range ch {
						for dx := range cw {
							occ[[2]int{col + dx, r + dy}] = true
						}
					}
					out = append(out, placed{id, size, col, r, cw, ch})
					rows = max(rows, r+ch)
					found = true
					break
				}
			}
			if found {
				break
			}
		}
	}
	return out, rows
}

func columnsFor(w float32) int {
	n := int((w + cellGap) / (minColW + cellGap))
	n -= n % 2
	return max(2, min(8, n))
}

func (a *ctrl) dashboard(c *ui.Context, p palette) {
	m, w := a.m, a.w
	rep := m.current()
	grid := ui.Box(c.Key("grid")).FillWidth()
	if b := grid.Bounds(); b.W > 0 {
		w.gridW = b.W
	}
	if w.gridW == 0 {
		w.gridW = 1140
	}
	n := columnsFor(w.gridW)
	cells, rows := a.pack(n)
	colW := (w.gridW - float32(n-1)*cellGap) / float32(n)
	grid.Height(float32(rows)*cellH + float32(max(0, rows-1))*cellGap)
	grid.Children(func() {
		for _, pl := range cells {
			x := float32(pl.col) * (colW + cellGap)
			y := float32(pl.row) * (cellH + cellGap)
			wd := float32(pl.cols)*colW + float32(pl.cols-1)*cellGap
			ht := float32(pl.rows)*cellH + float32(pl.rows-1)*cellGap
			card := ui.Column(c.Key(pl.id)).Absolute().Left(x).Top(y).Size(wd, ht).Radius(p.rCard()).Background(p.Surf).
				Transition(ui.ElementTransition{Duration: 400 * time.Millisecond, Ease: ui.EaseInOut, Position: true})
			a.cardShell(c, p, card, pl, rep)
		}
	})
}

func (a *ctrl) cardShell(c *ui.Context, p palette, card ui.Element, pl placed, rep analytics.Report) {
	w := a.w
	def := cardDefs[pl.id]
	hover := card.Hovered()
	border := pick(hover, p.L3, p.L2)
	if w.editing {
		card.Drag(pl.id)
		if id, over := ui.DragOver[string](card); over && id != pl.id {
			border = p.sigLine()
			card.Shadow(0, 0, 18, 0, p.glowSoft())
		}
		if id, ok := ui.Drop[string](card); ok && id != pl.id {
			a.moveCard(id, pl.id)
		}
		if card.Dragging() {
			card.Opacity(0.35)
		}
	}
	card.Border(1, card.AnimateColor("bd", border, animHover))
	card.ContextMenu(a.cardMenu(pl))
	flipped := w.flipped == pl.id
	card.Children(func() {
		if w.editing {
			ui.Box(c).Absolute().Left(-1).Top(-1).Right(-1).Bottom(-1).Radius(p.rCard()).PassThrough().Draw(func(pt *ui.Painter, r ui.Rect) {
				pt.StrokeDashed(r, p.L4, p.rCard(), 1)
			})
		}
		ui.Row(c.Key("head")).FillWidth().Height(34).Padding(0, 8, 0, 12).Gap(8).AlignItems(ui.Center).Shrink(0).Children(func() {
			p.caption(c, L(def.Title)+pick(flipped, " · "+L("Settings"), ""))
			if !flipped {
				p.mono(c, a.cardNote(pl.id, rep), 10.5, p.T4).MinWidth(0).Ellipsis("…")
			}
			ui.Box(c).Grow(1)
			switch {
			case flipped:
				if p.iconBtn(c, "hide", "eye-off", L("Hide widget"), false).Clicked() {
					a.hideCard(pl.id)
				}
				if p.button(c, "done", L("Done"), "", btnPrimary).Clicked() {
					w.flipped = ""
				}
			case w.editing:
				icon(c, "grip-vertical", 14).TextColor(p.T3)
			case hover:
				if p.iconBtn(c, "opts", "sliders-horizontal", L("%@ settings", L(def.Title)), false).Clicked() {
					w.flipped = pl.id
				}
			}
		})
		body := ui.Column(c.Key(pick(flipped, "back", "front"))).FillWidth().Grow(1).MinHeight(0).Padding(0, 12, 12)
		if flipped {
			body.Transition(ui.ElementTransition{Duration: 260 * time.Millisecond, Enter: &ui.Motion{Scale: 0.97}})
			body.Children(func() { a.cardBack(c, p, pl) })
		} else {
			body.Children(func() { a.cardFront(c, p, pl, rep) })
		}
		if w.editing && !flipped {
			a.sizer(c, p, pl)
		}
	})
}

func (a *ctrl) cardFront(c *ui.Context, p palette, pl placed, rep analytics.Report) {
	switch id := pl.id; {
	case id == "hero":
		a.heroCard(c, p, pl.size, rep)
	case cardDefs[id].Stat:
		a.statCard(c, p, id, pl.size, rep)
	case id == "limits":
		a.limitsCard(c, p, pl.size)
	case id == "models":
		a.modelsCard(c, p, pl.size, rep)
	case id == "map":
		a.mapCard(c, p, pl.size, rep)
	case id == "flow":
		a.flowCard(c, p, pl.size, rep)
	case id == "usage":
		a.usageCard(c, p, pl.size, rep)
	case id == "calendar":
		a.calendarCard(c, p, pl.size)
	case id == "punchcard":
		a.punchCard(c, p, pl.size)
	case id == "tools":
		a.toolsCard(c, p, pl.size, rep)
	case id == "composition":
		a.compositionCard(c, p, pl.size, rep)
	case id == "cost":
		a.costCard(c, p, pl.size)
	}
}

// sizer is the edit-mode size switch in a card's corner.
func (a *ctrl) sizer(c *ui.Context, p palette, pl placed) {
	ui.Row(c.Key("sizer")).Absolute().Right(6).Bottom(6).Padding(2).Gap(2).Radius(4).Background(p.Elev).Border(1, p.L3).Children(func() {
		for _, s := range cardDefs[pl.id].Sizes {
			cw, ch := s.span()
			on := s == pl.size
			b := ui.Row(c.Key(string(s))).Height(18).Padding(0, 5).Radius(2).AlignItems(ui.Center).Background(pick(on, p.L3, ui.Transparent)).Label(sizeName(s))
			b.Children(func() { p.mono(c, itoa(cw)+"×"+itoa(ch), 9.5, pick(on, p.T1, p.T3)) })
			if b.Clicked() {
				a.setCardSize(pl.id, s)
			}
		}
		if p.iconBtn(c, "hide", "eye-off", L("Hide widget"), false).Clicked() {
			a.hideCard(pl.id)
		}
	})
}

func sizeName(s cardSize) string {
	switch s {
	case sizeS:
		return L("Small · 1×1")
	case sizeM:
		return L("Medium · 2×1")
	case sizeL:
		return L("Large · 2×2")
	}
	return L("Wide · 4×2")
}

func (a *ctrl) cardMenu(pl placed) func(m *ui.Menu) {
	return func(m *ui.Menu) {
		for _, s := range cardDefs[pl.id].Sizes {
			if m.Item(sizeName(s)).Checked(s == pl.size).Chosen() {
				a.setCardSize(pl.id, s)
			}
		}
		m.Separator()
		if m.Item(L("Move Earlier")).Chosen() {
			a.shiftCard(pl.id, -1)
		}
		if m.Item(L("Move Later")).Chosen() {
			a.shiftCard(pl.id, 1)
		}
		m.Separator()
		if m.Item(L("Hide “%@”", L(cardDefs[pl.id].Title))).Chosen() {
			a.hideCard(pl.id)
		}
	}
}

func (a *ctrl) setCardSize(id string, s cardSize) {
	a.m.s.CardSizes[id] = string(s)
	a.saveSettings()
}

func (a *ctrl) hideCard(id string) {
	if !slices.Contains(a.m.s.HiddenCards, id) {
		a.m.s.HiddenCards = append(a.m.s.HiddenCards, id)
	}
	if a.w.flipped == id {
		a.w.flipped = ""
	}
	a.saveSettings()
}

func (a *ctrl) moveCard(id, before string) {
	o := slices.DeleteFunc(slices.Clone(a.m.s.CardOrder), func(x string) bool { return x == id })
	i := slices.Index(o, before)
	if i < 0 {
		return
	}
	a.m.s.CardOrder = slices.Insert(o, i, id)
	a.saveSettings()
}

func (a *ctrl) shiftCard(id string, d int) {
	o := a.m.s.CardOrder
	i := slices.Index(o, id)
	j := i + d
	if i < 0 || j < 0 || j >= len(o) {
		return
	}
	o[i], o[j] = o[j], o[i]
	a.saveSettings()
}

// widgetDrawer lists every widget in edit mode: visibility, allowed sizes, reset.
func (a *ctrl) widgetDrawer(c *ui.Context, p palette) {
	m := a.m
	ui.Column(c.Key("drawer")).Width(252).FillHeight().Background(p.BG2).Shrink(0).
		Transition(ui.ElementTransition{Duration: 220 * time.Millisecond, Enter: &ui.Motion{X: 20}, Exit: &ui.Motion{X: 20}}).Children(func() {
		ui.Box(c).Absolute().Left(0).Top(0).Width(1).FillHeight().Background(p.L2)
		ui.Row(c.Key("h")).FillWidth().Height(40).Padding(0, 12).AlignItems(ui.Center).Children(func() {
			p.caption(c, L("Widgets"))
			ui.Box(c).Grow(1)
			if p.button(c, "reset", L("Reset to Default"), "", btnGhost).Clicked() {
				d := settings.Default()
				m.s.CardOrder, m.s.HiddenCards, m.s.CardSizes = d.CardOrder, d.HiddenCards, d.CardSizes
				a.saveSettings()
			}
		})
		ui.Scroll(c.Key("list")).Grow(1).FillWidth().Children(func() {
			ui.Column(c).FillWidth().Padding(0, 8, 12).Children(func() {
				for _, group := range []struct {
					name string
					stat bool
				}{{L("Charts"), false}, {L("Stats"), true}} {
					p.mono(c, upper(group.name), 10, p.T4).Padding(8, 6, 4)
					for _, id := range settings.Cards {
						if cardDefs[id].Stat != group.stat {
							continue
						}
						on := !slices.Contains(m.s.HiddenCards, id)
						ui.Row(c.Key(id)).FillWidth().Height(32).Padding(0, 6).Gap(8).AlignItems(ui.Center).Children(func() {
							ui.Text(c, L(cardDefs[id].Title)).FontSize(12).TextColor(pick(on, p.T1, p.T3)).Grow(1).SingleLine()
							sizes := ""
							for _, s := range cardDefs[id].Sizes {
								sizes += string(s) + " "
							}
							p.mono(c, sizes, 10, p.T4)
							v := on
							if p.toggle(c, "t", &v).Changed() {
								if v {
									m.s.HiddenCards = slices.DeleteFunc(m.s.HiddenCards, func(x string) bool { return x == id })
								} else {
									m.s.HiddenCards = append(m.s.HiddenCards, id)
								}
								a.saveSettings()
							}
						})
					}
				}
				p.hint(c, L("Drag a widget to move it. Sizes are on each widget, on its back and in the right-click menu.")).Padding(8, 6)
			})
		})
	})
}
