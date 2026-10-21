package gui

import (
	"math"
	"slices"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
)

// panelSections names the panel's sections (Settings → Panel).
var panelSections = [][2]string{
	{"claude", "Claude limits"}, {"codex", "Codex limits"}, {"cursor", "Cursor limits"},
	{"today", "Today: usage and trend"}, {"models", "Today's models"}, {"tools", "Today's tools"},
	{"week", "Last 7 days"}, {"month", "This month's cost"},
}

// panelView is the drop-down panel under the menu bar item.
func (a *ctrl) panelView(c *ui.Context) {
	p := a.palette().panelStyle()
	c.SetTheme(p.theme(c.Theme()))
	if c.Shortcut(0, ui.KeyEscape) {
		a.closePanel()
	}
	c.OnShortcut(ui.Cmd, ui.KeyR, a.refreshAll)
	c.OnShortcut(ui.Cmd, ui.KeyComma, func() { a.openWindow(true) })
	m := a.m
	bg := pick(m.s.PanelMaterial == "solid", p.BG, alpha(p.BG, 0.72))
	root := ui.Column(c.Key("panel")).FillWidth().Background(bg).Padding(0, 10, 12).Children(func() {
		a.panelHeader(c, p)
		if len(m.s.PanelSections) == 0 {
			ui.Column(c).FillWidth().Padding(30, 0).AlignItems(ui.Center).Gap(10).Children(func() {
				p.mono(c, L("Choose what to show in Settings → Panel"), 11, p.T3)
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
	// Size the flyout to the content (it opens with the last measured height).
	if h := root.Bounds().H; h > 0 && a.panelResize != nil {
		a.panelResize(h)
	}
}

func (a *ctrl) panelHeader(c *ui.Context, p palette) {
	m := a.m
	ui.Row(c.Key("head")).FillWidth().Padding(13, 0, 4, 6).Gap(8).AlignItems(ui.Center).Children(func() {
		p.brand(c, 12.5, false)
		now := m.now()
		p.mono(c, upper(itoa(now.Day())+" "+format.MonthName(now)), 10.5, p.T3).Shrink(0)
		ui.Box(c).Grow(1)
		label := fmtr.PanelUpdated(m.d.UpdatedAt, now)
		if !m.d.Collected {
			label = L("Not collected yet")
		}
		if m.d.Refreshing {
			label = L("Refreshing")
		}
		b := ui.Row(c.Key("refresh")).Height(24).Padding(0, 8).Radius(p.rCtl()).Gap(6).AlignItems(ui.Center).Label(L("Refresh")).Tooltip(L("Refresh") + " ⌘R")
		b.Background(b.AnimateColor("bg", pick(b.Hovered(), p.L2, ui.Transparent), animHover))
		b.Children(func() {
			if m.d.Refreshing {
				p.dotRun(c, 10)
			} else {
				icon(c, "rotate-cw", 12).TextColor(p.T2)
			}
			p.mono(c, label, 10.5, p.T2)
		})
		if b.Clicked() {
			a.refreshAll()
		}
		if p.iconBtn(c, "win", "app-window", L("Open Main Window"), false).Clicked() {
			a.openWindow(false)
		}
		if p.iconBtn(c, "set", "settings-2", L("Settings"), false).Clicked() {
			a.openWindow(true)
		}
	})
}

// panelFrame is a Console section: a faint box with a "// TITLE ---- right" header row.
func (p palette) panelFrame(c *ui.Context, key, title string, right func(), body func()) {
	ui.Column(c.Key(key)).FillWidth().Margin(8, 0, 0).Padding(0, 12, 11).Radius(p.rCard()).Border(1, p.L2).Background(p.L1).Children(func() {
		ui.Row(c.Key("h")).FillWidth().Height(30).Gap(8).AlignItems(ui.Center).Children(func() {
			p.caption(c, title)
			ui.Box(c).Grow(1).Height(1).Draw(func(pt *ui.Painter, r ui.Rect) { dashH(pt, r.X, r.X+r.W, r.Y, p.L2, 3, 3) })
			if right != nil {
				right()
			}
		})
		body()
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

func (a *ctrl) limitView(w limits.Window) (used, pace float64, hot bool, reset string) {
	now := a.m.now()
	used = w.UsedPercent
	if !a.m.s.LimitShowUsed {
		used = w.Remaining()
	}
	pace, _ = w.Elapsed(now)
	hot = w.UsedPercent >= a.m.s.TopThreshold()
	if w.ResetsAt != nil {
		reset = fmtr.ShortCountdown(w.ResetsAt.Sub(now))
	}
	return
}

func (a *ctrl) panelLimits(c *ui.Context, p palette, prov limits.Provider) {
	m := a.m
	var e limits.Entry
	for _, x := range m.d.Limits {
		if x.Provider == prov {
			e = x
		}
	}
	title := prov.DisplayName()
	if e.Snapshot != nil && e.Snapshot.AccountLabel != "" {
		title += " · " + e.Snapshot.AccountLabel
	}
	right := func() {
		p.mono(c, a.statusText(e), 10, p.T4)
	}
	p.panelFrame(c, string(prov), title, right, func() {
		if e.Snapshot == nil || len(e.Snapshot.Windows) == 0 {
			p.mono(c, a.statusText(e), 11, p.T3)
			return
		}
		wins := slices.DeleteFunc(slices.Clone(e.Snapshot.Windows), func(w limits.Window) bool {
			return w.Kind == limits.Model && !m.s.LimitShowModelBuckets
		})
		if m.s.PanelLimitStyle == "gauges" {
			ui.Row(c.Key("g")).FillWidth().Justify(ui.SpaceAround).Children(func() {
				for i, w := range wins[:min(3, len(wins))] {
					used, pace, hot, reset := a.limitView(w)
					sub := ""
					if m.s.PanelShowResets && reset != "" {
						sub = "↻ " + reset
					}
					p.dotGauge(c, itoa(i), used, pace, hot, 78, upper(windowLabel(w)), sub, m.s.LimitShowPace)
				}
			})
			return
		}
		ui.Column(c.Key("m")).FillWidth().Gap(8).Children(func() {
			for i, w := range wins {
				used, pace, hot, reset := a.limitView(w)
				ui.Row(c.Key(i)).FillWidth().Gap(9).AlignItems(ui.Center).Children(func() {
					ui.Text(c, upper(windowLabel(w))).Font(monoFont).FontSize(10.5).LetterSpacing(0.6).TextColor(p.T2).SingleLine().Width(70).Ellipsis("…")
					p.paceMeter(c, "meter", used, pace, hot, 20, m.s.LimitShowPace)
					ui.Text(c, itoa(int(math.Round(used)))+"%").Font(monoFont).FontSize(12).TextColor(pick(hot, p.Sig, p.T1)).SingleLine().Width(36).TextAlign(ui.End)
					if m.s.PanelShowResets {
						ui.Text(c, reset).Font(monoFont).FontSize(10).TextColor(p.T4).SingleLine().Width(48).TextAlign(ui.End)
					}
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
		y := days[0]
		share, all := 0.0, 0.0
		for i, v := range m.yesterdayHalf() {
			all += v
			if i <= slot {
				share += v
			}
		}
		if all > 0 {
			yTotal = float64(y.Tokens) * share / all
		}
	}
	right := func() { a.delta(c, p, float64(t.TotalTokens), yTotal, "") }
	p.panelFrame(c, "today", L("Today"), right, func() {
		if t.TotalTokens == 0 {
			p.mono(c, L("No usage yet today"), 11, p.T3)
			return
		}
		ui.Row(c.Key("n")).FillWidth().Gap(14).AlignItems(ui.End).Children(func() {
			v, u := splitNum(m.num(float64(t.TotalTokens)))
			p.bigNum(c, "tok", v, u, pick(m.s.ExactNumbers, float32(22), 36), p.T1)
			ui.Text(c, format.Money(t.CostUSD)).Font(monoFont).FontSize(15).TextColor(p.T2).SingleLine()
			p.mono(c, L("%lld msgs", t.Messages), 11, p.T3)
		})
		ui.Box(c).Height(10)
		half := m.todayHalf()
		if len(half) < 48 {
			half = append(slices.Clone(half), make([]float64, 48-len(half))...)
		}
		if m.s.PanelTodayStyle == "bars" {
			vals := slices.Clone(half[:48])
			for i := slot + 1; i < 48; i++ {
				vals[i] = 0
			}
			p.sparkBars(c, "bars", vals, sparkOpts{Emph: slot, Height: 34, Dots: true, Color: p.T2})
		} else {
			cum := cumulative(half[:min(48, slot+1)])
			ui.Box(c.Key("line")).FillWidth().Height(40).Children(func() {
				ui.Box(c).WidthPercent(float32(slot+1) / 48 * 100).Height(40).Children(func() {
					p.sparkLine(c, "l", cum, 40, p.T1, true, true)
				})
			})
		}
		ui.Row(c.Key("axis")).FillWidth().Justify(ui.SpaceBetween).Margin(4, 0, 0).Children(func() {
			for _, s := range []string{"0h", "6", "12", "18", "24h"} {
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
	total := 0.0
	for _, k := range keys {
		total += float64(src[k])
	}
	title := pick(models, L("Today's models"), L("Today's tools"))
	right := func() {
		if models {
			p.mono(c, L("%lld models", len(keys)), 10, p.T4)
		} else {
			p.mono(c, format.Money(t.CostUSD), 10, p.T4)
		}
	}
	col := func(k string) ui.Color { return pick(models, m.modelColor(p, k), m.toolColor(p, k)) }
	p.panelFrame(c, pick(models, "models", "tools"), title, right, func() {
		if len(keys) == 0 {
			p.mono(c, L("No usage yet today"), 11, p.T3)
			return
		}
		parts := make([]part, len(keys))
		for i, k := range keys {
			parts[i] = part{ID: k, V: float64(src[k]), Color: col(k)}
		}
		_, hover := p.segmentBar(c, "seg", parts, 5, "")
		ui.Box(c).Height(7)
		top := float64(src[keys[0]])
		for _, k := range keys[:min(len(keys), m.s.PanelListCount)] {
			v := float64(src[k])
			ui.Row(c.Key(k)).FillWidth().Height(22).Gap(8).AlignItems(ui.Center).Opacity(pick(hover != "" && hover != k, float32(0.4), 1)).Children(func() {
				if models {
					swatch(c, col(k), 7)
					logo(c, vendorLogo(vendorOf(k)), 11, m.vendorTint(p, vendorOf(k)))
				} else {
					logo(c, vendorLogo(k), 13, m.vendorTint(p, k))
				}
				ui.Text(c, pick(models, m.modelName(k), toolName(k))).Font(monoFont).FontSize(11).TextColor(p.T1).SingleLine().Grow(1).MinWidth(0).Ellipsis("…")
				ui.Box(c).Width(52).Height(3).Radius(2).Background(p.L2).Draw(func(pt *ui.Painter, r ui.Rect) {
					pt.Fill(ui.Rect{X: r.X, Y: r.Y, W: r.W * float32(v/top), H: r.H}, col(k), 2)
				})
				ui.Text(c, shortNum(v)).Font(monoFont).FontSize(10.5).TextColor(p.T2).SingleLine().Width(42).TextAlign(ui.End)
				ui.Text(c, itoa(int(math.Round(v/total*100)))+"%").Font(monoFont).FontSize(10.5).TextColor(p.T4).SingleLine().Width(30).TextAlign(ui.End)
			})
		}
	})
}

func (a *ctrl) panelWeek(c *ui.Context, p palette) {
	m := a.m
	days := m.days(7)
	vals := make([]float64, len(days))
	labels := make([]string, len(days))
	sum := 0.0
	for i, d := range days {
		vals[i] = float64(d.Tokens)
		sum += vals[i]
		if t, ok := format.DateFromKey(d.Date); ok {
			labels[i] = format.WeekdayInitialsFromMonday[format.WeekdayIndex(t)]
		}
	}
	avg := sum / math.Max(1, float64(len(days)))
	hovered := -1
	right := func() {
		txt := shortNum(sum) + " · " + shortNum(avg) + L("/day")
		if hovered >= 0 && hovered < len(days) {
			txt = format.ShortDate(days[hovered].Date) + " · " + shortNum(vals[hovered])
		}
		p.mono(c, txt, 10, p.T4)
	}
	p.panelFrame(c, "week", L("Last 7 days"), right, func() {
		_, hovered = p.sparkBars(c, "bars", vals, sparkOpts{Emph: len(vals) - 1, Rule: avg, Height: 44, Dots: true, Color: p.T2, Labels: labels})
	})
}

func (a *ctrl) panelMonth(c *ui.Context, p palette) {
	mc := a.m.monthCost()
	spent := 0.0
	if n := len(mc.Days); n > 0 {
		spent = mc.Days[n-1].Cumulative
	}
	right := func() { p.mono(c, L("Last month %@", format.Money(mc.LastMonthTotal)), 10, p.T4) }
	p.panelFrame(c, "month", L("This month's cost"), right, func() {
		ui.Row(c.Key("n")).FillWidth().Gap(12).AlignItems(ui.End).Children(func() {
			p.money(c, "spent", spent, 30)
			p.mono(c, L("Projected %@", format.Money(mc.Projected)), 11, p.T3)
		})
		ui.Box(c).Height(10)
		vals := make([]float64, max(mc.DaysInMonth, len(mc.Days)))
		for i, d := range mc.Days {
			vals[i] = d.Cost
		}
		p.sparkBars(c, "bars", vals, sparkOpts{Emph: len(mc.Days) - 1, Rule: spent / math.Max(1, float64(len(mc.Days))), Height: 30, Color: p.T2})
	})
}

// money is a dollar amount in the dot face: "$" small, cents small for amounts of 100 and more.
func (p palette) money(c *ui.Context, key string, v float64, size float32) ui.Element {
	return ui.Row(c.Key(key)).AlignItems(ui.End).Gap(1).Shrink(0).Children(func() {
		ui.Text(c, "$").Font(monoFont).FontSize(size*0.42).TextColor(p.T3).SingleLine().Margin(0, 0, size*0.5)
		if v < 100 {
			ui.Text(c.Key("v"), ftoa(v, 2)).Font(dotFont).FontSize(size).TextColor(p.T1).SingleLine().ContentTransition(ui.ContentTransition{Numeric: true})
			return
		}
		whole := math.Floor(v)
		ui.Text(c.Key("v"), format.Grouped(int64(whole))).Font(dotFont).FontSize(size).TextColor(p.T1).SingleLine().ContentTransition(ui.ContentTransition{Numeric: true})
		ui.Text(c.Key("c"), "."+pad2(int(math.Round((v-whole)*100)))).Font(monoFont).FontSize(size*0.36).TextColor(p.T3).SingleLine().Margin(0, 0, size*0.08)
	})
}

// delta is the change badge: "↗ 14.3%" in green or "↘ 3.1%" neutral, with an optional label.
func (a *ctrl) delta(c *ui.Context, p palette, now, prev float64, label string) {
	if prev <= 0 {
		return
	}
	pct := (now - prev) / prev * 100
	ui.Row(c).Gap(6).AlignItems(ui.Center).Shrink(0).Children(func() {
		p.badge(c, pick(pct >= 0, "↗ ", "↘ ")+ftoa(math.Abs(pct), 1)+"%", pick(pct >= 0, "up", ""))
		if label != "" {
			p.mono(c, label, 10.5, p.T3)
		}
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
