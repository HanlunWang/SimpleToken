package history

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/HanlunWang/SimpleToken/internal/leakcheck"
)

func TestStartStopLeavesNothingRunning(t *testing.T) {
	check := leakcheck.Goroutines(t)
	for range 20 {
		src := &fakeGraph{g: graphDay(t, "2020-01-02", nil, row{7, 0.1, 1})}
		s := NewStore(src, filepath.Join(t.TempDir(), "a.json"), "")
		done := make(chan struct{}, 1)
		s.SetOnChange(func() {
			select {
			case done <- struct{}{}:
			default:
			}
		})
		s.Start(context.Background())
		<-done
		s.Stop()
	}
	check()
}
