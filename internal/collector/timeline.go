package collector

import (
	"encoding/json"
	"os"
	"slices"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/atomicfile"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

const (
	maxTimelineSamples = 600
	hourlyKeepDays     = 14
)

// Timeline is today's cumulative usage as sampled by each collection (today-timeline.json). tokscale only has
// daily resolution, so the collector records today itself; differences of adjacent samples give per-bucket usage.
type Timeline struct {
	DayKey  string   `json:"dayKey"`
	Samples []Sample `json:"samples"`
}

// Sample is today's cumulative token count at one moment.
type Sample struct {
	At          time.Time `json:"at"`
	TotalTokens int64     `json:"totalTokens"`
}

// Record appends a sample, starting over on a new day, and keeps the last 600 (a scan every few minutes plus
// watch ticks stays well under that in a day).
func (t *Timeline) Record(tokens int64, at time.Time) {
	if key := usage.DayKey(at); key != t.DayKey {
		t.DayKey = key
		t.Samples = nil
	}
	t.Samples = append(t.Samples, Sample{At: isoTime(at), TotalTokens: tokens})
	if n := len(t.Samples); n > maxTimelineSamples {
		t.Samples = slices.Clone(t.Samples[n-maxTimelineSamples:])
	}
}

// HalfHourBuckets is today's net token increase per local half hour (48 buckets); zeros when the timeline is not
// today's. A drop (logs cleaned up) adds nothing and the climb restarts from the highest value seen.
func (t Timeline) HalfHourBuckets(now time.Time) []int64 {
	buckets := make([]int64, 48)
	if usage.DayKey(now) != t.DayKey || len(t.Samples) == 0 {
		return buckets
	}
	var last int64
	for _, s := range t.Samples {
		at := s.At.In(now.Location())
		i := at.Hour() * 2
		if at.Minute() >= 30 {
			i++
		}
		buckets[i] += max(0, s.TotalTokens-last)
		last = max(last, s.TotalTokens)
	}
	return buckets
}

// HourlyBuckets is today's net token increase per local hour (24 buckets), the same rule as HalfHourBuckets.
func (t Timeline) HourlyBuckets(now time.Time) []int64 {
	half := t.HalfHourBuckets(now)
	out := make([]int64, 24)
	for h := range out {
		out[h] = half[2*h] + half[2*h+1]
	}
	return out
}

func (t Timeline) clone() Timeline {
	return Timeline{DayKey: t.DayKey, Samples: slices.Clone(t.Samples)}
}

// HourlyHistory keeps the last 14 days of half-hour buckets (hourly-history.json): each collection stores
// today's from the timeline.
type HourlyHistory struct {
	Days map[string][]int64 `json:"days"`
}

// Set stores a day's buckets, keeping the newest 14 days and none after todayKey.
func (h *HourlyHistory) Set(dayKey string, buckets []int64, todayKey string) {
	if h.Days == nil {
		h.Days = map[string][]int64{}
	}
	h.Days[dayKey] = buckets
	keys := make([]string, 0, len(h.Days))
	for k := range h.Days {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if len(keys) > hourlyKeepDays {
		for _, k := range keys[:len(keys)-hourlyKeepDays] {
			delete(h.Days, k)
		}
	}
	for k := range h.Days {
		if k > todayKey {
			delete(h.Days, k)
		}
	}
}

// HourTotals is one day's net token increase per local hour (24 buckets; zeros for a day not kept).
func (h HourlyHistory) HourTotals(dayKey string) []int64 {
	out := make([]int64, 24)
	b := h.Days[dayKey]
	for i, v := range b {
		if i/2 < len(out) {
			out[i/2] += v
		}
	}
	return out
}

// RollingHourly is the per-hour totals of the last hours hours, oldest first, ending with the current hour
// (joined across days).
func (h HourlyHistory) RollingHourly(hours int, now time.Time) []int64 {
	out := make([]int64, max(0, hours))
	day := now
	hour := now.Hour()
	totals := h.HourTotals(usage.DayKey(day))
	for i := len(out) - 1; i >= 0; i-- {
		out[i] = totals[hour]
		hour--
		if hour < 0 {
			hour = 23
			day = day.AddDate(0, 0, -1)
			totals = h.HourTotals(usage.DayKey(day))
		}
	}
	return out
}

func (h HourlyHistory) clone() HourlyHistory {
	out := HourlyHistory{Days: make(map[string][]int64, len(h.Days))}
	for k, v := range h.Days {
		out.Days[k] = slices.Clone(v)
	}
	return out
}

func loadJSON(path string, v any) bool {
	data, err := os.ReadFile(path)
	return err == nil && json.Unmarshal(data, v) == nil
}

func saveJSON(path string, v any) error {
	data, err := marshal(v)
	if err != nil {
		return err
	}
	return atomicfile.Write(path, data)
}
