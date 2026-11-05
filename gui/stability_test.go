package gui

import (
	"runtime"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

// A window left open for hours, its data refreshed every few seconds and its range switched back and forth, holds
// steady memory: nothing the views derive or cache grows with frames or refreshes.
func TestLongRunMemoryIsStable(t *testing.T) {
	if testing.Short() {
		t.Skip("long run")
	}
	a := newDemoCtrl(t)
	a.m.s.Theme = "dark"
	tt := ui.NewTester(a.windowView, 1440, 3200)
	pt := ui.NewTester(a.panelView, 340, 1200)
	heap := func() uint64 {
		runtime.GC()
		runtime.GC()
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		return ms.HeapAlloc
	}
	step := func(i int) {
		if i%10 == 0 {
			a.loadDemo() // a collection lands: new data, every memo dropped
		}
		a.m.s.Range = rangeChoices[(i/25)%len(rangeChoices)][0]
		tt.Advance(100 * time.Millisecond)
		tt.Frame()
		if i%5 == 0 {
			pt.Advance(500 * time.Millisecond)
			pt.Frame()
		}
	}
	for i := range 300 {
		step(i)
	}
	base := heap()
	for i := range 3000 {
		step(i)
	}
	after := heap()
	t.Logf("heap after warm-up %.1f MB, after 3000 more frames %.1f MB", float64(base)/(1<<20), float64(after)/(1<<20))
	if after > base+8<<20 {
		t.Fatalf("heap grew from %d to %d bytes over 3000 frames", base, after)
	}
}
