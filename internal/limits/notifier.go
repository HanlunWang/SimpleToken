package limits

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"

	"github.com/HanlunWang/SimpleToken/internal/paths"
)

// NotifiedPath is where the notifier remembers what it has posted (the Swift app kept this in UserDefaults).
func NotifiedPath() string { return filepath.Join(paths.Dir(), "limit-notified.json") }

// maxNotifiedRecords bounds the record; older periods are useless.
const maxNotifiedRecords = 200

// Alert is one limit notification to post: a window crossed Threshold (the highest threshold it has crossed).
type Alert struct {
	Provider  Provider
	Window    Window
	Threshold float64
}

// Notifier decides which limit alerts to post. Each threshold fires once per window period (persisted, so a
// relaunch does not repeat it); when several thresholds are crossed at once only the highest is posted. Titled
// extras (Kind Model) never alert. Posting is the caller's job. Safe for concurrent use.
type Notifier struct {
	path     string
	mu       sync.Mutex
	loaded   bool
	order    []string // insertion order, oldest first
	notified map[string]bool
}

// NewNotifier persists to path (NotifiedPath for the standard file; "" keeps the record in memory only).
func NewNotifier(path string) *Notifier {
	return &Notifier{path: path, notified: map[string]bool{}}
}

// Check returns the alerts to post for these snapshots and records them. Hidden providers are skipped; the caller
// skips Check entirely while alerts are turned off.
func (n *Notifier) Check(snapshots []Snapshot, thresholds []float64, hidden map[Provider]bool) []Alert {
	ts := slices.Clone(thresholds)
	slices.Sort(ts)
	if len(ts) == 0 {
		return nil
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.load()

	var alerts []Alert
	changed := false
	for _, snap := range snapshots {
		if hidden[snap.Provider] {
			continue
		}
		for _, w := range snap.Windows {
			if w.Kind == Model {
				continue
			}
			var crossed []float64
			for _, t := range ts {
				if w.UsedPercent >= t {
					crossed = append(crossed, t)
				}
			}
			if len(crossed) == 0 {
				continue
			}
			top := crossed[len(crossed)-1]
			// Period: the reset time in whole hours (second-level jitter between probes is not a new period).
			period := int64(0)
			if w.ResetsAt != nil {
				period = w.ResetsAt.Unix() / 3600
			}
			id := func(t float64) string {
				return fmt.Sprintf("%s|%s|%d|%d", snap.Provider, w.ID(), period, int(t))
			}
			topFresh := false
			for _, t := range crossed {
				key := id(t)
				if n.notified[key] {
					continue
				}
				n.notified[key] = true
				n.order = append(n.order, key)
				changed = true
				if t == top {
					topFresh = true
				}
			}
			if topFresh {
				alerts = append(alerts, Alert{Provider: snap.Provider, Window: w, Threshold: top})
			}
		}
	}
	if changed {
		if extra := len(n.order) - maxNotifiedRecords; extra > 0 {
			for _, k := range n.order[:extra] {
				delete(n.notified, k)
			}
			n.order = slices.Clone(n.order[extra:])
		}
		n.save()
	}
	return alerts
}

func (n *Notifier) load() {
	if n.loaded {
		return
	}
	n.loaded = true
	if n.path == "" {
		return
	}
	data, err := os.ReadFile(n.path)
	if err != nil {
		return
	}
	var keys []string
	if json.Unmarshal(data, &keys) != nil {
		return
	}
	for _, k := range keys {
		if !n.notified[k] {
			n.notified[k] = true
			n.order = append(n.order, k)
		}
	}
}

func (n *Notifier) save() {
	if n.path == "" {
		return
	}
	data, err := json.Marshal(n.order)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(n.path), 0o755); err != nil {
		return
	}
	tmp := n.path + ".tmp"
	if os.WriteFile(tmp, data, 0o644) == nil {
		_ = os.Rename(tmp, n.path)
	}
}
