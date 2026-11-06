package gui

import (
	"slices"
	"strings"
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
	search        string // the widget drawer's search
	firstRow      bool   // the settings row being built is its group's first (no hairline above it)
	bitmaps       map[string]*ui.Bitmap
}

// narrow is a window too small for the top bar's pickers (they move to a row of their own).
func (w *winState) narrow() bool { return w.winW > 0 && w.winW < 860 }

// bitmap decodes a PNG once per window (menu bar previews redraw every frame); at most 32 are kept.
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

// The grid (designs/simpletoken-v3 Widgets board): rows of 184, 12 apart; columns of at least 290, so a 1440 window
// holds four.
const (
	cellH   = 184
	cellGap = 12
	minColW = 290
)

// windowView is the main window: a top bar over the dashboard or the settings page.
func (a *ctrl) windowView(c *ui.Context) {
	p := a.palette(c)
	c.SetTheme(p.theme(c.Theme()))
	c.SetZoom(uiZoom)
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
	if w.editing && c.Shortcut(0, ui.KeyEnter) {
		w.editing, w.flipped = false, ""
	}
	root := ui.Column(c.Key("root")).Fill().Background(p.BG)
	if b := root.Bounds(); b.W > 0 {
		w.winW = b.W
	}
	root.Children(func() {
		a.topBar(c, p)
		if !w.settings && !w.editing && w.narrow() {
			ui.Row(c.Key("pickers")).FillWidth().Padding(8, 16).Gap(10).Justify(ui.Center).Shrink(0).Children(func() {
				a.rangePicker(c, p)
				a.metricPicker(c, p)
			})
		}
		if w.settings {
			ui.Column(c.Key("settings")).Grow(1).FillWidth().MinHeight(0).
				Transition(ui.ElementTransition{Duration: 200 * time.Millisecond, Enter: &ui.Motion{X: 16}}).
				Children(func() { a.settingsPage(c, p) })
			return
		}
		if a.needsOnboarding() {
			a.onboarding(c, p)
			return
		}
		ui.Row(c.Key("dash")).Grow(1).FillWidth().MinHeight(0).Children(func() {
			ui.Scroll(c.Key("scroll")).Grow(1).FillHeight().Children(func() {
				ui.Column(c.Key("pad")).FillWidth().Padding(18, 20, 28).Children(func() {
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
	bar := ui.Row(c.Key("top")).FillWidth().Height(52).Padding(0, 16, 0, 84).Gap(14).AlignItems(ui.Center).Shrink(0).DragWindow()
	bar.Background(p.BG)
	bar.Children(func() {
		ui.Box(c).Absolute().Left(0).Bottom(0).FillWidth().Height(1).Background(p.L2)
		if w.settings {
			if p.button(c, "back", L("Dashboard"), "chevron-left", btnGhost).Clicked() {
				w.settings = false
			}
		}
		ui.Row(c.Key("crumbs")).Gap(8).AlignItems(ui.Center).Shrink(0).Children(func() {
			p.brand(c, 12.5, m.d.Refreshing && time.Since(w.manualRefresh) < 5*time.Second)
			p.mono(c, "/", 12.5, p.T4)
			switch {
			case w.settings:
				p.mono(c, L("settings"), 12.5, p.T2)
			case w.editing:
				p.mono(c, L("edit widgets"), 12.5, p.T2)
			default:
				p.mono(c, L("usage"), 12.5, p.T2)
			}
		})
		if w.editing {
			p.badge(c, L("EDITING"), "sig")
		}
		ui.Box(c).Grow(1)
		switch {
		case w.settings:
		case w.editing:
			if !w.narrow() {
				ui.Text(c, L("Drag to reorder · pick a size · flip a card for its options")).FontSize(11).TextColor(p.T3).SingleLine()
			}
			if p.button(c, "reset", L("Reset layout"), "", btnGhost).Clicked() {
				d := settings.Default()
				m.s.CardOrder, m.s.HiddenCards, m.s.CardSizes = d.CardOrder, d.HiddenCards, d.CardSizes
				a.saveSettings()
			}
			if p.button(c, "done", L("Done")+"  ↩", "", btnPrimary).Clicked() {
				w.editing, w.flipped = false, ""
			}
		default:
			if !w.narrow() {
				a.rangePicker(c, p)
				a.metricPicker(c, p)
			}
			ui.Row(c.Key("tools")).Gap(2).AlignItems(ui.Center).Shrink(0).Children(func() {
				a.refreshControl(c, p)
				if p.iconBtn(c, "edit", "layout-grid", L("Edit widgets"), false).Clicked() {
					w.editing, w.flipped = true, ""
				}
				if p.iconBtn(c, "settings", "sliders-horizontal", L("Settings")+" ⌘,", false).Clicked() {
					w.settings = true
				}
			})
		}
	})
}

// rangeChoices are the top bar's ranges (the v3 set); 6M and YTD stay valid values for settings written before.
var rangeChoices = [][2]string{{"1D", "Today"}, {"1W", "7D"}, {"1M", "30D"}, {"3M", "90D"}, {"1Y", "1Y"}, {"ALL", "All"}}

// rangePicker is the Today … All segmented control.
func (a *ctrl) rangePicker(c *ui.Context, p palette) {
	m := a.m
	labels := make([]string, len(rangeChoices))
	sel := -1
	for i, r := range rangeChoices {
		labels[i] = L(r[1])
		if r[0] == m.s.Range {
			sel = i
		}
	}
	if n := p.segmented(c, "range", sel, labels...); n != sel && n >= 0 {
		m.s.Range = rangeChoices[n][0]
		a.w.usageDay = ""
		a.saveSettings()
	}
}

// metricPicker switches the dashboard between tokens and cost.
func (a *ctrl) metricPicker(c *ui.Context, p palette) {
	m := a.m
	v := pick(m.s.Metric == "cost", "cost", "tokens")
	if p.segValue(c, "metric", &v, [][2]string{{"tokens", L("Tokens")}, {"cost", L("Cost")}}) {
		m.s.Metric = v
		a.saveSettings()
	}
}

// refreshControl shows the last update beside the refresh button; only a manual refresh animates it (background
// ticks never do).
func (a *ctrl) refreshControl(c *ui.Context, p palette) {
	m := a.m
	now := m.now()
	label := fmtr.Updated(m.d.UpdatedAt, now)
	if !m.d.Collected {
		label = L("Not collected yet")
	}
	manual := m.d.Refreshing && time.Since(a.w.manualRefresh) < 2*time.Minute
	if !a.w.narrow() {
		p.mono(c, pick(manual, L("Refreshing"), label), 11, p.T3).Padding(0, 6, 0, 0)
	}
	b := ui.Row(c.Key("refresh")).Size(26, 26).Radius(5).AlignItems(ui.Center).Justify(ui.Center).Shrink(0).
		Label(L("Refresh")).Tooltip(L("Refresh") + " ⌘R · " + L("Today's usage refresh") + " " + fmtr.Seconds(m.s.LiveRefreshSeconds))
	b.Background(b.AnimateColor("bg", pick(b.Hovered(), p.L2, ui.Transparent), animHover))
	pressPose(b, 0.92)
	b.Children(func() {
		if manual {
			p.dotRun(c, 10)
		} else {
			icon(c, "rotate-cw", 14).TextColor(pick(b.Hovered(), p.T1, p.T2))
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
		if m.d.LegacyMerged {
			p.mono(c, "·", 10.5, p.T4)
			p.mono(c, L("Token Monitor history merged"), 10.5, p.T4)
		}
		if n := len(m.s.ExcludedModels) + len(m.s.ExcludedClients); n > 0 {
			p.mono(c, "·", 10.5, p.T4)
			p.mono(c, L("%lld excluded", n), 10.5, p.T4)
		}
		if hidden > 0 && !w.editing {
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

// pack places cards dense first-fit in a grid of n columns. A wide card (4 × 1) becomes large (2 × 2) below four
// columns.
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
		if size == sizeW && n < 4 {
			size = pick(slices.Contains(cardDefs[id].Sizes, sizeL), sizeL, sizeM)
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
	// Even counts only: M, L and W (2 and 4 wide) tile without holes, so 5 columns become 4.
	return max(2, min(8, n&^1))
}

func (a *ctrl) dashboard(c *ui.Context, p palette) {
	m, w := a.m, a.w
	rep := m.current()
	grid := ui.Box(c.Key("grid")).FillWidth()
	if b := grid.Bounds(); b.W > 0 {
		w.gridW = b.W
	}
	if w.gridW == 0 {
		w.gridW = 1200
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

// cardShell is a widget's frame (theme.css .w): the card ground, one hairline, a header with the caption (its
// square in the card's accent) and a note, and the body 14 below. In edit mode the header holds a grip, the sizes
// and a remove button, and the card can be dragged onto another to take its place; flipped, it shows its options.
func (a *ctrl) cardShell(c *ui.Context, p palette, card ui.Element, pl placed, rep analytics.Report) {
	w := a.w
	def := cardDefs[pl.id]
	flipped := w.flipped == pl.id
	hover := card.Hovered()
	border := pick(hover, p.L3, p.L2)
	if w.editing {
		border = p.L3
		card.Drag(pl.id)
		if id, over := ui.DragOver[string](card); over && id != pl.id {
			border = p.sigLine()
			card.Shadow(0, 0, 14, 0, p.glowSoft())
		}
		if id, ok := ui.Drop[string](card); ok && id != pl.id {
			a.moveCard(id, pl.id)
		}
		if card.Dragging() {
			card.Opacity(0.4)
		}
	}
	if flipped {
		border = p.L4
		card.Background(p.Elev)
	}
	card.Border(1, card.AnimateColor("bd", border, animHover))
	card.ContextMenu(a.cardMenu(pl))
	acc := a.accent(p, pl.id)
	card.Children(func() {
		ui.Column(c.Key("in")).Fill().Padding(14, 16, 16).Children(func() {
			ui.Row(c.Key("head")).FillWidth().Height(18).Gap(8).AlignItems(ui.Center).Shrink(0).Children(func() {
				if w.editing && !flipped {
					grip(c, p)
				}
				p.captionAcc(c, L(def.Title)+pick(flipped, " · "+L("options"), ""), pick(cardAccented(pl.id), acc, p.Sig))
				ui.Box(c).Grow(1).MinWidth(0)
				switch {
				case flipped:
					if p.button(c, "flip", L("Flip back"), "", btnGhost).Height(24).Clicked() {
						w.flipped = ""
					}
				case w.editing:
					for _, s := range def.Sizes {
						if p.chip(c, "size"+string(s), string(s), s == pl.size).Tooltip(sizeName(s)).Clicked() {
							a.setCardSize(pl.id, s)
						}
					}
					if p.iconBtn(c, "opts", "sliders-horizontal", L("%@ options", L(def.Title)), false).Size(22, 22).Clicked() {
						w.flipped = pl.id
					}
					rm := ui.Row(c.Key("rm")).Size(22, 22).Radius(5).Background(p.L2).AlignItems(ui.Center).Justify(ui.Center).
						Label(L("Remove %@", L(def.Title))).Tooltip(L("Remove"))
					rm.Children(func() { icon(c, "x", 12).TextColor(pick(rm.Hovered(), p.T1, p.T2)) })
					pressPose(rm, 0.92)
					if rm.Clicked() {
						a.hideCard(pl.id)
					}
				case hover:
					if note := a.cardNote(pl.id, rep); note != "" {
						p.note(c, note).MinWidth(0).Ellipsis("…")
					}
					if p.iconBtn(c, "opts", "sliders-horizontal", L("%@ options", L(def.Title)), false).Size(22, 22).Clicked() {
						w.flipped = pl.id
					}
				default:
					if note := a.cardNote(pl.id, rep); note != "" {
						p.note(c, note).MinWidth(0).Ellipsis("…")
					}
				}
			})
			body := ui.Column(c.Key(pick(flipped, "back", "front"))).FillWidth().Grow(1).MinHeight(0).Margin(14, 0, 0)
			if flipped {
				body.Transition(ui.ElementTransition{Duration: 260 * time.Millisecond, Enter: &ui.Motion{Scale: 0.97}})
				body.Children(func() { a.cardBack(c, p, pl) })
			} else {
				body.Children(func() { a.cardFront(c, p, pl, rep) })
			}
		})
	})
}

// grip is the drag handle: two columns of three dots.
func grip(c *ui.Context, p palette) {
	ui.Box(c.Key("grip")).Size(12, 14).Shrink(0).Draw(func(pt *ui.Painter, r ui.Rect) {
		for i := range 6 {
			d := ui.Rect{X: r.X + 3 + float32(i%2)*5, Y: r.Y + 2 + float32(i/2)*5, W: 3, H: 3}
			pt.Fill(d, p.T3, 1.5)
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

func sizeName(s cardSize) string {
	switch s {
	case sizeS:
		return L("Small · 1×1")
	case sizeM:
		return L("Medium · 2×1")
	case sizeL:
		return L("Large · 2×2")
	}
	return L("Wide · 4×1")
}

func (a *ctrl) cardMenu(pl placed) func(m *ui.Menu) {
	return func(m *ui.Menu) {
		for _, s := range cardDefs[pl.id].Sizes {
			if m.Item(sizeName(s)).Checked(s == pl.size).Chosen() {
				a.setCardSize(pl.id, s)
			}
		}
		m.Separator()
		if m.Item(L("Options…")).Chosen() {
			a.w.flipped = pl.id
		}
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

func (a *ctrl) showCard(id string) {
	a.m.s.HiddenCards = slices.DeleteFunc(a.m.s.HiddenCards, func(x string) bool { return x == id })
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

// widgetDrawer is edit mode's side panel: the hidden widgets to add (searchable), then what is on the dashboard.
func (a *ctrl) widgetDrawer(c *ui.Context, p palette) {
	m, w := a.m, a.w
	var hidden, shown []string
	for _, id := range m.s.CardOrder {
		if _, ok := cardDefs[id]; !ok {
			continue
		}
		if slices.Contains(m.s.HiddenCards, id) {
			hidden = append(hidden, id)
		} else {
			shown = append(shown, id)
		}
	}
	q := strings.ToLower(strings.TrimSpace(w.search))
	match := func(id string) bool { return q == "" || strings.Contains(strings.ToLower(L(cardDefs[id].Title)), q) }
	ui.Column(c.Key("drawer")).Width(320).FillHeight().Background(p.BG2).Shrink(0).Padding(18, 16).Gap(14).
		Transition(ui.ElementTransition{Duration: 220 * time.Millisecond, Enter: &ui.Motion{X: 20}, Exit: &ui.Motion{X: 20}}).Children(func() {
		ui.Box(c).Absolute().Left(0).Top(0).Width(1).FillHeight().Background(p.L2)
		ui.Row(c.Key("h")).FillWidth().AlignItems(ui.Center).Children(func() {
			p.caption(c, L("Add widgets"))
			ui.Box(c).Grow(1)
			p.mono(c, L("%lld hidden", len(hidden)), 11, p.T4)
		})
		ui.Row(c.Key("search")).FillWidth().Height(28).Padding(0, 10).Gap(8).Radius(4).Border(1, p.L3).Background(p.Surf).
			AlignItems(ui.Center).Children(func() {
			icon(c, "search", 13).TextColor(p.T3)
			ui.TextInput(c.Key("q"), &w.search).Placeholder(L("Search widgets")).Grow(1).FontSize(12).Background(ui.Transparent).Border(0, ui.Transparent)
		})
		ui.Scroll(c.Key("list")).Grow(1).FillWidth().Children(func() {
			ui.Column(c).FillWidth().Children(func() {
				p.mono(c, L("HIDDEN"), 10, p.T3).LetterSpacing(0.8).Padding(4, 0, 8)
				any := false
				for _, id := range hidden {
					if !match(id) {
						continue
					}
					any = true
					def := cardDefs[id]
					ui.Row(c.Key("h" + id)).FillWidth().Height(46).Gap(10).AlignItems(ui.Center).Children(func() {
						ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
						p.tile(c, "", cardIcon(id), pick(cardAccented(id), a.accent(p, id), p.T2))
						ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
							ui.Text(c, L(def.Title)).FontSize(12.5).FontWeight(500).TextColor(p.T1).SingleLine()
							sizes := make([]string, len(def.Sizes))
							for i, s := range def.Sizes {
								sizes[i] = string(s)
							}
							p.mono(c, strings.Join(sizes, " · "), 10.5, p.T3)
						})
						if p.iconBtn(c, "add", "plus", L("Add %@", L(def.Title)), false).Clicked() {
							a.showCard(id)
						}
					})
				}
				if !any {
					p.hint(c, pick(len(hidden) == 0, L("Every widget is on the dashboard."), L("No widget matches."))).Padding(0, 0, 8)
				}
				p.mono(c, L("ON THE DASHBOARD"), 10, p.T3).LetterSpacing(0.8).Padding(18, 0, 8)
				for _, id := range shown {
					if !match(id) {
						continue
					}
					ui.Row(c.Key("s" + id)).FillWidth().Height(30).Gap(10).AlignItems(ui.Center).Children(func() {
						ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
						swatch(c, pick(cardAccented(id), a.accent(p, id), p.Ink[1]), 7)
						ui.Text(c, L(cardDefs[id].Title)).FontSize(12).TextColor(p.T2).Grow(1).SingleLine()
						p.mono(c, string(a.cardSize(id)), 10.5, p.T3)
					})
				}
			})
		})
	})
}

// cardIcon is a widget's icon in the drawer.
func cardIcon(id string) string {
	switch id {
	case "stat.totalCost", "cost":
		return "dollar-sign"
	case "stat.messages":
		return "message-square"
	case "stat.topModel":
		return "trophy"
	case "stat.weekday", "calendar":
		return "calendar"
	case "stat.average", "usage":
		return "chart-column"
	case "stat.peak":
		return "trending-up"
	case "stat.active":
		return "grid-3x3"
	case "stat.perMillion":
		return "percent"
	case "limits":
		return "gauge"
	case "models":
		return "boxes"
	case "map":
		return "layout-dashboard"
	case "flow":
		return "git-merge"
	case "punchcard":
		return "clock"
	case "tools":
		return "wrench"
	case "composition":
		return "layers"
	}
	return "chart-line"
}
