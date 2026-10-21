package gui

import (
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/limits"
	"github.com/HanlunWang/SimpleToken/internal/settings"
)

// newDemoCtrl is a controller on the demo data, without stores, tray or windows.
func newDemoCtrl(t *testing.T) *ctrl {
	t.Helper()
	t.Setenv("SIMPLETOKEN_DATA_DIR", t.TempDir())
	setLanguage("en")
	login := false
	a := &ctrl{m: newModel(settings.Default()), w: newWinState(), demo: true,
		loginGet: func() bool { return login }, loginSet: func(on bool) { login = on }}
	a.creds = limits.NewCredentialStore()
	a.lim = limits.NewStore(a.creds)
	a.loadDemo()
	return a
}

func shot(t *testing.T, tt *ui.Tester, name string) {
	dir := os.Getenv("SIMPLETOKEN_SHOTS")
	if dir == "" {
		return
	}
	tt.Advance(2 * time.Second)
	f, err := os.Create(filepath.Join(dir, name+".png"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, tt.Image()); err != nil {
		t.Fatal(err)
	}
}

func TestWindowRenders(t *testing.T) {
	for _, theme := range []string{"dark", "light"} {
		a := newDemoCtrl(t)
		a.m.s.Theme = theme
		tt := ui.NewTester(a.windowView, 1180, 2700)
		tt.Frame()
		tt.Frame()
		for _, want := range []string{"MAIN CHART", "LIMITS", "MODELS", "USAGE MAP", "FLOW", "CALENDAR", "TIME OF DAY", "TOOLS", "TOKEN BREAKDOWN", "THIS MONTH'S COST"} {
			if !tt.HasText(want) {
				t.Errorf("%s: missing %q", theme, want)
			}
		}
		shot(t, tt, "window-"+theme)
	}
}

func TestPanelRenders(t *testing.T) {
	a := newDemoCtrl(t)
	a.m.s.PanelSections = []string{"claude", "codex", "cursor", "today", "models", "tools", "week", "month"}
	tt := ui.NewTester(a.panelView, 360, 1400)
	tt.Frame()
	tt.Frame()
	for _, want := range []string{"CLAUDE", "TODAY", "LAST 7 DAYS"} {
		if !tt.HasText(want) {
			t.Errorf("panel: missing %q in %q", want, tt.Texts())
		}
	}
	shot(t, tt, "panel-meters")
	a.m.s.PanelLimitStyle, a.m.s.PanelTodayStyle = "gauges", "bars"
	tt.Frame()
	shot(t, tt, "panel-gauges")
}

func TestSettingsRender(t *testing.T) {
	a := newDemoCtrl(t)
	a.w.settings = true
	tt := ui.NewTester(a.windowView, 1180, 1100)
	for _, tab := range settingsTabs {
		a.w.tab = tab[0]
		tt.Frame()
		tt.Frame()
		shot(t, tt, "settings-"+tab[0])
	}
}
