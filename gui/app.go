package gui

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"sync"
	"time"

	"github.com/egoist/mygo"
	_ "github.com/egoist/mygo/locales/zh-Hans" // mygo's own control strings in Chinese
	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/analytics"
	"github.com/HanlunWang/SimpleToken/internal/collector"
	"github.com/HanlunWang/SimpleToken/internal/demo"
	"github.com/HanlunWang/SimpleToken/internal/format"
	"github.com/HanlunWang/SimpleToken/internal/history"
	"github.com/HanlunWang/SimpleToken/internal/intraday"
	"github.com/HanlunWang/SimpleToken/internal/limits"
	"github.com/HanlunWang/SimpleToken/internal/paths"
	"github.com/HanlunWang/SimpleToken/internal/platform/darwin"
	"github.com/HanlunWang/SimpleToken/internal/settings"
	"github.com/HanlunWang/SimpleToken/internal/tokscale"
)

// ctrl owns the app: the stores, the menu bar item, the panel and the main window. Everything on it is read and
// changed on the main thread; stores report changes from their goroutines through pull.
type ctrl struct {
	m        *model
	coll     *collector.Store
	lim      *limits.Store
	creds    *limits.CredentialStore
	notifier *limits.Notifier
	cursor   *tokscale.CursorSync
	intra    *intraday.Store
	ctx      context.Context
	cancel   context.CancelFunc

	tray     *mygo.Tray
	trayKey  string
	flyout   *mygo.Window
	panelH   float32
	closedAt time.Time

	panelResize func(h float32)

	win      *mygo.Window
	w        *winState
	quitting bool

	upd updates

	loginGet func() bool
	loginSet func(bool)

	pullMu      sync.Mutex
	pullPending bool
	demo        bool
}

// Run starts the menu bar app and blocks until it quits.
func Run() error {
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	if !mygo.App.RequestSingleInstanceLock() {
		return nil // the running instance shows its window
	}
	mygo.App.OnWindowAllClosed(func() {}) // closing the window keeps the app in the menu bar
	mygo.App.SetLanguages("en", "zh-Hans")
	setLanguage(mygo.App.Locale())
	if err := paths.Ensure(); err != nil {
		return err
	}

	a := &ctrl{m: newModel(settings.Load()), w: newWinState(), demo: demo.Enabled(),
		loginGet: mygo.App.OpenAtLogin, loginSet: func(on bool) { _ = mygo.App.SetOpenAtLogin(on) }}
	a.ctx, a.cancel = context.WithCancel(context.Background())
	a.startStores()
	mygo.App.WhenReady(a.ready)
	mygo.App.OnSecondInstance(func([]string, string) { mygo.RunOnMain(func() { a.openWindow(false) }) })
	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) { a.quitting = true })
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { a.shutdown() })
	mygo.App.OnLocaleChanged(func(loc string) {
		setLanguage(loc)
		a.invalidate()
	})
	return mygo.App.Run()
}

func (a *ctrl) startStores() {
	s := a.m.s
	limits.Transport = &darwin.URLSessionTransport{} // Apple's networking stack, as the Swift releases used
	a.creds = limits.NewCredentialStore()
	a.creds.ImportLegacyIfMissing()
	a.lim = limits.NewStore(a.creds)
	hidden := []limits.Provider{}
	for _, h := range s.HiddenLimitProviders {
		hidden = append(hidden, limits.Provider(h))
	}
	a.lim.SetHiddenProviders(hidden)
	a.notifier = limits.NewNotifier(limits.NotifiedPath())

	if a.demo {
		a.loadDemo()
		return
	}
	bin, err := tokscale.LocateBinary()
	if err != nil {
		log.Println("tokscale:", err)
	}
	runner := tokscale.NewRunner(bin)
	a.coll = collector.New(runner, collector.DefaultPaths())
	a.coll.SetLiveInterval(time.Duration(s.LiveRefreshSeconds) * time.Second)
	a.coll.SetFullInterval(time.Duration(s.FullRefreshMinutes) * time.Minute)
	a.cursor = tokscale.NewCursorSync(runner, limits.CursorSignedIn)
	a.coll.SetBeforeFullScan(a.cursor.SyncIfDue)
	a.coll.History().SetFilter(analytics.NewFilter(s.ExcludedModels, s.ExcludedClients))
	a.coll.SetOnChange(a.schedulePull)
	a.lim.OnChange = a.schedulePull
	a.coll.Start(a.ctx)
	a.lim.Start()
	a.intra = intraday.NewStore(intraday.NewScanner("", 90))
	go a.intra.Run(a.ctx.Done(), 60*time.Second, func(intraday.Snapshot) { a.schedulePull() })
}

// watchLogs pokes the collector when Claude Code writes its logs (FSEvents), so today's numbers move without polling.
func (a *ctrl) watchLogs() {
	home, _ := os.UserHomeDir()
	for _, dir := range []string{filepath.Join(home, ".claude", "projects"), filepath.Join(home, ".claude", "transcripts"), filepath.Join(home, ".codex", "sessions")} {
		if _, err := os.Stat(dir); err != nil {
			continue
		}
		w, err := mygo.WatchFiles(a.ctx, dir, mygo.FileWatchOptions{Recursive: true, Debounce: 500 * time.Millisecond, MaxDelay: 2 * time.Second})
		if err != nil {
			log.Println("watch", filepath.Base(dir), err)
			continue
		}
		go func() {
			for {
				if _, err := w.Next(a.ctx); err != nil {
					return
				}
				a.coll.Poke()
			}
		}()
	}
}

// schedulePull coalesces store notifications into one pull on the main thread.
func (a *ctrl) schedulePull() {
	a.pullMu.Lock()
	if a.pullPending {
		a.pullMu.Unlock()
		return
	}
	a.pullPending = true
	a.pullMu.Unlock()
	time.AfterFunc(80*time.Millisecond, func() {
		mygo.RunOnMain(func() {
			a.pullMu.Lock()
			a.pullPending = false
			a.pullMu.Unlock()
			a.pull()
		})
	})
}

// pull copies the stores into the model (main thread) and redraws what shows it.
func (a *ctrl) pull() {
	if a.demo {
		return
	}
	now := time.Now()
	d := data{TodayKey: format.DayKey(now)}
	f := analytics.NewFilter(a.m.s.ExcludedModels, a.m.s.ExcludedClients)
	if snap, ok := a.coll.Snapshot(); ok {
		d.Snapshot = snap
		d.Collected = true
		d.UpdatedAt = snap.CollectedAt
		live := analytics.LiveDay(f.Apply(snap.Today), d.TodayKey)
		d.Live = &live
	}
	hs := a.coll.History()
	for _, s := range hs.Daily() {
		if s.Date != d.TodayKey {
			d.History = append(d.History, analytics.DaySummary(s))
		}
	}
	d.Rows = archiveRows(hs.Archive())
	d.LegacyMerged = hs.ImportedFromLegacy()
	d.Refreshing = a.coll.IsCollecting()
	d.Intra = a.intra.Snapshot()
	d.Limits = a.lim.Entries()
	if a.cursor != nil {
		d.CursorError = a.cursor.LastError()
	}
	a.m.setData(d)
	a.checkAlerts()
	a.invalidate()
}

func archiveRows(ar *history.Archive) []analytics.Day {
	if ar == nil {
		return nil
	}
	out := make([]analytics.Day, 0, len(ar.Days))
	for k, day := range ar.Days {
		ad := analytics.Day{Date: k}
		for _, o := range day.Observations {
			ad.Rows = append(ad.Rows, analytics.Row{Client: o.Client, Model: o.ModelID, Tokens: o.Tokens, Cost: o.Cost, Messages: o.Messages})
		}
		out = append(out, ad)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Date < out[j].Date })
	return out
}

// toF converts buckets to floats; nil becomes n zeros.
func toF(v []int64) []float64 {
	out := make([]float64, len(v))
	for i, x := range v {
		out[i] = float64(x)
	}
	return out
}

// loadDemo fills the model with the deterministic demo data (SIMPLETOKEN_DEMO=1; screenshots, recordings).
func (a *ctrl) loadDemo() {
	now := time.Now()
	ar := demo.Archive(now)
	days := demo.AnalyticsDays(ar)
	snap := demo.Snapshot(ar, now)
	f := analytics.NewFilter(a.m.s.ExcludedModels, a.m.s.ExcludedClients)
	d := data{TodayKey: format.DayKey(now), Rows: days, Snapshot: snap, Collected: true, UpdatedAt: now}
	d.History = analytics.Summaries(days, d.TodayKey, f, 0)
	d.History = slices.DeleteFunc(d.History, func(s analytics.DaySummary) bool { return s.Date == d.TodayKey })
	live := analytics.LiveDay(f.Apply(snap.Today), d.TodayKey)
	d.Live = &live
	d.Intra = demo.Intraday(ar, now)
	cl, cx, cu := demo.Limits(now)
	for _, s := range []limits.Snapshot{cl, cx, cu} {
		s := s
		d.Limits = append(d.Limits, limits.Entry{Provider: s.Provider, Snapshot: &s, Status: limits.Status{State: limits.StateOK, UpdatedAt: now}})
	}
	a.m.setData(d)
}

func (a *ctrl) ready() {
	var err error
	a.tray, err = mygo.NewTray(mygo.TrayOptions{ID: "main", IconIsTemplate: true, ToolTip: "SimpleToken"})
	if err != nil {
		log.Println("tray:", err)
	} else {
		a.tray.OnClick(func() {
			if a.m.s.ClickOpensPanel != darwin.OptionKeyDown() { // ⌥-click opens the other one
				a.togglePanel()
			} else {
				a.openWindow(false)
			}
		})
		a.tray.OnRightClick(a.contextMenu)
		a.tray.OnAppearanceChange(func() { a.trayKey = ""; a.syncMenuBar() })
	}
	if a.coll != nil {
		a.watchLogs() // FSEvents needs the running app
	}
	a.pull()
	a.syncMenuBar()
	if os.Getenv("SIMPLETOKEN_NO_WINDOW") != "1" { // dev: measure the menu-bar-only state
		a.openWindow(false)
	}
	// Clock-bound items (countdowns, today by hour) redraw every 30 s; the image is only re-set when it changed.
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-a.ctx.Done():
				return
			case <-t.C:
				// Also ticks "Updated N min ago" over in the window.
				mygo.RunOnMain(func() {
					a.syncMenuBar()
					if a.win != nil {
						a.win.Invalidate()
					}
				})
			}
		}
	}()
	if !a.demo {
		a.startUpdates()
	}
	if os.Getenv("SIMPLETOKEN_SHOW_PANEL") == "1" {
		time.AfterFunc(1200*time.Millisecond, func() { mygo.RunOnMain(a.togglePanel) })
	}
}

func (a *ctrl) shutdown() {
	a.cancel()
	if a.coll != nil {
		a.coll.Stop()
	}
	a.lim.Stop()
	if a.tray != nil {
		a.tray.Destroy()
	}
}

// palette is the current palette for the resolved appearance.
func (a *ctrl) palette() palette {
	dark := true
	switch a.m.s.Theme {
	case "light":
		dark = false
	case "system":
		dark = mygo.Theme.IsDark()
	}
	return newPalette(dark, Pal(a.m.s.Palette))
}

// invalidate redraws every open surface and the menu bar item.
func (a *ctrl) invalidate() {
	if a.flyout != nil {
		a.flyout.Invalidate()
	}
	if a.win != nil {
		a.win.Invalidate()
	}
	a.syncMenuBar()
	a.updateLive()
}

// updateLive tells the collector whether anything needs live numbers: a visible window or panel, or a menu bar
// item showing today's figures. Without one, watch ticks only mark the data stale (AGENTS.md performance rules).
func (a *ctrl) updateLive() {
	if a.coll == nil {
		return
	}
	need := a.flyout != nil || (a.win != nil && a.win.IsVisible())
	if a.intra != nil {
		a.intra.SetPaused(!need)
	}
	for _, it := range a.m.s.MenuBarItems {
		switch it {
		case "today.tokens", "today.cost", "month.cost", "today.hours", "week.days":
			need = true
		}
	}
	a.coll.SetLive(need)
}

// saveSettings persists the settings and applies the ones the stores read.
func (a *ctrl) saveSettings() {
	s := a.m.s
	if err := s.Save(); err != nil {
		log.Println("settings:", err)
	}
	if a.coll != nil {
		a.coll.SetLiveInterval(time.Duration(s.LiveRefreshSeconds) * time.Second)
		a.coll.SetFullInterval(time.Duration(s.FullRefreshMinutes) * time.Minute)
		a.coll.History().SetFilter(analytics.NewFilter(s.ExcludedModels, s.ExcludedClients))
	}
	hidden := []limits.Provider{}
	for _, h := range s.HiddenLimitProviders {
		hidden = append(hidden, limits.Provider(h))
	}
	a.lim.SetHiddenProviders(hidden)
	if a.win != nil {
		a.win.SetAlwaysOnTop(s.FloatingWindow)
	}
	a.m.invalidate()
	if a.demo {
		a.loadDemo()
	} else {
		a.pull()
	}
	a.invalidate()
}

func (a *ctrl) refreshAll() {
	if a.cursor != nil {
		a.cursor.MarkDue()
	}
	if a.coll != nil {
		a.coll.RequestFull()
	}
	a.lim.RefreshNow()
	a.w.manualRefresh = time.Now()
	a.invalidate()
}

// checkAlerts posts a notification once per window period per threshold (when alerts are on).
func (a *ctrl) checkAlerts() {
	if !a.m.s.LimitNotifications || a.demo {
		return
	}
	hidden := map[limits.Provider]bool{}
	for _, h := range a.m.s.HiddenLimitProviders {
		hidden[limits.Provider(h)] = true
	}
	var snaps []limits.Snapshot
	for _, e := range a.m.d.Limits {
		if e.Snapshot != nil {
			snaps = append(snaps, *e.Snapshot)
		}
	}
	for _, al := range a.notifier.Check(snaps, a.m.s.AlertThresholds, hidden) {
		title := al.Provider.DisplayName() + " · " + windowLabel(al.Window)
		body := L("%@ · %@: %lld%% used", al.Provider.DisplayName(), windowLabel(al.Window), int64(al.Window.UsedPercent))
		if al.Window.ResetsAt != nil {
			body += " · " + fmtr.CountdownLeft(time.Until(*al.Window.ResetsAt))
		}
		mygo.NewNotification(mygo.NotificationOptions{Title: title, Body: body}).Show()
	}
}

// ── Panel ──

func (a *ctrl) togglePanel() {
	if a.flyout != nil {
		a.closePanel()
		return
	}
	if time.Since(a.closedAt) < 400*time.Millisecond {
		return // the click that closed the panel by clicking outside it
	}
	if a.tray == nil {
		return
	}
	w := max(320, a.m.s.PanelWidth)
	maxH := float32(800)
	if d := mygo.Screen.PrimaryDisplay(); d.WorkArea.Height > 0 {
		maxH = float32(d.WorkArea.Height) - 40
	}
	h := a.panelH
	if h <= 0 {
		h = 520
	}
	fl := mygo.NewFlyout(mygo.FlyoutOptions{
		Tray: a.tray, Placement: mygo.PlacementBottom, Gap: 6, Width: w, Height: int(min(h, maxH) + 0.5),
		Focusable: os.Getenv("SIMPLETOKEN_SHOW_PANEL") != "1", Shadow: true,
		Vibrancy: pick(a.m.s.PanelMaterial == "solid", mygo.Vibrancy(""), mygo.VibrancyPopover), CornerRadius: 12,
		Content: ui.View(a.panelView),
	})
	a.flyout = fl
	fl.SetOpacity(0)
	shown := false
	reveal := func() {
		if shown || a.flyout != fl {
			return
		}
		shown = true
		darwin.RevealWindow(fl.NativeHandle(), 0.22, 6, false)
		fl.Invalidate()
	}
	a.panelResize = func(ch float32) {
		ch = min(ch, maxH)
		if ch == a.panelH && shown {
			return
		}
		a.panelH = ch
		go mygo.RunOnMain(func() {
			if a.flyout == fl {
				fl.SetSize(w, int(ch+0.5))
				reveal()
			}
		})
	}
	time.AfterFunc(300*time.Millisecond, func() { mygo.RunOnMain(reveal) })
	fl.OnClose(func(e *mygo.CloseEvent) {
		if a.flyout == fl && !a.quitting {
			e.PreventDefault()
			a.closePanel()
		}
	})
	fl.OnClosed(func() {
		if a.flyout == fl {
			a.flyout = nil
			a.closedAt = time.Now()
			a.updateLive()
		}
	})
	a.updateLive()
}

func (a *ctrl) closePanel() {
	fl := a.flyout
	if fl == nil {
		return
	}
	a.flyout = nil
	a.closedAt = time.Now()
	a.panelResize = nil
	a.updateLive()
	darwin.FadeOutWindow(fl.NativeHandle(), 0.12)
	time.AfterFunc(130*time.Millisecond, func() { mygo.RunOnMain(fl.Close) })
}

func (a *ctrl) contextMenu() {
	if a.flyout != nil {
		a.closePanel()
	}
	menu := mygo.NewMenu([]*mygo.MenuItem{
		{Label: L("Open Main Window"), Click: func(*mygo.MenuItem, *mygo.Window) { a.openWindow(false) }},
		{Label: L("Settings…"), Accelerator: "CmdOrCtrl+,", Click: func(*mygo.MenuItem, *mygo.Window) { a.openWindow(true) }},
		{Label: L("Refresh Now"), Accelerator: "CmdOrCtrl+R", Click: func(*mygo.MenuItem, *mygo.Window) { a.refreshAll() }},
		mygo.Separator(),
		{Label: L("Quit SimpleToken"), Accelerator: "CmdOrCtrl+Q", Click: func(*mygo.MenuItem, *mygo.Window) { mygo.App.Quit() }},
	})
	a.tray.SetMenu(menu)
	defer a.tray.SetMenu(nil)
	a.tray.PopUpMenu()
}

// ── Main window ──

// openWindow shows the main window, on the dashboard or the settings page. Closing the window destroys it and
// its whole view state (the cheapest hidden window is no window: AGENTS.md performance rules).
func (a *ctrl) openWindow(settingsPage bool) {
	if a.flyout != nil {
		a.closePanel()
	}
	a.w.settings = settingsPage
	if a.win != nil {
		a.win.Show()
		a.win.Focus()
		mygo.App.Focus()
		a.win.Invalidate()
		return
	}
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyRegular)
	a.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "SimpleToken", Width: 1180, Height: 860, MinWidth: 420, MinHeight: 440,
		TitleBarStyle: mygo.TitleBarHidden, StateKey: "main", AlwaysOnTop: a.m.s.FloatingWindow,
		BackgroundColor: "#14120b", Content: ui.View(a.windowView),
	})
	a.win.OnClosed(func() {
		a.win = nil
		a.w = newWinState()
		mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
		a.updateLive()
	})
	mygo.App.Focus()
	a.updateLive()
}

// ── Menu bar item ──

var mbItemLabels = map[string]string{
	"claude.session": "5h", "claude.weekly": "wk", "claude.fable": "Fable", "codex.session": "5h", "codex.weekly": "wk",
	"cursor.weekly": "wk", "today.tokens": "today", "today.cost": "today", "month.cost": "month", "claude.reset": "reset",
	"today.hours": "today", "week.days": "7d",
}

// menuBarSegs turns the chosen items into segments for the renderer.
func (a *ctrl) menuBarSegs() []mbSeg {
	m := a.m
	now := m.now()
	providers := map[string]bool{}
	for _, it := range m.s.MenuBarItems {
		if p, _, ok := cutDot(it); ok && (p == "claude" || p == "codex" || p == "cursor") && it != "claude.reset" {
			providers[p] = true
		}
	}
	var segs []mbSeg
	for _, it := range m.s.MenuBarItems {
		label := L(mbItemLabels[it])
		prov, kind, _ := cutDot(it)
		switch it {
		case "today.tokens":
			segs = append(segs, mbSeg{Label: label, Value: shortNum(float64(m.today().TotalTokens)), Pct: -1})
		case "today.cost":
			segs = append(segs, mbSeg{Label: label, Value: format.Money(m.today().CostUSD), Pct: -1})
		case "month.cost":
			mc := m.monthCost()
			v := 0.0
			if n := len(mc.Days); n > 0 {
				v = mc.Days[n-1].Cumulative
			}
			segs = append(segs, mbSeg{Label: label, Value: format.Money(v), Pct: -1})
		case "claude.reset":
			if w, ok := a.window(limits.Claude, limits.Session); ok && w.ResetsAt != nil {
				segs = append(segs, mbSeg{Label: label, Value: format.MenuBarCountdown(w.ResetsAt.Sub(now)), Pct: -1})
			}
		case "today.hours":
			bars := make([]float64, 24)
			for i, v := range m.todayHalf() {
				bars[min(23, i/2)] += v
			}
			segs = append(segs, mbSeg{Bars: bars, Now: now.Hour(), Pct: -1})
		case "week.days":
			days := m.days(7)
			bars := make([]float64, len(days))
			for i, d := range days {
				bars[i] = float64(d.Tokens)
			}
			segs = append(segs, mbSeg{Bars: bars, Now: len(bars) - 1, Pct: -1})
		default:
			w, ok := a.window(limits.Provider(prov), limits.Kind(kind))
			if !ok {
				continue
			}
			used, pace, hot, _ := a.limitView(w)
			if len(providers) > 1 {
				label = limits.Provider(prov).DisplayName() + " " + label
			}
			segs = append(segs, mbSeg{Label: label, Value: itoa(int(used+0.5)) + "%", Pct: used, Pace: pace, Hot: hot})
		}
	}
	return segs
}

func (a *ctrl) window(p limits.Provider, k limits.Kind) (limits.Window, bool) {
	for _, e := range a.m.d.Limits {
		if e.Provider == p && e.Snapshot != nil {
			return e.Snapshot.Window(k)
		}
	}
	return limits.Window{}, false
}

func cutDot(s string) (string, string, bool) {
	for i := range len(s) {
		if s[i] == '.' {
			return s[:i], s[i+1:], true
		}
	}
	return s, "", false
}

// syncMenuBar redraws the item; the image is only sent to AppKit when it changed.
func (a *ctrl) syncMenuBar() {
	if a.tray == nil {
		return
	}
	s := a.m.s
	png, tmpl := renderMenuBar(a.menuBarSegs(), mbOpts{
		Style: mbStyle(s.MenuBarStyle), Labels: s.MenuBarShowLabels || s.MenuBarStyle == "stacked", Pace: s.MenuBarShowPace,
		Icon: s.MenuBarShowIcon, Red: s.MenuBarAlertColor, Dark: a.tray.Dark(),
	})
	key := string(png)
	if key == a.trayKey {
		return
	}
	a.trayKey = key
	_ = a.tray.SetIcon(png, tmpl)
}
