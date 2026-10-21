package collector

import (
	"bytes"
	"encoding/json"
	"os"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/atomicfile"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Anchor is the last full scan (collector-anchor.json). Watch ticks derive month and all time from it
// arithmetically; persisting it means a restart shows numbers at once instead of paying for three scans first.
// A different day or scan configuration (Fingerprint) makes it stale.
type Anchor struct {
	AllTime     usage.Period `json:"allTime"`
	CollectedAt time.Time    `json:"collectedAt"`
	DayKey      string       `json:"dayKey"`
	Fingerprint string       `json:"fingerprint"`
	Month       usage.Period `json:"month"`
	Today       usage.Period `json:"today"`
}

// LoadAnchor reads the anchor at path; ok is false when it is missing, unreadable or from another configuration.
func LoadAnchor(path, fingerprint string) (a Anchor, ok bool) {
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &a) != nil || a.Fingerprint != fingerprint {
		return Anchor{}, false
	}
	// Older anchors lack byPair (and slices may lack fields): missing means empty
	for _, p := range []*usage.Period{&a.Today, &a.Month, &a.AllTime} {
		fillMaps(p)
	}
	return a, true
}

// SaveAnchor writes the anchor atomically. Dates are whole-second UTC ("2026-10-21T19:26:42Z"), the ISO 8601
// form the Swift releases wrote and read.
func SaveAnchor(path string, a Anchor) error {
	a.CollectedAt = isoTime(a.CollectedAt)
	data, err := marshal(a)
	if err != nil {
		return err
	}
	return atomicfile.Write(path, data)
}

func fillMaps(p *usage.Period) {
	if p.ByModel == nil {
		p.ByModel = map[string]usage.Slice{}
	}
	if p.ByClient == nil {
		p.ByClient = map[string]usage.Slice{}
	}
	if p.ByPair == nil {
		p.ByPair = map[string]usage.Slice{}
	}
}

func isoTime(t time.Time) time.Time { return t.UTC().Truncate(time.Second) }

func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}
