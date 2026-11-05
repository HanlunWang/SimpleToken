package collector

import (
	"context"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/leakcheck"
)

// Starting and stopping, as the app does when it quits, leaves no goroutine or timer behind, also with live
// updates toggled on and off on the way (the window and panel opening and closing).
func TestStartStopLeavesNothingRunning(t *testing.T) {
	check := leakcheck.Goroutines(t)
	for range 20 {
		s := New(newFake(), testPaths(t))
		c := watch(s)
		s.Start(context.Background())
		c.waitFor(t, "a snapshot", func() bool { return todayTokens(s) == 10 })
		s.SetLive(true)
		s.Poke()
		s.SetLive(false)
		s.RequestFull()
		s.Stop()
	}
	check()
}
