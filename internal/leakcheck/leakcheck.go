// Package leakcheck lets tests assert that background work has stopped: no goroutine outlives the code that
// started it.
package leakcheck

import (
	"runtime"
	"testing"
	"time"
)

// Goroutines records the goroutines running now and returns a check that fails the test unless the count falls
// back to that within a few seconds (goroutines that are ending get time to return).
func Goroutines(t testing.TB) func() {
	t.Helper()
	base := runtime.NumGoroutine()
	return func() {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for {
			n := runtime.NumGoroutine()
			if n <= base {
				return
			}
			if time.Now().After(deadline) {
				buf := make([]byte, 1<<16)
				t.Fatalf("%d goroutines leaked (%d before, %d after):\n%s", n-base, base, n, buf[:runtime.Stack(buf, true)])
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}
