package limits

import (
	"context"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/leakcheck"
)

// Every probe loop and one-shot refresh ends with Stop; a refresh while stopped ends on its own.
func TestStartStopLeavesNothingRunning(t *testing.T) {
	check := leakcheck.Goroutines(t)
	for range 20 {
		s, _ := newTestStore(t, "http://127.0.0.1:1")
		s.probes[Cursor] = func(context.Context) (Snapshot, error) {
			return Snapshot{Provider: Cursor, Windows: []Window{NewWindow(Weekly, 40, nil, 0, "")}}, nil
		}
		s.Start()
		s.RefreshNow()
		waitFor(t, "cursor probed", func() bool { return s.Get(Cursor).Status.State == StateOK })
		s.Stop()
		s.RefreshNow()
	}
	check()
}
