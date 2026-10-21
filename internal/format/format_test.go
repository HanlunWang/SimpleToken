package format

import (
	"os"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	time.Local = time.FixedZone("UTC+8", 8*3600)
	os.Exit(m.Run())
}

func TestCompact(t *testing.T) {
	for n, want := range map[int64]string{0: "0", 999: "999", 700_000: "700.0K", 74_208_291: "74.2M", 1_240_000_000: "1.24B"} {
		if got := Compact(n); got != want {
			t.Errorf("Compact(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestShortEnglish(t *testing.T) {
	cases := map[float64]string{
		0: "0", 3512: "3,512", 9999.4: "9,999", 35_100: "35.1 K", 23_400_000: "23.4 M", 234_000_000: "234 M",
		5_210_000_000: "5.21 B", 52_100_000_000: "52.1 B", 521_000_000_000: "521 B",
	}
	for n, want := range cases {
		if got := English.Short(n); got != want {
			t.Errorf("Short(%v) = %q, want %q", n, got, want)
		}
	}
	if got := English.Tokens(74_208_291, true); got != "74,208,291" {
		t.Errorf("exact = %q", got)
	}
	if got := English.Tokens(74_208_291, false); got != "74.2 M" {
		t.Errorf("short = %q", got)
	}
}

// Catalog stand-in for a Chinese localization; the unit words are written as escapes (no CJK in source).
var zh = Formatter{CJKUnits: true, Translate: func(key string) string {
	return map[string]string{
		"unit.10K":     "\u4e07",
		"unit.100M":    "\u4ebf",
		"%lld min ago": "%lld \u5206\u949f\u524d",
		"%lldh %lldm":  "%lld\u5c0f\u65f6%lld\u5206",
		"%@ msgs":      "%@ \u6761",
	}[key]
}}

func TestShortCJK(t *testing.T) {
	cases := map[float64]string{
		9_999: "9,999", 35_100: "4 \u4e07", 12_345_678: "1,235 \u4e07", 523_000_000: "5.23 \u4ebf", 52_300_000_000: "523.0 \u4ebf",
	}
	for n, want := range cases {
		if got := zh.Short(n); got != want {
			t.Errorf("Short(%v) = %q, want %q", n, got, want)
		}
	}
	if got := zh.Metric(1234, MetricMessages, false); got != "1,234 \u6761" {
		t.Errorf("messages = %q", got)
	}
}

func TestMoneyAndGrouping(t *testing.T) {
	for v, want := range map[float64]string{0: "$0.00", 12.3: "$12.30", 999.994: "$999.99", 1000: "$1,000", 4044.4: "$4,044", 1_234_567.8: "$1,234,568", -5: "$-5.00"} {
		if got := Money(v); got != want {
			t.Errorf("Money(%v) = %q, want %q", v, got, want)
		}
	}
	if USD(4.2) != "$4.20" {
		t.Error("USD")
	}
	for n, want := range map[int64]string{0: "0", 999: "999", 1000: "1,000", -1234567: "-1,234,567", 100000: "100,000"} {
		if got := Grouped(n); got != want {
			t.Errorf("Grouped(%d) = %q", n, got)
		}
	}
	if got := English.Metric(12.5, MetricCost, true); got != "$12.50" {
		t.Errorf("cost = %q", got)
	}
	if got := English.Metric(1234.4, MetricMessages, true); got != "1,234 msgs" {
		t.Errorf("messages = %q", got)
	}
}

func TestDurations(t *testing.T) {
	for s, want := range map[int]string{30: "30 s", 120: "2 min", 90: "1 min 30 s"} {
		if got := English.Seconds(s); got != want {
			t.Errorf("Seconds(%d) = %q", s, got)
		}
	}
	short := map[time.Duration]string{
		2*time.Hour + 23*time.Minute: "2h 23m", 35 * time.Minute: "35m", 10 * time.Second: "1m", 52 * time.Hour: "2d 4h",
	}
	for d, want := range short {
		if got := English.ShortCountdown(d); got != want {
			t.Errorf("ShortCountdown(%v) = %q, want %q", d, got, want)
		}
	}
	if got := zh.ShortCountdown(2*time.Hour + 23*time.Minute); got != "2\u5c0f\u65f623\u5206" {
		t.Errorf("zh countdown = %q", got)
	}
	left := map[time.Duration]string{52 * time.Hour: "2 d 4 h left", 134 * time.Minute: "2 h 14 min left", 35 * time.Minute: "35 min left"}
	for d, want := range left {
		if got := English.CountdownLeft(d); got != want {
			t.Errorf("CountdownLeft(%v) = %q", d, got)
		}
	}
	bar := map[time.Duration]string{45 * time.Minute: "45m", 133 * time.Minute: "2h13m", 125 * time.Minute: "2h05m", 76 * time.Hour: "3d4h", -time.Hour: "0m"}
	for d, want := range bar {
		if got := MenuBarCountdown(d); got != want {
			t.Errorf("MenuBarCountdown(%v) = %q", d, got)
		}
	}
	if English.WindowSpan(300) != "5-hour window" || English.WindowSpan(10080) != "7-day window" || English.WindowSpan(30) != "30-minute window" {
		t.Error("window span")
	}
}

func TestRelative(t *testing.T) {
	now := time.Date(2026, 10, 21, 15, 30, 0, 0, time.Local)
	ago := map[time.Duration]string{30 * time.Second: "Just updated", 89 * time.Second: "Just updated", 5 * time.Minute: "5 min ago", 3 * time.Hour: "3 h ago"}
	for d, want := range ago {
		if got := English.Ago(now.Add(-d), now); got != want {
			t.Errorf("Ago(%v) = %q", d, got)
		}
	}
	if got := English.Updated(now.Add(-7*time.Minute), now); got != "Updated 7 min ago" {
		t.Errorf("Updated = %q", got)
	}
	if got := English.Updated(now.Add(-2*time.Hour), now); got != "Updated 13:30" {
		t.Errorf("Updated = %q", got)
	}
	if got := English.PanelUpdated(now.Add(-10*time.Second), now); got != "Just now" {
		t.Errorf("PanelUpdated = %q", got)
	}
	if got := zh.PanelUpdated(now.Add(-3*time.Minute), now); got != "3 \u5206\u949f\u524d" {
		t.Errorf("zh PanelUpdated = %q", got)
	}
}

func TestRender(t *testing.T) {
	cases := []struct {
		format string
		args   []any
		want   string
	}{
		{"%lld min %lld s", []any{1, 30}, "1 min 30 s"},
		{"%2$@ / %1$lld", []any{7, "x"}, "x / 7"},
		{"%.1lf%%", []any{12.345}, "12.3%"},
		{"%@ msgs", []any{T("%lld", 3)}, "3 msgs"},
		{"plain", nil, "plain"},
		{"%lld", nil, "0"},
	}
	for _, c := range cases {
		if got := Render(c.format, c.args...); got != c.want {
			t.Errorf("Render(%q) = %q, want %q", c.format, got, c.want)
		}
	}
	if T("%lld h ago", 2).String() != "2 h ago" {
		t.Error("Text.String")
	}
}

func TestDates(t *testing.T) {
	ts := time.Date(2026, 9, 14, 23, 30, 0, 0, time.UTC) // 07:30 on the 15th in UTC+8
	if DayKey(ts) != "2026-09-15" || MonthKey(ts) != "2026-09" || Clock(ts) != "07:30" {
		t.Errorf("%s %s %s", DayKey(ts), MonthKey(ts), Clock(ts))
	}
	if ShortDate("2026-09-14") != "Sep 14" || LongDate("2026-09-14") != "Mon, Sep 14, 2026" || ShortDate("bad") != "bad" {
		t.Errorf("%s / %s", ShortDate("2026-09-14"), LongDate("2026-09-14"))
	}
	d, _ := DateFromKey("2026-09-14")
	if Weekday(d) != "Mon" || WeekdayIndex(d.AddDate(0, 0, 6)) != 6 || MonthName(d) != "Sep" {
		t.Error("weekday")
	}
}
