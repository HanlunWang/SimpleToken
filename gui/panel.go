package gui

import (
	"math"
	"slices"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
)

// panelSections names the panel's sections (Settings → Menu bar & panel).
var panelSections = [][2]string{
	{"claude", "Claude limits"}, {"codex", "Codex limits"}, {"cursor", "Cursor limits"},
	{"today", "Today"}, {"models", "Today's models"}, {"tools", "Today's tools"},
	{"week", "Last 7 days"}, {"month", "This month"},
}

// panelView is the drop-down panel under the menu bar item (designs/simpletoken-v3 Panel board): the Console
// surface, a frame per section with its title on the border.
func (a *ctrl) panelView(c *ui.Context) {
	p := a.palette(c).panelStyle()
	c.SetTheme(p.theme(c.Theme()))
	c.SetZoom(uiZoom)
	if c.Shortcut(0, ui.KeyEscape) {
		a.closePanel()
	}
	c.OnShortcut(ui.Cmd, ui.KeyR, a.refreshAll)
	c.OnShortcut(ui.Cmd, ui.KeyComma, func() { a.openWindow(true) })
	c.OnShortcut(ui.Cmd, ui.KeyO, func() { a.openWindow(false) })
	m := a.m
	bg := pick(m.s.PanelMaterial == "solid", p.BG, alpha(p.BG, 0.78))
	root := ui.Column(c.Key("panel")).FillWidth().Background(bg).Children(func() {
		a.panelHeader(c, p)
		ui.Column(c.Key("body")).FillWidth().Padding(6, 12, 12).Gap(6).Children(func() {
			if len(m.s.PanelSections) == 0 {
				ui.Column(c).FillWidth().Padding(30, 0).AlignItems(ui.Center).Children(func() {
					p.mono(c, L("Choose what to show in Settings → Menu bar & panel"), 11, p.T3)
				})
			}
			for i, s := range m.s.PanelSections {
				e := ui.Column(c.Key(s)).FillWidth()
				if k := enterOnce(e, 260*time.Millisecond, time.Duration(i)*30*time.Millisecond); k < 1 {
					e.Opacity(k).Translate(0, (1-k)*6)
				}
				e.Children(func() {
					switch s {
					case "claude", "codex", "cursor":
						a.panelLimits(c, p, limits.Provider(s))
					case "today":
						a.panelToday(c, p)
					case "models":
						a.panelRows(c, p, true)
					case "tools":
						a.panelRows(c, p, false)
					case "week":
						a.panelWeek(c, p)
					case "month":
						a.panelMonth(c, p)
					}
				})
			}
		})
		ui.Box(c).FillWidth().Height(1).Background(p.L2)
		ui.Row(c.Key("foot")).FillWidth().Padding(6, 8).Justify(ui.SpaceBetween).AlignItems(ui.Center).Children(func() {
			if p.button(c, "open", L("Open SimpleToken")+"  ⌘O", "", btnGhost).Clicked() {
				a.openWindow(false)
			}
			if p.button(c, "quit", L("Quit")+"  ⌘Q", "", btnGhost).Clicked() && a.running {
				mygo.App.Quit()
			}
		})
	})
	// Size the flyout to the content (it opens with the last measured height).
	if h := root.Bounds().H; h > 0 && a.panelResize != nil {
		a.panelResize(h * uiZoom) // content DIPs → window points
	}
}

func (a *ctrl) panelHeader(c *ui.Context, p palette) {
	m := a.m
	ui.Row(c.Key("head")).FillWidth().Padding(12, 8, 4, 16).Gap(8).AlignItems(ui.Center).Children(func() {
		p.brand(c, 12.5, false)
		now := m.now()
		p.mono(c, upper(fmtr.Weekday(now)+" "+itoa(now.Day())+" "+fmtr.MonthName(now)), 10.5, p.T3).Shrink(0)
		ui.Box(c).Grow(1)
		b := ui.Row(c.Key("refresh")).Height(24).Padding(0, 7).Radius(p.rCtl()).Gap(6).AlignItems(ui.Center).Label(L("Refresh")).Tooltip(L("Refresh") + " ⌘R")
		b.Background(b.AnimateColor("bg", pick(b.Hovered(), p.L2, ui.Transparent), animHover))
		b.Children(func() {
			if m.d.Refreshing {
				p.dotRun(c, 9)
				p.mono(c, L("Refreshing"), 11, p.T2)
			} else {
				icon(c, "rotate-cw", 12).TextColor(p.T2)
				label := fmtr.PanelUpdated(m.d.UpdatedAt, now)
				if !m.d.Collected {
					label = L("Not collected yet")
				}
				p.mono(c, label, 11, p.T2)
			}
		})
		if b.Clicked() {
			a.refreshAll()
		}
		if p.iconBtn(c, "win", "app-window", L("Open main window")+" ⌘O", false).Clicked() {
			a.openWindow(false)
		}
		if p.iconBtn(c, "set", "sliders-horizontal", L("Settings"), false).Clicked() {
			a.openWindow(true)
		}
	})
}

// panelFrame is a Console section (theme.css .st-frame): a hairline box with its "// TITLE" on the top border
// and a trail at the right of it.
func (p palette) panelFrame(c *ui.Context, key, title string, acc ui.Color, trail func(), body func()) {
	ui.Column(c.Key(key)).FillWidth().Margin(8, 0, 0).Children(func() {
		ui.Column(c.Key("box")).FillWidth().Padding(14, 12, 12).Gap(6).Radius(8).Border(1, p.L2).Children(body)
		ui.Row(c.Key("t")).Absolute().Left(10).Top(-7).Padding(0, 6).Background(p.BG).Children(func() {
			p.captionAcc(c, title, acc)
		})
		if trail != nil {
			ui.Row(c.Key("tr")).Absolute().Right(10).Top(-8).Padding(0, 6).Background(p.BG).AlignItems(ui.Center).Children(trail)
		}
	})
}

// windowLabel names a limit window.
func windowLabel(w limits.Window) string {
	switch w.Kind {
	case limits.Session:
		return L("Session")
	case limits.Weekly:
		return L("Weekly")
	case limits.Fable:
		return "Fable"
	}
	return w.Title
}

func (a *ctrl) panelLimits(c *ui.Context, p palette, prov limits.Provider) {
	m := a.m
	var e limits.Entry
	for _, x := range m.d.Limits {
		if x.Provider == prov {
			e = x
		}
	}
	items, _ := a.limitItems(p)
	items = slices.DeleteFunc(items, func(it limitItem) bool { return it.prov != prov })
	var hot *limitItem
	for i := range items {
		if items[i].spec.Hot && hot == nil {
			hot = &items[i]
		}
	}
	trail := func() {
		switch {
		case hot != nil:
			p.badge(c, "! "+L("%@ over %@", limitName(*hot, false), itoa(int(m.s.TopThreshold()))+"%"), "red")
		default:
			txt := a.statusText(e)
			if e.Snapshot != nil && e.Snapshot.AccountLabel != "" {
				txt = e.Snapshot.AccountLabel + " · " + txt
			}
			p.mono(c, txt, 11, p.T4)
		}
	}
	p.panelFrame(c, string(prov), prov.DisplayName(), p.Sig, trail, func() {
		if len(items) == 0 {
			p.mono(c, a.statusText(e), 11, p.T3)
			return
		}
		if m.s.PanelLimitStyle != "gauges" {
			for i, it := range items {
				a.limitRow(c, p, i, it, 30)
			}
			return
		}
		// Over the threshold and on course to run out before the reset: when, at this pace.
		runOut, before := "", ""
		if hot != nil {
			if at, ok := runsOut(hot.w, m.now()); ok {
				runOut, before = format.Clock(at), fmtr.ShortCountdown(hot.w.ResetsAt.Sub(at))
			}
		}
		shown := items[:min(pick(runOut != "", 2, 3), len(items))]
		ui.Row(c.Key("g")).FillWidth().Gap(4).Children(func() {
			for i, it := range shown {
				ui.Column(c.Key(i)).Grow(1).Basis(0).AlignItems(ui.Center).Children(func() {
					s := it.spec
					s.Stroke, s.Num, s.Ground = 3, 25, p.BG
					p.gauge(c, "g", s, 92)
					ui.Row(c.Key("n")).Gap(4).AlignItems(ui.Center).Margin(-6, 0, 0).Children(func() {
						ui.Text(c, limitName(it, false)).FontSize(11.5).FontWeight(500).TextColor(p.T1).SingleLine()
						if it.proj >= 0 {
							p.mono(c, "→"+itoa(int(math.Round(it.proj)))+"%", 10.5, p.T2)
						}
					})
					if m.s.PanelShowResets && it.reset != "" {
						p.mono(c, pick(it.spec.Hot, "! ", "")+it.reset, 10, pick(it.spec.Hot, p.Red, p.T3))
					}
				})
			}
			for i := len(shown); i < 3 && runOut == ""; i++ {
				ui.Box(c.Key(i)).Grow(1).Basis(0)
			}
			if runOut != "" {
				ui.Column(c.Key("out")).Grow(1).Basis(0).Justify(ui.Center).Gap(6).Padding(0, 0, 0, 6).Children(func() {
					ui.Box(c).Absolute().Left(0).Top(0).Width(1).FillHeight().Background(p.L2)
					p.mono(c, L("RUNS OUT"), 10, p.T3).LetterSpacing(0.6)
					p.mono(c, "≈ "+runOut, 15, p.Red)
					ui.Text(c, L("%@ before the %@ reset", before, lowerFirst(limitName(*hot, false)))).FontSize(10.5).TextColor(p.T3).Wrap()
				})
			}
		})
	})
}

// statusText is a provider's status line: refreshing, unreachable, not set up, or its age.
func (a *ctrl) statusText(e limits.Entry) string {
	switch e.Status.State {
	case limits.StateRefreshing:
		return L("Refreshing")
	case limits.StateNotConfigured:
		switch e.Provider {
		case limits.Claude:
			return L("Paste your claude.ai key in Settings")
		case limits.Codex:
			return L("Sign in to Codex")
		case limits.Cursor:
			return L("Sign in to the Cursor app")
		}
		return L("Not set up")
	case limits.StateFailed:
		if e.Snapshot == nil {
			return L("Unreachable") + " · " + e.Status.Reason
		}
	}
	if e.Snapshot != nil {
		return fmtr.Ago(e.Snapshot.UpdatedAt, a.m.now())
	}
	return L("Reading limits…")
}

func (a *ctrl) panelToday(c *ui.Context, p palette) {
	m := a.m
	t := m.today()
	now := m.now()
	slot := now.Hour()*2 + now.Minute()/30
	// Yesterday up to this time, from the half-hour shape (Claude Code) scaled to yesterday's total.
	var yTotal float64
	if days := m.days(2); len(days) == 2 {
		share, all := 0.0, 0.0
		for i, v := range m.yesterdayHalf() {
			all += v
			if i <= slot {
				share += v
			}
		}
		if all > 0 {
			yTotal = float64(days[0].Tokens) * share / all
		}
	}
	r := a.ramp(p, "stat.average")
	trail := func() { p.mono(c, L("since 00:00"), 11, p.T4) }
	p.panelFrame(c, "today", L("Today"), a.accent(p, "stat.average"), trail, func() {
		if t.TotalTokens == 0 {
			p.mono(c, L("No usage yet today"), 11, p.T3)
			return
		}
		ui.Row(c.Key("n")).FillWidth().Gap(12).AlignItems(ui.End).Children(func() {
			bigText(c.Key("tok"), m.num(float64(t.TotalTokens)), pick(m.s.ExactNumbers, float32(22), 32), p.T1)
			ui.Column(c.Key("d")).Gap(3).Padding(0, 0, 2).Children(func() {
				p.mono(c, format.Money(t.CostUSD), 12, p.T1)
				if d := deltaText(float64(t.TotalTokens), yTotal); d != "" {
					p.mono(c, d+" "+L("vs %@ at %@", fmtr.Weekday(now.AddDate(0, 0, -1)), format.Clock(now)), 10.5, p.T3)
				}
			})
		})
		half := m.todayHalf()
		ui.Box(c.Key("half")).FillWidth().Height(40).Margin(4, 0, 0).Draw(func(pt *ui.Painter, rr ui.Rect) {
			const gap = 1.5
			bw := (rr.W - 47*gap) / 48
			mx := 1e-9
			for _, v := range half {
				mx = math.Max(mx, v)
			}
			for i := range 48 {
				x := rr.X + float32(i)*(bw+gap)
				v := 0.0
				if i < len(half) {
					v = half[i]
				}
				switch {
				case i > slot:
					pt.Stroke(ui.Rect{X: x, Y: rr.Y + rr.H - 6, W: bw, H: 6}, p.L3, 1, 1)
				case v/mx <= 0.02:
					pt.Fill(ui.Rect{X: x, Y: rr.Y + rr.H - 2, W: bw, H: 2}, p.L3, 1)
				default:
					f := v / mx
					h := max(rr.H*0.08, float32(f)*rr.H)
					bar := ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}
					if i == slot {
						pt.Shadow(bar, 1, 0, 0, 6, 0, p.glow())
						pt.Fill(bar, p.Sig, 1)
						continue
					}
					pt.Fill(bar, pick(f > 0.66, r[3], pick(f > 0.33, r[2], r[1])), 1)
				}
			}
			nx := rr.X + (float32(slot)+float32(now.Minute()%30)/30)*(bw+gap)
			pt.Line(nx, rr.Y-6, nx, rr.Y+rr.H+2, 1, p.sigLine())
		})
		ui.Row(c.Key("axis")).FillWidth().Justify(ui.SpaceBetween).Margin(-2, 0, 0).Children(func() {
			for _, s := range []string{"00", "06", "12", "18", "24"} {
				p.mono(c, s, 9.5, p.T4)
			}
		})
	})
}

func (a *ctrl) panelRows(c *ui.Context, p palette, models bool) {
	m := a.m
	t := m.today()
	src := map[string]int64{}
	if models {
		for k, s := range t.ByModel {
			src[k] = s.Tokens
		}
	} else {
		for k, s := range t.ByClient {
			src[k] = s.Tokens
		}
	}
	keys := sortedKeys(src)
	title := pick(models, L("Today's models"), L("Today's tools"))
	trail := func() { p.mono(c, itoa(len(keys)), 11, p.T4) }
	col := func(k string) ui.Color { return pick(models, m.modelColor(p, k), m.toolColor(p, k)) }
	p.panelFrame(c, pick(models, "models", "tools"), title, p.Sig, trail, func() {
		if len(keys) == 0 {
			p.mono(c, L("No usage yet today"), 11, p.T3)
			return
		}
		top := float64(src[keys[0]])
		n := len(keys)
		if m.s.PanelListCount > 0 {
			n = min(n, m.s.PanelListCount)
		}
		ui.Column(c.Key("rows")).FillWidth().Margin(-4, 0, -4).Children(func() {
			for _, k := range keys[:n] {
				v := float64(src[k])
				ui.Row(c.Key(k)).FillWidth().Height(28).Gap(10).AlignItems(ui.Center).Children(func() {
					if models {
						a.modelLabel(c, p, k, 11.5, p.T1).Width(118)
					} else {
						ui.Row(c.Key("n")).Width(118).Gap(6).AlignItems(ui.Center).Children(func() {
							logo(c, vendorLogo(k), 12, col(k))
							ui.Text(c, toolName(k)).FontSize(12).TextColor(p.T1).SingleLine().MinWidth(0).Ellipsis("…")
						})
					}
					ui.Box(c.Key("b")).Grow(1).Height(4).Radius(2).Background(p.L2).Draw(func(pt *ui.Painter, rr ui.Rect) {
						pt.Fill(ui.Rect{X: rr.X, Y: rr.Y, W: rr.W * float32(v/top), H: rr.H}, col(k), 2)
					})
					ui.Text(c, shortNum(v)).Font(monoFont).FontSize(11.5).TextColor(p.T1).SingleLine().Width(48).TextAlign(ui.End)
				})
			}
		})
	})
}

func (a *ctrl) panelWeek(c *ui.Context, p palette) {
	m := a.m
	days := m.days(7)
	sum, cost := 0.0, 0.0
	vals := make([]float64, len(days))
	for i, d := range days {
		vals[i] = float64(d.Tokens)
		sum += vals[i]
		cost += d.Cost
	}
	r := a.ramp(p, "stat.average")
	trail := func() { p.mono(c, shortNum(sum)+" · "+format.Money(cost), 11, p.T4) }
	p.panelFrame(c, "week", L("Last 7 days"), p.Sig, trail, func() {
		mx := 1e-9
		for _, v := range vals {
			mx = math.Max(mx, v)
		}
		ui.Box(c.Key("bars")).FillWidth().Height(54).Draw(func(pt *ui.Painter, rr ui.Rect) {
			const gap = 8
			bw := (rr.W - float32(len(vals)-1)*gap) / float32(max(1, len(vals)))
			for i, v := range vals {
				x := rr.X + float32(i)*(bw+gap)
				switch {
				case i == len(vals)-1:
					h := max(2, float32(v/mx)*rr.H)
					bar := ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}
					pt.Shadow(bar, 2, 0, 0, 6, 0, p.glow())
					pt.Fill(bar, p.Sig, 2)
				case v <= 0:
					pt.Fill(ui.Rect{X: x, Y: rr.Y + rr.H - 2, W: bw, H: 2}, p.L3, 1)
				default:
					h := float32(v/mx) * rr.H
					pt.Fill(ui.Rect{X: x, Y: rr.Y + rr.H - h, W: bw, H: h}, r[1], 2)
				}
			}
		})
		ui.Row(c.Key("wd")).FillWidth().Gap(8).Children(func() {
			for i, d := range days {
				t, _ := format.DateFromKey(d.Date)
				ui.Text(c.Key(i), fmtr.Weekday(t)).Font(monoFont).FontSize(9.5).TextColor(pick(i == len(days)-1, p.T1, p.T3)).
					Grow(1).Basis(0).TextAlign(ui.Center).SingleLine()
			}
		})
	})
}

func (a *ctrl) panelMonth(c *ui.Context, p palette) {
	mc := a.m.monthCost()
	spent := 0.0
	if n := len(mc.Days); n > 0 {
		spent = mc.Days[n-1].Cumulative
	}
	r := a.ramp(p, "cost")
	trail := func() { p.mono(c, L("Last month %@", format.Money(mc.LastMonthTotal)), 11, p.T4) }
	p.panelFrame(c, "month", L("This month"), a.accent(p, "cost"), trail, func() {
		ui.Row(c.Key("n")).FillWidth().Gap(12).AlignItems(ui.End).Children(func() {
			bigText(c.Key("spent"), format.Money(spent), 28, p.T1)
			p.mono(c, L("proj. %@", format.Money(mc.Projected)), 11, p.T3).Padding(0, 0, 3)
		})
		vals := make([]float64, max(mc.DaysInMonth, len(mc.Days)))
		for i, d := range mc.Days {
			vals[i] = d.Cost
		}
		p.miniBars(c, "bars", vals, 30, func(i int, _ float64) ui.Color { return pick(i == len(mc.Days)-1, r[3], r[1]) })
	})
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(min(n, 99))
}

func upper(s string) string {
	b := []rune(s)
	for i, r := range b {
		if r >= 'a' && r <= 'z' {
			b[i] = r - 32
		}
	}
	return string(b)
}
