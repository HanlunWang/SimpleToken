// Package format turns numbers, money, day keys and durations into UI text. It is the Go port of the Swift
// `Fmt` helpers plus the small relative-time helpers the views used.
//
// Translatable text never carries translated words here: functions return English through a Formatter whose
// Translate hook maps a String Catalog key (English text with %lld / %@ / %lf placeholders, exactly as in
// App/Localizable.xcstrings) to the localized format. The CJK ten-thousand units come from the catalog keys
// unit.10K and unit.100M through the same hook, so no CJK text lives in Go source.
package format

import (
	"math"
	"strconv"
	"strings"
	"time"
)

// Formatter renders UI text for one localization. The zero value is English.
type Formatter struct {
	// CJKUnits switches Short to ten-thousand based units (the UI runs in a Chinese localization).
	CJKUnits bool
	// Translate maps a catalog key to its localized format; nil, or an empty result, keeps the English key.
	Translate func(key string) string
}

// English is the source-language formatter.
var English = Formatter{}

// Text is a translatable string: Key is the String Catalog key, Args fill its placeholders in order
// (int / int64 for %lld, string for %@, float64 for %lf).
type Text struct {
	Key  string
	Args []any
}

// T builds a Text.
func T(key string, args ...any) Text { return Text{Key: key, Args: args} }

// String renders the English text.
func (t Text) String() string { return Render(t.Key, t.Args...) }

// L renders a Text through the formatter's catalog.
func (f Formatter) L(t Text) string {
	format := t.Key
	if f.Translate != nil {
		if s := f.Translate(t.Key); s != "" {
			format = s
		}
	}
	return Render(format, t.Args...)
}

func (f Formatter) l(key string, args ...any) string { return f.L(T(key, args...)) }

// Render fills a catalog format: %lld / %ld / %d take an integer, %@ a string, %lf / %f a float (printed like
// String(format:) prints it, six decimals unless a precision is given), %% a percent sign. Positional forms
// (%1$lld, %2$@) are honoured, since translations may reorder arguments.
func Render(format string, args ...any) string {
	var b strings.Builder
	next := 0
	for i := 0; i < len(format); i++ {
		c := format[i]
		if c != '%' || i+1 >= len(format) {
			b.WriteByte(c)
			continue
		}
		j := i + 1
		if format[j] == '%' {
			b.WriteByte('%')
			i = j
			continue
		}
		// Optional position n$
		pos := -1
		k := j
		for k < len(format) && format[k] >= '0' && format[k] <= '9' {
			k++
		}
		if k > j && k < len(format) && format[k] == '$' {
			n, _ := strconv.Atoi(format[j:k])
			pos = n - 1
			j = k + 1
		}
		// Optional precision .n
		prec := -1
		if j < len(format) && format[j] == '.' {
			k = j + 1
			for k < len(format) && format[k] >= '0' && format[k] <= '9' {
				k++
			}
			prec, _ = strconv.Atoi(format[j+1 : k])
			j = k
		}
		// Length modifiers
		for j < len(format) && (format[j] == 'l' || format[j] == 'h' || format[j] == 'q') {
			j++
		}
		if j >= len(format) {
			b.WriteString(format[i:])
			break
		}
		verb := format[j]
		if verb != 'd' && verb != 'i' && verb != 'u' && verb != '@' && verb != 'f' {
			b.WriteString(format[i : j+1])
			i = j
			continue
		}
		idx := next
		if pos >= 0 {
			idx = pos
		} else {
			next++
		}
		var arg any
		if idx >= 0 && idx < len(args) {
			arg = args[idx]
		}
		b.WriteString(renderArg(verb, prec, arg))
		i = j
	}
	return b.String()
}

func renderArg(verb byte, prec int, arg any) string {
	switch verb {
	case 'f':
		if prec < 0 {
			prec = 6
		}
		return strconv.FormatFloat(toFloat(arg), 'f', prec, 64)
	case '@':
		switch v := arg.(type) {
		case string:
			return v
		case nil:
			return ""
		case interface{ String() string }:
			return v.String()
		}
		return ""
	}
	return strconv.FormatInt(toInt(arg), 10)
}

func toInt(a any) int64 {
	switch v := a.(type) {
	case int:
		return int64(v)
	case int64:
		return v
	case int32:
		return int64(v)
	case float64:
		return int64(v)
	}
	return 0
}

func toFloat(a any) float64 {
	switch v := a.(type) {
	case float64:
		return v
	case int:
		return float64(v)
	case int64:
		return float64(v)
	}
	return 0
}

// ── numbers ──

// Compact is the ASCII form for the menu bar: 74.2M / 1.24B / 700.0K.
func Compact(n int64) string {
	v := float64(n)
	switch {
	case v >= 1e9:
		return strconv.FormatFloat(v/1e9, 'f', 2, 64) + "B"
	case v >= 1e6:
		return strconv.FormatFloat(v/1e6, 'f', 1, 64) + "M"
	case v >= 1e3:
		return strconv.FormatFloat(v/1e3, 'f', 1, 64) + "K"
	}
	return strconv.FormatInt(n, 10)
}

// USD is plain dollars with cents: $4.20.
func USD(v float64) string { return "$" + strconv.FormatFloat(v, 'f', 2, 64) }

// Money is money in the UI: no cents from $1,000 up ($4,044), otherwise two decimals ($12.30).
func Money(v float64) string {
	digits := 2
	if v >= 1000 {
		digits = 0
	}
	s := strconv.FormatFloat(v, 'f', digits, 64)
	whole, frac, _ := strings.Cut(s, ".")
	neg := strings.HasPrefix(whole, "-")
	whole = strings.TrimPrefix(whole, "-")
	out := groupDigits(whole)
	if neg {
		out = "-" + out
	}
	if frac != "" {
		out += "." + frac
	}
	return "$" + out
}

// Exact is a number with grouping: 74,208,291.
func Exact(n int64) string { return Grouped(n) }

// Grouped formats an integer with comma grouping.
func Grouped(n int64) string {
	if n < 0 {
		if n == math.MinInt64 {
			return "-9,223,372,036,854,775,808"
		}
		return "-" + groupDigits(strconv.FormatInt(-n, 10))
	}
	return groupDigits(strconv.FormatInt(n, 10))
}

func groupDigits(d string) string {
	if len(d) <= 3 {
		return d
	}
	var b strings.Builder
	head := len(d) % 3
	if head > 0 {
		b.WriteString(d[:head])
	}
	for i := head; i < len(d); i += 3 {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(d[i : i+3])
	}
	return b.String()
}

// round is Swift's rounded(): to nearest, halves away from zero.
func round(v float64) float64 { return math.Round(v) }

// Short is a short token count. English: 5.21 B / 23.4 M / 35.1 K / 3,512 (K from 10,000 up). With CJKUnits:
// ten-thousand based units from the catalog (unit.10K, unit.100M). The unit is separated by a space so the UI can
// render it smaller.
func (f Formatter) Short(n float64) string {
	v := round(n)
	if f.CJKUnits {
		if v >= 1e8 {
			p := 2
			if v >= 1e10 {
				p = 1
			}
			return strconv.FormatFloat(v/1e8, 'f', p, 64) + " " + f.l("unit.100M")
		}
		if v >= 1e4 {
			return Grouped(int64(round(v/1e4))) + " " + f.l("unit.10K")
		}
		return Grouped(int64(v))
	}
	switch {
	case v >= 1e9:
		p := 2
		if v >= 1e11 {
			p = 0
		} else if v >= 1e10 {
			p = 1
		}
		return strconv.FormatFloat(v/1e9, 'f', p, 64) + " B"
	case v >= 1e6:
		p := 1
		if v >= 1e8 {
			p = 0
		}
		return strconv.FormatFloat(v/1e6, 'f', p, 64) + " M"
	case v >= 1e4:
		return strconv.FormatFloat(v/1e3, 'f', 1, 64) + " K"
	}
	return Grouped(int64(v))
}

// Tokens follows the short / exact setting.
func (f Formatter) Tokens(n float64, exact bool) string {
	if exact {
		return Grouped(int64(round(n)))
	}
	return f.Short(n)
}

// Metric names accepted by Formatter.Metric (the same raw values as analytics.Metric).
const (
	MetricTokens   = "tokens"
	MetricCost     = "cost"
	MetricMessages = "messages"
)

// Metric formats a value of a metric ("tokens", "cost" or "messages"). Axis ticks pass exact = false: they are
// always short.
func (f Formatter) Metric(v float64, metric string, exact bool) string {
	switch metric {
	case MetricCost:
		return Money(v)
	case MetricMessages:
		return f.l("%@ msgs", Grouped(int64(round(v))))
	}
	return f.Tokens(v, exact)
}

// ── durations ──

// Seconds: 30 s / 2 min / 1 min 30 s.
func (f Formatter) Seconds(s int) string {
	if s < 60 {
		return f.l("%lld s", s)
	}
	if s%60 == 0 {
		return f.l("%lld min", s/60)
	}
	return f.l("%lld min %lld s", s/60, s%60)
}

// ShortCountdown is the time to a reset, compact: "2d 4h", "2h 14m", "35m" (at least 1m).
func (f Formatter) ShortCountdown(d time.Duration) string {
	s := max(0, int(d/time.Second))
	switch {
	case s >= 86400:
		return f.l("%lldd %lldh", s/86400, s%86400/3600)
	case s >= 3600:
		return f.l("%lldh %lldm", s/3600, s%3600/60)
	}
	return f.l("%lldm", max(1, s/60))
}

// CountdownLeft is the time to a reset in hover tips: "2 d 4 h left", "2 h 14 min left", "35 min left".
func (f Formatter) CountdownLeft(d time.Duration) string {
	s := max(0, int(d/time.Second))
	switch {
	case s >= 86400:
		return f.l("%lld d %lld h left", s/86400, s%86400/3600)
	case s >= 3600:
		return f.l("%lld h %lld min left", s/3600, s%3600/60)
	}
	return f.l("%lld min left", s/60)
}

// MenuBarCountdown is the ASCII countdown in the menu bar (never translated): 45m / 2h13m / 3d4h.
func MenuBarCountdown(d time.Duration) string {
	minutes := max(0, int(d/time.Minute))
	switch {
	case minutes < 60:
		return strconv.Itoa(minutes) + "m"
	case minutes < 24*60:
		m := minutes % 60
		mm := strconv.Itoa(m)
		if m < 10 {
			mm = "0" + mm
		}
		return strconv.Itoa(minutes/60) + "h" + mm + "m"
	}
	return strconv.Itoa(minutes/1440) + "d" + strconv.Itoa(minutes%1440/60) + "h"
}

// WindowSpan names a limit window's length: "5-hour window", "7-day window", "30-minute window".
func (f Formatter) WindowSpan(minutes int) string {
	switch {
	case minutes >= 1440:
		return f.l("%lld-day window", minutes/1440)
	case minutes >= 60:
		return f.l("%lld-hour window", minutes/60)
	}
	return f.l("%lld-minute window", minutes)
}

// ── relative times ──

// Ago is a limit snapshot's age: "Just updated" (under 90 s), "N min ago", "N h ago".
func (f Formatter) Ago(at, now time.Time) string {
	s := int(now.Sub(at) / time.Second)
	switch {
	case s < 90:
		return f.l("Just updated")
	case s < 3600:
		return f.l("%lld min ago", s/60)
	}
	return f.l("%lld h ago", s/3600)
}

// Updated is the dashboard refresh label: "Just updated", "Updated N min ago", then "Updated HH:mm".
func (f Formatter) Updated(at, now time.Time) string {
	s := int(now.Sub(at) / time.Second)
	switch {
	case s < 60:
		return f.l("Just updated")
	case s < 3600:
		return f.l("Updated %lld min ago", s/60)
	}
	return f.l("Updated %@", Clock(at))
}

// PanelUpdated is the drop-down panel's refresh label: "Just now", "N min ago", then "HH:mm".
func (f Formatter) PanelUpdated(at, now time.Time) string {
	s := int(now.Sub(at) / time.Second)
	switch {
	case s < 60:
		return f.l("Just now")
	case s < 3600:
		return f.l("%lld min ago", s/60)
	}
	return Clock(at)
}

// ── dates ──

// Clock is hours and minutes in the local time zone: 14:05.
func Clock(t time.Time) string { return t.Local().Format("15:04") }

// DayKey is the local day key yyyy-MM-dd (tokscale uses the system time zone too).
func DayKey(t time.Time) string { return t.Local().Format("2006-01-02") }

// MonthKey is the local month key yyyy-MM.
func MonthKey(t time.Time) string { return t.Local().Format("2006-01") }

// DateFromKey is local noon of a day key (noon keeps day arithmetic clear of DST edges); ok is false for a
// malformed key.
func DateFromKey(key string) (time.Time, bool) {
	parts := strings.Split(key, "-")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	y, e1 := strconv.Atoi(parts[0])
	m, e2 := strconv.Atoi(parts[1])
	d, e3 := strconv.Atoi(parts[2])
	if e1 != nil || e2 != nil || e3 != nil {
		return time.Time{}, false
	}
	return time.Date(y, time.Month(m), d, 12, 0, 0, 0, time.Local), true
}

// ShortDate is the month and day of a day key: "Sep 14" (English; other localizations format dates in the UI
// layer with the platform's locale-aware templates).
func ShortDate(key string) string {
	t, ok := DateFromKey(key)
	if !ok {
		return key
	}
	return t.Format("Jan 2")
}

// LongDate is year, month, day and weekday of a day key: "Mon, Sep 14, 2026" (English).
func LongDate(key string) string {
	t, ok := DateFromKey(key)
	if !ok {
		return key
	}
	return t.Format("Mon, Jan 2, 2006")
}

// MonthName is the short month name for calendar labels: "Sep" (English).
func MonthName(t time.Time) string { return t.Local().Format("Jan") }

// WeekdaysFromMonday are the short English weekday names starting on Monday.
var WeekdaysFromMonday = []string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

// WeekdayInitialsFromMonday are the very short English weekday names starting on Monday.
var WeekdayInitialsFromMonday = []string{"M", "T", "W", "T", "F", "S", "S"}

// WeekdayIndex is Monday = 0 … Sunday = 6 in the local time zone.
func WeekdayIndex(t time.Time) int { return (int(t.Local().Weekday()) + 6) % 7 }

// Weekday is the short English weekday name of a date.
func Weekday(t time.Time) string { return WeekdaysFromMonday[WeekdayIndex(t)] }
