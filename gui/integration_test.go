package gui

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/HanlunWang/SimpleToken/internal/settings"
)

// TestRealData runs the real stores (tokscale, history, limits, intraday) against a copy of a data directory and
// renders the dashboard. Opt-in, it reads this Mac's logs:
//
//	SIMPLETOKEN_REAL=1 SIMPLETOKEN_DATA_DIR=/copy/of/data SIMPLETOKEN_SHOTS=/tmp/shots go test -run TestRealData ./gui/
func TestRealData(t *testing.T) {
	if os.Getenv("SIMPLETOKEN_REAL") != "1" || os.Getenv("SIMPLETOKEN_DATA_DIR") == "" {
		t.Skip("set SIMPLETOKEN_REAL=1 and SIMPLETOKEN_DATA_DIR to a copy of the data directory")
	}
	setLanguage("en")
	login := false
	a := &ctrl{m: newModel(settings.Default()), w: newWinState(), loginGet: func() bool { return login }, loginSet: func(bool) {}}
	a.ctx, a.cancel = context.WithCancel(context.Background())
	a.startStores()
	defer a.shutdown()
	deadline := time.Now().Add(90 * time.Second)
	for {
		if snap, ok := a.coll.Snapshot(); ok && snap.Today.TotalTokens >= 0 && len(a.coll.History().Daily()) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no snapshot after 90 s: %v", a.coll.LastError())
		}
		time.Sleep(500 * time.Millisecond)
	}
	time.Sleep(3 * time.Second) // intraday scan and limit probes
	a.pull()
	d := a.m.d
	t.Logf("history %d days, today %d tokens, limits %d providers, intraday %d days", len(d.History), d.Snapshot.Today.TotalTokens, len(d.Limits), len(d.Intra.Days()))
	if len(d.History) == 0 {
		t.Fatal("empty history")
	}
	tt := ui.NewTester(a.windowView, 1180, 2700)
	tt.Frame()
	tt.Frame()
	shot(t, tt, "real-window")
	pt := ui.NewTester(a.panelView, 360, 1100)
	pt.Frame()
	shot(t, pt, "real-panel")
}
