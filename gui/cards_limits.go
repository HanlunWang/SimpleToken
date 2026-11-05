package gui

import (
	"math"
	"slices"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/limits"
)

// ── Limits ──

// limitItem is one window to draw with everything its gauge needs.
type limitItem struct {
	prov  limits.Provider
	w     limits.Window
	spec  gaugeSpec
	proj  float64 // −1 without a forecast
	reset string
}

// limitItems are the shown providers' windows (per-model extras only when asked for), and the providers that
// have no window to draw (not set up, unreachable, loading).
func (a *ctrl) limitItems(p palette) (items []limitItem, empty []limits.Entry) {
	m := a.m
	now := m.now()
	for _, e := range m.d.Limits {
		if slices.Contains(m.s.HiddenLimitProviders, string(e.Provider)) {
			continue
		}
		if e.Snapshot == nil || len(e.Snapshot.Windows) == 0 {
			empty = append(empty, e)
			continue
		}
		for _, w := range e.Snapshot.Windows {
			if w.Kind == limits.Model && !m.s.LimitShowModelBuckets {
				continue
			}
			it := limitItem{prov: e.Provider, w: w, proj: -1}
			elapsed, ok := w.Elapsed(now)
			if !ok || !m.s.LimitShowPace {
				elapsed = -1
			}
			if v, ok := a.lim.Projected(e.Provider, w, now); ok {
				it.proj = v
			}
			if w.ResetsAt != nil {
				it.reset = fmtr.ShortCountdown(w.ResetsAt.Sub(now))
			}
			it.spec = gaugeSpec{
				Used: w.UsedPercent, Elapsed: elapsed, Proj: pick(m.s.LimitShowPace, it.proj, -1),
				Col: m.vendorTint(p, string(e.Provider)), Hot: w.UsedPercent >= m.s.TopThreshold(), Ticks: 42, Stroke: 2.4,
				Ground: p.Surf,
			}
			items = append(items, it)
		}
	}
	return items, empty
}

// limitName is "Claude 5-hour", "Codex weekly", or the window alone when the provider is clear.
func limitName(it limitItem, withProvider bool) string {
	name := windowLabel(it.w)
	if it.w.Kind == limits.Session {
		name = L("5-hour")
	}
	if withProvider {
		return it.prov.DisplayName() + " " + lowerFirst(name)
	}
	return name
}

func lowerFirst(s string) string {
	if s == "" || s == "Fable" {
		return s
	}
	r := []rune(s)
	if r[0] >= 'A' && r[0] <= 'Z' {
		r[0] += 'a' - 'A'
	}
	return string(r)
}

// limitsProbed is when the shown limits were read ("2 min ago"), for the card's note.
func (a *ctrl) limitsProbed() string {
	m := a.m
	var latest *limits.Entry
	for i, e := range m.d.Limits {
		if e.Snapshot != nil && !slices.Contains(m.s.HiddenLimitProviders, string(e.Provider)) {
			if latest == nil || e.Snapshot.UpdatedAt.After(latest.Snapshot.UpdatedAt) {
				latest = &m.d.Limits[i]
			}
		}
	}
	if latest == nil {
		return ""
	}
	if m.now().Sub(latest.Snapshot.UpdatedAt) < 90*time.Second {
		return L("just now")
	}
	return lowerFirst(fmtr.Ago(latest.Snapshot.UpdatedAt, m.now()))
}

func (a *ctrl) limitsCard(c *ui.Context, p palette, size cardSize) {
	m := a.m
	items, empty := a.limitItems(p)
	if len(items) == 0 {
		switch {
		case len(empty) > 0:
			a.limitNotice(c, p, empty[0])
		default:
			p.empty(c, L("All providers hidden"))
		}
		return
	}
	tip := func(it limitItem) (string, []tipRow) {
		rows := []tipRow{{Label: L("Used"), Value: ftoa(it.w.UsedPercent, 0) + "%"}}
		if e, ok := it.w.Elapsed(m.now()); ok {
			rows = append(rows, tipRow{Label: L("Window elapsed"), Value: ftoa(e*100, 0) + "%"})
		}
		if it.proj >= 0 {
			rows = append(rows, tipRow{Label: L("Expected by reset"), Value: "≈ " + ftoa(it.proj, 0) + "%"})
		}
		if it.w.ResetsAt != nil {
			start := it.w.ResetsAt.Add(-it.w.Span())
			rows = append(rows, tipRow{}, tipRow{Label: L("Window"), Value: format.ResetTime(start, m.now()) + " → " + format.ResetTime(*it.w.ResetsAt, m.now())})
		}
		return upper(it.prov.DisplayName() + " · " + windowLabel(it.w)), rows
	}
	switch size {
	case sizeS:
		shown := items[:min(2, len(items))]
		ui.Row(c.Key("s")).FillWidth().Grow(1).Gap(6).AlignItems(ui.Center).Children(func() {
			for i, it := range shown {
				ui.Column(c.Key(i)).Grow(1).Basis(0).AlignItems(ui.Center).Gap(2).Children(func() {
					s := it.spec
					s.Ticks, s.Stroke, s.Num = 32, 3.2, 25
					p.gauge(c, "g", s, 96)
					p.mono(c, limitName(it, false), 10.5, p.T2).Margin(-6, 0, 0)
				})
			}
		})
		resets := ""
		for i, it := range shown {
			if it.reset != "" {
				resets += pick(i > 0, " · ", "") + it.reset
			}
		}
		if resets != "" {
			p.mono(c, "↻ "+resets, 10.5, p.T3).AlignSelf(ui.Center)
		}
	case sizeM:
		ui.Column(c.Key("m")).FillWidth().Grow(1).Justify(ui.Center).Children(func() {
			for i, it := range items[:min(4, len(items))] {
				a.limitRow(c, p, i, it, 34)
			}
		})
	default:
		n := min(len(items), 6)
		across := pick(n > 4, 3, 2) // six windows (Claude's three, Codex's two, Cursor's) fit two rows of three
		ui.Column(c.Key("dials")).FillWidth().Grow(1).Justify(ui.Center).Gap(pick(n > 4, float32(8), 14)).Children(func() {
			for row := 0; row < (n+across-1)/across; row++ {
				ui.Row(c.Key(row)).FillWidth().Gap(12).Children(func() {
					for k := 0; k < across; k++ {
						i := row*across + k
						if i >= n {
							ui.Box(c.Key(k)).Grow(1).Basis(0)
							continue
						}
						it := items[i]
						ui.Column(c.Key(k)).Grow(1).Basis(0).AlignItems(ui.Center).Gap(4).Children(func() {
							s := it.spec
							s.Num = pick(n > 4, float32(28), 36)
							dw := pick(n > 4, float32(112), min(156, max(110, a.w.gridW/8)))
							p.gauge(c, "g", s, dw).Tooltip(tipText(tip(it)))
							ui.Row(c.Key("name")).Gap(6).AlignItems(ui.Center).Margin(-10, 0, 0).Children(func() {
								logo(c, vendorLogo(string(it.prov)), 13, pick(it.spec.Hot, p.Red, it.spec.Col))
								ui.Text(c, windowLabel(it.w)).FontSize(12.5).FontWeight(500).TextColor(p.T1).SingleLine()
								if it.proj >= 0 {
									p.mono(c, "→ "+itoa(int(math.Round(it.proj)))+"%", 11, p.T2)
								}
							})
							switch {
							case it.spec.Hot:
								p.mono(c, "! "+L("resets in %@", it.reset), 10.5, p.Red)
							case it.reset != "":
								p.mono(c, L("resets in %@", it.reset), 10.5, p.T3)
							}
						})
					}
				})
			}
		})
		if m.s.LimitShowPace {
			ui.Row(c.Key("legend")).FillWidth().Wrap().Justify(ui.Center).Gap(16).Padding(10, 0, 0).Shrink(0).Children(func() {
				ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
				col := items[0].spec.Col
				legendItem(c, p, L("Used"), func(pt *ui.Painter, r ui.Rect) { pt.Fill(ui.Rect{X: r.X + 5, Y: r.Y, W: 3, H: r.H}, col, 1.5) })
				legendItem(c, p, L("At this pace by reset"), func(pt *ui.Painter, r ui.Rect) { pt.Fill(ui.Rect{X: r.X + 5, Y: r.Y, W: 3, H: r.H}, dim(col), 1.5) })
				legendItem(c, p, L("Time elapsed"), func(pt *ui.Painter, r ui.Rect) {
					bar := ui.Rect{X: r.X + 6, Y: r.Y - 1, W: 1.5, H: r.H + 2}
					pt.Shadow(bar, 1, 0, 0, 6, 0, p.glow())
					pt.Fill(bar, p.Sig, 0.75)
				})
			})
		}
	}
}

// limitRow is a window as a line: logo, name, the three marks, the number and the time to the reset.
func (a *ctrl) limitRow(c *ui.Context, p palette, i int, it limitItem, height float32) {
	ui.Row(c.Key(i)).FillWidth().Height(height).Gap(10).AlignItems(ui.Center).Children(func() {
		if i > 0 {
			ui.Box(c).Absolute().Left(0).Top(0).FillWidth().Height(1).Background(p.L2)
		}
		logo(c, vendorLogo(string(it.prov)), 13, pick(it.spec.Hot, p.Red, it.spec.Col))
		p.mono(c, limitName(it, true), 11.5, p.T2).Width(118).Ellipsis("…")
		s := it.spec
		s.Ticks = 40
		p.gaugeLine(c, "line", s, 20)
		num := itoa(int(math.Round(it.w.UsedPercent))) + "%"
		if it.spec.Hot {
			num = "! " + num
		}
		ui.Text(c, num).Font(monoFont).FontSize(12).TextColor(pick(it.spec.Hot, p.Red, p.T1)).Width(44).TextAlign(ui.End).SingleLine()
		ui.Text(c, it.reset).Font(monoFont).FontSize(10.5).TextColor(p.T3).Width(56).TextAlign(ui.End).SingleLine()
	})
}

// limitNotice is a provider with nothing to draw: a dotted gauge and what is missing.
func (a *ctrl) limitNotice(c *ui.Context, p palette, e limits.Entry) {
	ui.Column(c.Key("notice")).FillWidth().Grow(1).AlignItems(ui.Center).Justify(ui.Center).Gap(4).Children(func() {
		p.gauge(c, "g", gaugeSpec{None: true, Elapsed: -1, Proj: -1, Ticks: 42, Stroke: 2.6, Num: 31, Ground: p.Surf}, 132)
		ui.Text(c, e.Provider.DisplayName()).FontSize(12.5).FontWeight(500).TextColor(p.T1).Margin(-8, 0, 0)
		p.mono(c, a.statusText(e), 10.5, p.T3)
	})
}

// tipText flattens a tooltip into a native tooltip's lines.
func tipText(title string, rows []tipRow) string {
	out := title
	for _, r := range rows {
		if r.Label == "" && r.Value == "" {
			continue
		}
		out += "\n" + r.Label + "  " + r.Value
	}
	return out
}
