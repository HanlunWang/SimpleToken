package limits

import (
	"math"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

func TestOrganizationPlan(t *testing.T) {
	data := []byte(`[{"uuid":"api","capabilities":["api"]},
		{"uuid":"chat","capabilities":["chat","claude_max"],"rate_limit_tier":"default_claude_max_5x"},
		{"uuid":"tier","rate_limit_tier":"default_claude_max_20x"}]`)
	for id, want := range map[string]string{"chat": "Max 5x", "tier": "Max 20x", "api": "", "gone": ""} {
		if got := organizationPlan(data, id); got != want {
			t.Errorf("%s: %q, want %q", id, got, want)
		}
	}
}

// claude.ai's plan wins over Claude Code's Keychain item, which keeps the old plan after a change.
func TestStorePrefersClaudeWebPlan(t *testing.T) {
	fake := &fakeClaude{tier: "default_claude_max_5x"}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()
	s, creds := newTestStore(t, srv.URL) // the Keychain says Max 20x
	if err := creds.SetClaudeCookie("sk-ant-x"); err != nil {
		t.Fatal(err)
	}
	s.Start()
	defer s.Stop()
	waitFor(t, "ok", func() bool { return s.Get(Claude).Status.State == StateOK })
	if got := s.Get(Claude).Snapshot.AccountLabel; got != "Max 5x" {
		t.Fatalf("plan %q", got)
	}
}

// September 2026: no daylight-saving change inside the windows below.
func day(d, h, m int) time.Time { return time.Date(2026, 9, d, h, m, 0, 0, time.Local) }

// workday spends the same tokens in every half-hour from 9:00 to 17:00.
func workday(tokens int64) map[string][]int64 {
	list := make([]int64, 48)
	for i := 18; i < 34; i++ {
		list[i] = tokens
	}
	return map[string][]int64{"claude-opus-5": list}
}

func history(days []int, today map[string][]int64) History {
	h := History{}
	for _, d := range days {
		h[format.DayKey(day(d, 12, 0))] = workday(100)
	}
	h[format.DayKey(day(20, 12, 0))] = today
	return h
}

func TestForecastEarlyInTheWindow(t *testing.T) {
	// The weekly window opened Sunday 10:00; by 12:00 four busy half-hours (400 tokens) spent 2 %
	now := day(20, 12, 0)
	today := workday(0)
	for i := 20; i < 24; i++ {
		today["claude-opus-5"][i] = 100
	}
	reset := day(20, 10, 0).Add(7 * 24 * time.Hour)
	w := NewWindow(Weekly, 2, &reset, 0, "")
	var all []int
	for d := 6; d <= 19; d++ {
		all = append(all, d)
	}
	got, ok := forecastFromHistory(w, history(all, today), now)
	// Still to come: 10 half-hours today, 16 a day for six days, 2 on the last morning: 108 × 100 tokens
	if want := 2 + 2.0/400*108*100; !ok || math.Abs(got-want) > 0.01 {
		t.Fatalf("forecast %v %v, want %v", got, ok, want)
	}
	// Idle days still count: with work every other day the profile halves
	var odd []int
	for d := 6; d <= 19; d += 2 {
		odd = append(odd, d)
	}
	got, _ = forecastFromHistory(w, history(odd, today), now)
	if want := 2 + 2.0/400*108*50; math.Abs(got-want) > 0.01 {
		t.Fatalf("with idle days %v, want %v", got, want)
	}
	// Fable counts Fable's tokens only: none in the window, no forecast
	if _, ok := forecastFromHistory(NewWindow(Fable, 1, &reset, 0, ""), history(all, today), now); ok {
		t.Fatal("Fable forecast from other models' tokens")
	}
}

// Past 5 % of the window the straight line takes over; before it, history (when the app has it).
func TestStoreProjectedSwitchesToTheLine(t *testing.T) {
	s, _ := newTestStore(t, "http://127.0.0.1:1")
	today := workday(0)
	for i := 20; i < 24; i++ {
		today["claude-opus-5"][i] = 100
	}
	var all []int
	for d := 6; d <= 19; d++ {
		all = append(all, d)
	}
	s.UsageHistory = func() (History, bool) { return history(all, today), true }
	reset := day(20, 10, 0).Add(7 * 24 * time.Hour)
	w := NewWindow(Weekly, 2, &reset, 0, "")
	early := day(20, 12, 0)
	if got, ok := s.Projected(Claude, w, early); !ok || math.Abs(got-56) > 0.01 {
		t.Fatalf("early: %v %v", got, ok)
	}
	if _, ok := s.Projected(Codex, w, early); ok {
		t.Fatal("history forecast for a provider without history")
	}
	later := day(22, 10, 0) // 2 of 7 days gone
	w.UsedPercent = 20
	if got, ok := s.Projected(Claude, w, later); !ok || math.Abs(got-70) > 0.01 {
		t.Fatalf("later: %v %v, want the line's 70", got, ok)
	}
}
