package limits

import (
	"strings"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

// History is Claude Code's half-hour usage: local day key → model → 48 token counts (the intraday snapshot).
type History map[string]map[string][]int64

// profileDays is how many complete days the half-hour profile averages over.
const profileDays = 14

// Projected is where a window is heading by its reset (%): in a straight line at the pace so far once 5 % of the
// window has passed (the owner's choice: it keeps up with a heavy start, where history read low); before that,
// where a line from a few minutes says little, a Claude window goes by usage history (forecastFromHistory) when
// the app has fresh history (UsageHistory).
func (s *Store) Projected(p Provider, w Window, now time.Time) (float64, bool) {
	if v, ok := w.Projected(now); ok {
		return v, true
	}
	if p != Claude || s.UsageHistory == nil {
		return 0, false
	}
	h, ok := s.UsageHistory()
	if !ok {
		return 0, false
	}
	return forecastFromHistory(w, h, now)
}

// forecastFromHistory: the share of the limit one Claude Code token costs comes from this window (used % ÷ tokens
// since it opened); the tokens still to come are the average of the same half-hours over the past two weeks,
// idle days included. The Fable window counts Fable's tokens only. ok is false without usage, without tokens in
// the window (use on claude.ai alone) or without history.
func forecastFromHistory(w Window, h History, now time.Time) (float64, bool) {
	if w.UsedPercent <= 0 || w.ResetsAt == nil || !w.ResetsAt.After(now) {
		return 0, false
	}
	reset := *w.ResetsAt
	start := reset.Add(-w.Span())
	counts := func(model string) bool { return w.Kind != Fable || strings.Contains(strings.ToLower(model), "fable") }
	slotTokens := func(day string, slot int) int64 {
		var sum int64
		for model, list := range h[day] {
			if counts(model) && slot < len(list) {
				sum += list[slot]
			}
		}
		return sum
	}
	slotOf := func(t time.Time) (string, int) {
		t = t.Local()
		return format.DayKey(t), min(47, (t.Hour()*60+t.Minute())/30)
	}
	slotStart := func(t time.Time) time.Time {
		t = t.Local()
		return t.Add(-time.Duration(t.Minute()%30)*time.Minute - time.Duration(t.Second())*time.Second - time.Duration(t.Nanosecond()))
	}

	var spent int64
	for t := slotStart(start); !t.After(now); t = t.Add(30 * time.Minute) {
		spent += slotTokens(slotOf(t))
	}
	if spent <= 0 {
		return 0, false
	}

	earliest := ""
	for day := range h {
		if earliest == "" || day < earliest {
			earliest = day
		}
	}
	var profile [48]float64
	days := 0
	for back := 1; back <= profileDays; back++ {
		key := format.DayKey(now.Local().AddDate(0, 0, -back))
		if key < earliest {
			break
		}
		days++
		for i := range 48 {
			profile[i] += float64(slotTokens(key, i))
		}
	}
	if days == 0 {
		return 0, false
	}
	for i := range profile {
		profile[i] /= float64(days)
	}

	next := slotStart(now).Add(30 * time.Minute)
	_, cur := slotOf(now)
	first := next
	if reset.Before(first) {
		first = reset
	}
	expected := profile[cur] * first.Sub(now).Seconds() / 1800
	for t := next; t.Before(reset); t = t.Add(30 * time.Minute) {
		_, i := slotOf(t)
		expected += profile[i] * min(1, reset.Sub(t).Seconds()/1800)
	}
	return w.UsedPercent + w.UsedPercent/float64(spent)*expected, true
}
