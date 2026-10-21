package intraday

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

// The fixtures and expectations are written for UTC+8 (no DST), so local day keys and slots are fixed.
var zone = time.FixedZone("UTC+8", 8*3600)

func TestMain(m *testing.M) {
	time.Local = zone
	os.Exit(m.Run())
}

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

func sum(list []int64) int64 {
	var t int64
	for _, v := range list {
		t += v
	}
	return t
}

func TestScanFixture(t *testing.T) {
	s := NewScanner("testdata/projects", 90)
	snap := s.Scan(at("2026-09-30T12:00:00Z"))

	if got := snap.Days(); strings.Join(got, ",") != "2026-09-29,2026-09-30" {
		t.Fatalf("days = %v (the May line is past the cutoff)", got)
	}
	day := snap.ModelBuckets("2026-09-29", nil)
	// msg_01A once (its streaming duplicate is dropped) + msg_01B (escaped "usage"/"model" text is ignored)
	if got := sum(day["claude-opus-5-5"]); got != 3250+100 {
		t.Errorf("opus = %d", got)
	}
	if got := sum(day["claude-fable-5"]); got != 10 {
		t.Errorf("fable = %d (spaces after the colon, +08:00 offset)", got)
	}
	if _, ok := day["fake"]; ok {
		t.Error("model taken from conversation text")
	}
	// 14:03Z = 22:03 local → slot 44; 14:45Z → 45; 23:10+08:00 → slot 46
	if b := day["claude-opus-5-5"]; b[44] != 3250 || b[45] != 100 {
		t.Errorf("opus slots = %v", b[40:])
	}
	if b := day["claude-fable-5"]; b[46] != 10 {
		t.Errorf("fable slots = %v", b[40:])
	}
	// Empty model → unknown; 01:29:59.999Z = 09:29 local → slot 18; msg_02B (no requestId) at 09:30 → slot 19
	next := snap.ModelBuckets("2026-09-30", nil)
	if len(next) != 2 || next["unknown"][18] != 10 || next["claude-haiku-5"][19] != 20 {
		t.Errorf("2026-09-30 = %v", next)
	}
	if got := sum(snap.Buckets("2026-09-29", map[string]bool{"claude-fable-5": true})); got != 3350 {
		t.Errorf("excluding fable = %d", got)
	}
	card := snap.Punchcard(7, "2026-09-30", nil)
	var total int64
	days := 0
	for w := range card.Grid {
		total += sum(card.Grid[w][:])
		days += card.DayCount[w]
	}
	if total != 3390 || days != 7 {
		t.Errorf("punchcard total %d over %d days", total, days)
	}
	// 2026-09-29 is a Tuesday: row 1, hour 22
	if card.Grid[1][22] != 3350 || card.Models[1][22]["claude-opus-5-5"] != 3350 || card.Grid[1][23] != 10 {
		t.Errorf("tuesday 22h/23h = %d/%d", card.Grid[1][22], card.Grid[1][23])
	}

	// A second scan reads nothing new and returns an equal, independent copy
	again := s.Scan(at("2026-09-30T12:00:00Z"))
	if !again.Equal(snap) {
		t.Error("rescan changed the snapshot")
	}
	again.ByModel["2026-09-29"]["claude-opus-5-5"][44] = 0
	if snap.ByModel["2026-09-29"]["claude-opus-5-5"][44] != 3250 {
		t.Error("snapshots share buckets")
	}
}

// reference sums the fixture with a full JSON decode, the check ARCHITECTURE.md asks for when the parser changes.
func reference(t *testing.T, root string, cutoffKey string) map[string]int64 {
	t.Helper()
	type line struct {
		RequestID string `json:"requestId"`
		Timestamp string `json:"timestamp"`
		Message   *struct {
			ID    string `json:"id"`
			Model string `json:"model"`
			Usage *struct {
				Input      int64 `json:"input_tokens"`
				Output     int64 `json:"output_tokens"`
				CacheRead  int64 `json:"cache_read_input_tokens"`
				CacheWrite int64 `json:"cache_creation_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	out := map[string]int64{}
	seen := map[string]bool{}
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() && strings.HasPrefix(d.Name(), ".") {
			return filepath.SkipDir
		}
		if d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		f, _ := os.Open(path)
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var l line
			if json.Unmarshal(sc.Bytes(), &l) != nil || l.Message == nil || l.Message.Usage == nil {
				continue
			}
			id := l.Message.ID
			if !strings.HasPrefix(id, "msg_") {
				id = ""
			}
			if id == "" && l.RequestID == "" || seen[id+"|"+l.RequestID] {
				continue
			}
			seen[id+"|"+l.RequestID] = true
			ts, err := time.Parse(time.RFC3339, l.Timestamp)
			if err != nil || format.DayKey(ts) < cutoffKey {
				continue
			}
			u := l.Message.Usage
			model := l.Message.Model
			if model == "" {
				model = "unknown"
			}
			out[model] += u.Input + u.Output + u.CacheRead + u.CacheWrite
		}
		return nil
	})
	return out
}

func TestScanMatchesFullJSONReference(t *testing.T) {
	now := at("2026-09-30T12:00:00Z")
	snap := NewScanner("testdata/projects", 90).Scan(now)
	ref := reference(t, "testdata/projects", format.DayKey(now.AddDate(0, 0, -90)))
	got := map[string]int64{}
	for _, models := range snap.ByModel {
		for m, b := range models {
			got[m] += sum(b)
		}
	}
	for m, v := range ref {
		if v > 0 && got[m] != v {
			t.Errorf("%s: scanner %d, reference %d", m, got[m], v)
		}
	}
	for m, v := range got {
		if ref[m] != v {
			t.Errorf("%s: scanner %d, reference %d", m, v, ref[m])
		}
	}
}

func usageLine(id string, tokens int, stamp string) string {
	return `{"timestamp":"` + stamp + `","requestId":"r-` + id + `","message":{"id":"` + id + `","usage":{"input_tokens":` +
		itoa(tokens) + `,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}`
}

func itoa(n int) string { return format.Render("%lld", n) }

func TestIncrementalScanDedupesAndDefersPartialLines(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "s.jsonl")
	now := time.Now()
	stamp := now.UTC().Format(time.RFC3339)
	b := usageLine("b", 7, stamp)
	// a appears twice (streaming duplicate); b's line is only half written
	content := usageLine("a", 100, stamp) + "\n" + usageLine("a", 100, stamp) + "\n" +
		`{"type":"user","message":{"content":"x"}}` + "\n" + b[:40]
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewScanner(dir, 90)
	today := format.DayKey(now)
	if got := sum(s.Scan(now).Buckets(today, nil)); got != 100 {
		t.Fatalf("first scan = %d", got)
	}
	// Finish b's line: only the new part is read
	f, err := os.OpenFile(file, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(b[40:] + "\n")
	f.Close()
	if got := sum(s.Scan(now).Buckets(today, nil)); got != 107 {
		t.Fatalf("second scan = %d", got)
	}
	// Rewritten shorter: read again from the start; already counted messages are not counted twice
	if err := os.WriteFile(file, []byte(usageLine("c", 5, stamp)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := sum(s.Scan(now).Buckets(today, nil)); got != 112 {
		t.Fatalf("after rewrite = %d", got)
	}
}

func TestLongLinesAcrossChunks(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	stamp := now.UTC().Format(time.RFC3339)
	padding := strings.Repeat("x", chunkSize+123)
	var sb strings.Builder
	for i := range 3 {
		sb.WriteString(`{"message":{"model":"m","id":"msg_` + itoa(i) + `","content":"` + padding + `","usage":{"input_tokens":1}},"timestamp":"` + stamp + "\"}\n")
	}
	if err := os.WriteFile(filepath.Join(dir, "big.jsonl"), []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := sum(NewScanner(dir, 90).Scan(now).Buckets(format.DayKey(now), nil)); got != 3 {
		t.Fatalf("got %d", got)
	}
}

func TestMissingRoot(t *testing.T) {
	snap := NewScanner(filepath.Join(t.TempDir(), "nope"), 90).Scan(time.Now())
	if len(snap.ByModel) != 0 {
		t.Fatal("expected empty")
	}
}

func TestParseTimestampMatchesRFC3339(t *testing.T) {
	for _, s := range []string{"2026-09-29T14:03:12.345Z", "2025-01-01T00:00:00Z", "2024-02-29T23:59:59.9Z",
		"2026-03-08T07:30:00+08:00", "2026-11-01T01:15:00-04:00", "1999-12-31T23:59:59.000Z"} {
		want, err := time.Parse(time.RFC3339Nano, s)
		if err != nil {
			t.Fatal(err)
		}
		got, ok := ParseTimestamp([]byte(s))
		if !ok || got != want.Unix() {
			t.Errorf("%s: got %d %v, want %d", s, got, ok, want.Unix())
		}
	}
	for _, s := range []string{"not-a-timestamp-at-all", "2026-13-01T00:00:00Z", "2026-09-29", "2026-09-29T14:03:12+08"} {
		if _, ok := ParseTimestamp([]byte(s)); ok {
			t.Errorf("%s parsed", s)
		}
	}
}

func TestCivilRoundTrip(t *testing.T) {
	for day := int64(-800_000); day <= 800_000; day += 997 {
		y, m, d := CivilFromDays(day)
		if DaysFromCivil(y, m, d) != day {
			t.Fatalf("day %d → %d-%d-%d", day, y, m, d)
		}
	}
	if DaysFromCivil(1970, 1, 1) != 0 || DaysFromCivil(2000, 3, 1) != 11017 {
		t.Fatal("anchors")
	}
}

func TestStorePausesAndDemo(t *testing.T) {
	st := NewStore(NewScanner("testdata/projects", 90))
	if _, changed := st.Refresh(); !changed {
		// The fixture is from 2026-09; with today's clock it may all be past the cutoff, which is still a valid
		// (empty) refresh.
		if len(st.Snapshot().ByModel) != 0 {
			t.Fatal("unchanged but not empty")
		}
	}
	demo := NewSnapshot()
	demo.ByModel["2026-01-01"] = map[string][]int64{"m": make([]int64, SlotsPerDay)}
	st.LoadDemo(demo)
	if _, changed := st.Refresh(); changed || !st.Snapshot().Equal(demo) {
		t.Fatal("demo mode must not scan")
	}
	done := make(chan struct{})
	close(done)
	st.SetPaused(true)
	st.Run(done, time.Hour, nil) // returns at once
}
