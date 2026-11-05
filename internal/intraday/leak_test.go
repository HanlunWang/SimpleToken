package intraday

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/leakcheck"
)

// Run ends when done closes, paused or not, and resuming scans at once.
func TestRunPausesAndStops(t *testing.T) {
	check := leakcheck.Goroutines(t)
	for range 10 {
		s := NewStore(NewScanner(t.TempDir(), 90))
		s.SetPaused(true)
		done := make(chan struct{})
		changed := make(chan struct{}, 1)
		finished := make(chan struct{})
		go func() {
			s.Run(done, time.Hour, func(Snapshot) {
				select {
				case changed <- struct{}{}:
				default:
				}
			})
			close(finished)
		}()
		s.SetPaused(false)
		s.SetPaused(true)
		close(done)
		<-finished
	}
	check()
}

// Nothing the scanner keeps grows with uptime: days, counted messages and caches follow the kept days, and the
// offsets of deleted files go.
func TestScannerStateFollowsKeptDays(t *testing.T) {
	root := t.TempDir()
	start := at("2026-01-01T12:00:00Z")
	var lines []string
	for d := range 60 {
		for m := range 20 {
			ts := start.Add(time.Duration(d)*24*time.Hour + time.Duration(m)*time.Minute).UTC().Format(time.RFC3339)
			id := ts + "-" + string(rune('a'+m))
			lines = append(lines, `{"type":"assistant","message":{"model":"claude-opus-5-5","id":"`+id+
				`","usage":{"input_tokens":10,"output_tokens":1}},"requestId":"r`+id+`","timestamp":"`+ts+`"}`)
		}
	}
	path := filepath.Join(root, "p", "s.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewScanner(root, 7)
	now := start.Add(59 * 24 * time.Hour)
	_ = os.Chtimes(path, now, now)
	snap := s.Scan(now)
	if len(snap.ByModel) > 8 || len(s.seen) > 9*20 || len(s.dayKeyCache) > 70 {
		t.Fatalf("kept %d days, %d messages, %d day keys", len(snap.ByModel), len(s.seen), len(s.dayKeyCache))
	}
	// A month later the file is gone: everything empties
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	snap = s.Scan(now.Add(30 * 24 * time.Hour))
	if len(snap.ByModel) != 0 || len(s.seen) != 0 || len(s.offsets) != 0 || len(s.dayKeyCache) != 0 || len(s.offsetCache) != 0 {
		t.Fatalf("left %d days, %d messages, %d offsets, %d day keys, %d zone hours",
			len(snap.ByModel), len(s.seen), len(s.offsets), len(s.dayKeyCache), len(s.offsetCache))
	}
}
