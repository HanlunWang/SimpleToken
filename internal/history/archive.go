// Package history keeps the per-day usage archive (daily-history-archive.json): tokscale graph output merged
// into tool × model observations per day, plus the old Token Monitor archive absorbed once.
package history

import (
	"bytes"
	"cmp"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/HanlunWang/SimpleToken/internal/atomicfile"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// Archive is the daily history, schema version 1: the same file the Swift releases and the Electron Token
// Monitor wrote, so their history imports directly. Struct fields are in JSON key order (the Swift encoder sorted
// keys), so a save reproduces its layout.
type Archive struct {
	Days    map[string]Day `json:"days"`
	Version int            `json:"version"`
}

// Day is one day of the archive. Observations are keyed by ObservationKey.
type Day struct {
	ActiveTimeMs *float64               `json:"activeTimeMs,omitempty"`
	Date         string                 `json:"date"`
	Observations map[string]Observation `json:"observations"`
}

// Observation is one tool × model row of a day.
type Observation struct {
	Client          string  `json:"client"`
	Cost            float64 `json:"cost"`
	Messages        int64   `json:"messages"`
	ModelID         string  `json:"modelId"`
	ProviderID      *string `json:"providerId,omitempty"`
	ReasoningTokens *int64  `json:"reasoningTokens,omitempty"`
	Tokens          int64   `json:"tokens"`
}

// NewArchive returns an empty version 1 archive.
func NewArchive() *Archive { return &Archive{Version: 1, Days: map[string]Day{}} }

// ObservationKey is the observation map key: the JSON array [client, modelId], byte for byte as the Swift
// releases wrote it (JavaScript's JSON.stringify in the Electron app, except that Swift escapes '/').
// Keys must stay identical or a merge stores the same row twice.
func ObservationKey(client, modelID string) string {
	var b strings.Builder
	b.WriteString(`[`)
	writeJSONString(&b, client)
	b.WriteString(`,`)
	writeJSONString(&b, modelID)
	b.WriteString(`]`)
	return b.String()
}

func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '/':
			b.WriteString(`\/`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

// Clone returns a deep copy.
func (a *Archive) Clone() *Archive {
	out := &Archive{Version: a.Version, Days: make(map[string]Day, len(a.Days))}
	for k, d := range a.Days {
		nd := Day{Date: d.Date, Observations: make(map[string]Observation, len(d.Observations))}
		if d.ActiveTimeMs != nil {
			v := *d.ActiveTimeMs
			nd.ActiveTimeMs = &v
		}
		for ok, o := range d.Observations {
			nd.Observations[ok] = o.clone()
		}
		out.Days[k] = nd
	}
	return out
}

func (o Observation) clone() Observation {
	if o.ProviderID != nil {
		v := *o.ProviderID
		o.ProviderID = &v
	}
	if o.ReasoningTokens != nil {
		v := *o.ReasoningTokens
		o.ReasoningTokens = &v
	}
	return o
}

func (o Observation) equal(p Observation) bool {
	return o.Client == p.Client && o.ModelID == p.ModelID && o.Tokens == p.Tokens && o.Cost == p.Cost &&
		o.Messages == p.Messages && ptrEqual(o.ProviderID, p.ProviderID) && ptrEqual(o.ReasoningTokens, p.ReasoningTokens)
}

func ptrEqual[T comparable](a, b *T) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func (a *Archive) day(date string) Day {
	d, ok := a.Days[date]
	if !ok {
		return Day{Date: date, Observations: map[string]Observation{}}
	}
	if d.Observations == nil {
		d.Observations = map[string]Observation{}
	}
	return d
}

// Merge folds a tokscale graph into the archive. Rows for the same (tool, model, day) within one graph are
// summed (shards of one source); against existing observations they replace whole: more tokens wins, ties
// compare messages, and a full tie still replaces, since equal usage may bring corrected pricing or fuller
// metadata and whole replacement keeps tokens and cost from the same collection. Days after todayKey are dropped.
func (a *Archive) Merge(g usage.Graph, todayKey string) {
	if a.Days == nil {
		a.Days = map[string]Day{}
	}
	for _, gd := range g.Contributions {
		date := gd.Date
		if date == "" || date > todayKey {
			continue
		}
		// 1) Aggregate within the graph (duplicate rows are summed)
		incoming := map[string]Observation{}
		for _, c := range gd.Clients {
			// tokscale always names both; a row missing either cannot be keyed
			if c.Client == "" || c.ModelID == "" {
				continue
			}
			name := usage.NormalizeClient(c.Client, c.ModelID)
			tokens := c.CollapsedTokens()
			cost := max(0, c.Cost)
			messages := max(0, c.Messages)
			if tokens == 0 && cost == 0 && messages == 0 {
				continue
			}
			reasoning := c.Tokens.Reasoning
			key := ObservationKey(name, c.ModelID)
			if prev, ok := incoming[key]; ok {
				prev.Tokens += tokens
				prev.Cost += cost
				prev.Messages += messages
				r := reasoning
				if prev.ReasoningTokens != nil {
					r += *prev.ReasoningTokens
				}
				prev.ReasoningTokens = &r
				if prev.ProviderID == nil {
					prev.ProviderID = optString(c.ProviderID)
				}
				incoming[key] = prev
				continue
			}
			o := Observation{Client: name, ModelID: c.ModelID, ProviderID: optString(c.ProviderID),
				Tokens: tokens, Cost: cost, Messages: messages}
			if reasoning > 0 {
				o.ReasoningTokens = &reasoning
			}
			incoming[key] = o
		}

		// 2) Replace whole in the archive (larger wins)
		entry := a.day(date)
		if gd.ActiveTimeMs > 0 {
			v := gd.ActiveTimeMs
			if entry.ActiveTimeMs != nil {
				v = max(v, *entry.ActiveTimeMs)
			}
			entry.ActiveTimeMs = &v
		}
		for key, o := range incoming {
			prev, had := entry.Observations[key]
			if shouldReplace(prev, had, o) {
				if o.ProviderID == nil && had {
					o.ProviderID = prev.ProviderID
				}
				entry.Observations[key] = o
			}
		}
		a.Days[date] = entry
	}
	a.pruneAfter(todayKey)
}

func shouldReplace(prev Observation, had bool, in Observation) bool {
	if !had {
		return true
	}
	if in.Tokens != prev.Tokens {
		return in.Tokens > prev.Tokens
	}
	if in.Messages != prev.Messages {
		return in.Messages > prev.Messages
	}
	return true
}

func (a *Archive) pruneAfter(todayKey string) {
	for k := range a.Days {
		if k > todayKey {
			delete(a.Days, k)
		}
	}
}

func optString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Absorb copies another archive of the same schema (the old Token Monitor's) into this one: larger wins per
// observation, as in Merge, so absorbing again changes nothing. It reports whether anything changed.
func (a *Archive) Absorb(other *Archive, todayKey string) bool {
	if a.Days == nil {
		a.Days = map[string]Day{}
	}
	changed := false
	for date, od := range other.Days {
		if date > todayKey {
			continue
		}
		entry := a.day(date)
		if od.ActiveTimeMs != nil {
			cur := 0.0
			if entry.ActiveTimeMs != nil {
				cur = *entry.ActiveTimeMs
			}
			if *od.ActiveTimeMs > cur {
				v := *od.ActiveTimeMs
				entry.ActiveTimeMs = &v
				changed = true
			}
		}
		for key, o := range od.Observations {
			prev, had := entry.Observations[key]
			if had && (prev.equal(o) || !(o.Tokens > prev.Tokens || (o.Tokens == prev.Tokens && o.Messages > prev.Messages))) {
				continue
			}
			entry.Observations[key] = o.clone()
			changed = true
		}
		a.Days[date] = entry
	}
	return changed
}

// Filter decides which observations count toward summaries (models and tools switched off in settings).
// analytics' usage filter satisfies it.
type Filter interface {
	Includes(client, model string) bool
}

// DaySummary is one day's totals.
type DaySummary struct {
	Date         string
	Tokens       int64
	Cost         float64
	Messages     int64
	ActiveTimeMs float64
	ByModel      map[string]int64
	CostByModel  map[string]float64
	ByClient     map[string]int64
}

// DailySummaries returns the days up to todayKey in date order, the last capDays of them (capDays <= 0: all).
// Observations the filter excludes count toward no field; a nil filter includes everything.
func (a *Archive) DailySummaries(capDays int, todayKey string, f Filter) []DaySummary {
	dates := make([]string, 0, len(a.Days))
	for k, d := range a.Days {
		if d.Date <= todayKey {
			dates = append(dates, k)
		}
	}
	slices.SortFunc(dates, func(x, y string) int { return cmp.Compare(a.Days[x].Date, a.Days[y].Date) })
	if capDays > 0 && len(dates) > capDays {
		dates = dates[len(dates)-capDays:]
	}
	out := make([]DaySummary, 0, len(dates))
	for _, k := range dates {
		d := a.Days[k]
		s := DaySummary{Date: d.Date, ByModel: map[string]int64{}, CostByModel: map[string]float64{}, ByClient: map[string]int64{}}
		if d.ActiveTimeMs != nil {
			s.ActiveTimeMs = *d.ActiveTimeMs
		}
		for _, o := range d.Observations {
			client := usage.NormalizeClient(o.Client, o.ModelID)
			if f != nil && !f.Includes(client, o.ModelID) {
				continue
			}
			s.Tokens += o.Tokens
			s.Cost += o.Cost
			s.Messages += o.Messages
			s.ByModel[o.ModelID] += o.Tokens
			s.CostByModel[o.ModelID] += o.Cost
			s.ByClient[client] += o.Tokens
		}
		out = append(out, s)
	}
	return out
}

// CatalogEntry is a model or tool ever seen, with its lifetime totals.
type CatalogEntry struct {
	Key string
	// Clients are the tools a model was used with (for a tool entry: the tool itself).
	Clients  map[string]bool
	Tokens   int64
	Cost     float64
	LastSeen string
}

// Catalog lists every model and tool ever seen, regardless of any filter (settings shows a switch for each),
// largest first.
type Catalog struct {
	Models  []CatalogEntry
	Clients []CatalogEntry
}

// Catalog builds the catalog.
func (a *Archive) Catalog() Catalog {
	models := map[string]*CatalogEntry{}
	clients := map[string]*CatalogEntry{}
	for _, d := range a.Days {
		for _, o := range d.Observations {
			client := usage.NormalizeClient(o.Client, o.ModelID)
			m := models[o.ModelID]
			if m == nil {
				m = &CatalogEntry{Key: o.ModelID, Clients: map[string]bool{}}
				models[o.ModelID] = m
			}
			m.Clients[client] = true
			m.Tokens += o.Tokens
			m.Cost += o.Cost
			m.LastSeen = max(m.LastSeen, d.Date)
			c := clients[client]
			if c == nil {
				c = &CatalogEntry{Key: client, Clients: map[string]bool{client: true}}
				clients[client] = c
			}
			c.Tokens += o.Tokens
			c.Cost += o.Cost
			c.LastSeen = max(c.LastSeen, d.Date)
		}
	}
	return Catalog{Models: sortedEntries(models), Clients: sortedEntries(clients)}
}

func sortedEntries(m map[string]*CatalogEntry) []CatalogEntry {
	out := make([]CatalogEntry, 0, len(m))
	for _, e := range m {
		out = append(out, *e)
	}
	slices.SortFunc(out, func(x, y CatalogEntry) int {
		if c := cmp.Compare(y.Tokens, x.Tokens); c != 0 {
			return c
		}
		return cmp.Compare(x.Key, y.Key)
	})
	return out
}

// Load reads an archive. A missing, unreadable or non-version-1 file is an error.
func Load(path string) (*Archive, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var a Archive
	if err := json.Unmarshal(data, &a); err != nil {
		return nil, err
	}
	if a.Version != 1 {
		return nil, fmt.Errorf("archive version %d", a.Version)
	}
	if a.Days == nil {
		a.Days = map[string]Day{}
	}
	return &a, nil
}

// Save writes the archive atomically.
func (a *Archive) Save(path string) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(a); err != nil {
		return err
	}
	return atomicfile.Write(path, bytes.TrimRight(buf.Bytes(), "\n"))
}
