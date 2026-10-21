// Package settings holds every preference of the app. They are stored as JSON in the data directory under the
// same keys the Swift 0.1.x releases used in UserDefaults, and imported from there once.
package settings

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/atomicfile"
	"github.com/HanlunWang/SimpleToken/internal/paths"
	"github.com/HanlunWang/SimpleToken/internal/proc"
)

// Settings is every preference. JSON keys match the old UserDefaults keys where one existed.
type Settings struct {
	// General
	FloatingWindow  bool   `json:"floatingWindow"`
	ClickOpensPanel bool   `json:"clickOpensPanel"`
	ExactNumbers    bool   `json:"statsExactNumber"`
	Range           string `json:"dashboardRange"`  // 1D 1W 1M 3M 6M YTD 1Y ALL
	Metric          string `json:"dashboardMetric"` // tokens cost messages
	AutoUpdate      bool   `json:"autoUpdate"`

	// Appearance (new in v2)
	Theme         string `json:"theme"`         // dark light system
	Palette       string `json:"palette"`       // paper graphite signal ice peach phosphor
	SeriesColors  string `json:"seriesColors"`  // ink vendor
	VendorMarks   string `json:"vendorMarks"`   // color mono
	PanelMaterial string `json:"panelMaterial"` // glass solid

	// Refresh
	LiveRefreshSeconds int `json:"liveRefreshSeconds"`
	FullRefreshMinutes int `json:"fullRefreshMinutes"`

	// Limits and alerts
	LimitShowUsed         bool      `json:"limitShowUsed"`
	AlertThresholds       []float64 `json:"alertThresholds"`
	LimitNotifications    bool      `json:"limitNotifications"`
	HiddenLimitProviders  []string  `json:"hiddenLimitProviders"`
	LimitShowPace         bool      `json:"limitShowPace"`
	LimitShowModelBuckets bool      `json:"limitShowModelBuckets"`

	// Menu bar
	MenuBarItems      []string `json:"menuBarItems"`
	MenuBarStyle      string   `json:"menuBarStyle"` // text stacked dense ring rings bar
	MenuBarShowLabels bool     `json:"menuBarShowLabels"`
	MenuBarAlertColor bool     `json:"menuBarAlertColor"`
	MenuBarShowIcon   bool     `json:"menuBarShowIcon"`
	MenuBarShowPace   bool     `json:"menuBarShowPace"`

	// Panel
	PanelSections   []string `json:"panelSections"`
	PanelWidth      int      `json:"panelWidth"`
	PanelLimitStyle string   `json:"panelLimitStyle"` // meters gauges (0.1.x: bars rings)
	PanelListCount  int      `json:"panelListCount"`
	PanelTodayStyle string   `json:"panelTodayStyle"` // cumulative bars
	PanelShowResets bool     `json:"panelShowResets"`

	// Models and tools
	ModelColorOverrides map[string]string `json:"modelColorOverrides"`
	ToolColorOverrides  map[string]string `json:"toolColorOverrides"`
	ModelAliases        map[string]string `json:"modelAliases"`
	ExcludedModels      []string          `json:"excludedModels"`
	ExcludedClients     []string          `json:"excludedClients"`
	SeparateModels      int               `json:"separateModels"`

	// Widgets
	CardOrder   []string          `json:"cardOrder"`
	HiddenCards []string          `json:"hiddenCards"`
	CardSizes   map[string]string `json:"widgetSizes"`
	CardAccents map[string]string `json:"cardAccents"`
	// Per-card options
	HeroShowPrevious       bool   `json:"heroShowPrevious"`
	IntradayMinutes        int    `json:"intradayMinutes"`
	UsageStack             string `json:"usageStack"` // model tool none
	UsageShowAverage       bool   `json:"usageShowAverage"`
	PunchcardDays          int    `json:"punchcardDays"`
	CalendarMetric         string `json:"calendarMetric"`
	CalendarWeeks          int    `json:"calendarWeeks"`
	CompositionPeriod      string `json:"compositionPeriod"`
	CompositionShowHitRate bool   `json:"compositionShowHitRate"`
	CostShowLastMonth      bool   `json:"costShowLastMonth"`
	CostShowProjection     bool   `json:"costShowProjection"`
	CostShowDailyBars      bool   `json:"costShowDailyBars"`
	ModelsShowSparklines   bool   `json:"modelsShowSparklines"`
	ModelsMetric           string `json:"modelsMetric"`

	// Bookkeeping
	ImportedFromUserDefaults bool `json:"importedFromUserDefaults"`
}

// Cards is every widget in default order. Stats are widgets of their own.
var Cards = []string{
	"hero", "stat.average", "stat.peak", "stat.active", "stat.perMillion",
	"stat.totalCost", "stat.messages", "stat.topModel", "stat.weekday",
	"limits", "models", "map", "flow", "usage", "calendar", "punchcard", "tools", "composition", "cost",
}

// DefaultHidden are the stat widgets hidden on a fresh install.
var DefaultHidden = []string{"stat.totalCost", "stat.messages", "stat.topModel", "stat.weekday"}

// Default returns the settings of a fresh install.
func Default() Settings {
	return Settings{
		ClickOpensPanel: true, Range: "1M", Metric: "tokens", AutoUpdate: true,
		Theme: "dark", Palette: "paper", SeriesColors: "ink", VendorMarks: "color", PanelMaterial: "glass",
		LiveRefreshSeconds: 30, FullRefreshMinutes: 15,
		LimitShowUsed: true, AlertThresholds: []float64{50, 80}, LimitShowPace: true, LimitShowModelBuckets: true,
		MenuBarItems: []string{"claude.session"}, MenuBarStyle: "text", MenuBarAlertColor: true, MenuBarShowIcon: true, MenuBarShowPace: true,
		PanelSections: []string{"claude", "codex", "cursor", "today", "models"}, PanelWidth: 360, PanelLimitStyle: "meters",
		PanelListCount: 4, PanelTodayStyle: "cumulative", PanelShowResets: true,
		ModelColorOverrides: map[string]string{}, ToolColorOverrides: map[string]string{}, ModelAliases: map[string]string{},
		SeparateModels: 4,
		CardOrder:      slices.Clone(Cards), HiddenCards: slices.Clone(DefaultHidden),
		CardSizes: map[string]string{}, CardAccents: map[string]string{},
		HeroShowPrevious: true, IntradayMinutes: 60, UsageStack: "model", UsageShowAverage: true, PunchcardDays: 30,
		CalendarMetric: "tokens", CompositionPeriod: "auto", CompositionShowHitRate: true,
		CostShowLastMonth: true, CostShowProjection: true, CostShowDailyBars: true, ModelsShowSparklines: true, ModelsMetric: "tokens",
	}
}

// Load reads settings.json; when it does not exist yet, it imports the Swift app's UserDefaults once.
func Load() Settings {
	s := Default()
	if data, err := os.ReadFile(paths.Settings()); err == nil {
		_ = json.Unmarshal(data, &s) // keys not in the file keep their defaults
		s.normalize()
		return s
	}
	if os.Getenv("SIMPLETOKEN_DATA_DIR") == "" {
		if old, err := readUserDefaults(BundleID); err == nil && len(old) > 0 {
			s.importDefaults(old)
		}
	}
	s.ImportedFromUserDefaults = true
	s.normalize()
	_ = s.Save()
	return s
}

// Save writes settings.json atomically.
func (s Settings) Save() error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(paths.Settings(), data)
}

// normalize repairs values a hand edit or an old version may have left out of range.
func (s *Settings) normalize() {
	d := Default()
	if !slices.Contains([]string{"1D", "1W", "1M", "3M", "6M", "YTD", "1Y", "ALL"}, s.Range) {
		s.Range = d.Range
	}
	if !slices.Contains([]string{"tokens", "cost", "messages"}, s.Metric) {
		s.Metric = d.Metric
	}
	switch s.PanelLimitStyle {
	case "rings":
		s.PanelLimitStyle = "gauges"
	case "bars":
		s.PanelLimitStyle = "meters"
	case "gauges", "meters":
	default:
		s.PanelLimitStyle = d.PanelLimitStyle
	}
	if s.LiveRefreshSeconds <= 0 {
		s.LiveRefreshSeconds = d.LiveRefreshSeconds
	}
	if s.FullRefreshMinutes <= 0 {
		s.FullRefreshMinutes = d.FullRefreshMinutes
	}
	if s.PanelWidth < 300 {
		s.PanelWidth = d.PanelWidth
	}
	// Every known card appears once in the order (new cards are appended).
	seen := map[string]bool{}
	var order []string
	for _, c := range s.CardOrder {
		if slices.Contains(Cards, c) && !seen[c] {
			seen[c] = true
			order = append(order, c)
		}
	}
	for _, c := range Cards {
		if !seen[c] {
			order = append(order, c)
		}
	}
	s.CardOrder = order
	for _, m := range []*map[string]string{&s.ModelColorOverrides, &s.ToolColorOverrides, &s.ModelAliases, &s.CardSizes, &s.CardAccents} {
		if *m == nil {
			*m = map[string]string{}
		}
	}
	if len(s.AlertThresholds) == 0 {
		s.AlertThresholds = d.AlertThresholds
	}
	// 0.1.x spelled sizes out and keyed accents "card.<id>".
	for id, v := range s.CardSizes {
		if n, ok := map[string]string{"small": "S", "medium": "M", "large": "L", "wide": "W"}[v]; ok {
			s.CardSizes[id] = n
		}
	}
	for k, v := range s.CardAccents {
		if id, ok := strings.CutPrefix(k, "card."); ok {
			delete(s.CardAccents, k)
			s.CardAccents[id] = v
		}
	}
}

// TopThreshold is the highest alert threshold (the menu bar turns red from it), 100 when none is set.
func (s Settings) TopThreshold() float64 {
	t := 0.0
	for _, v := range s.AlertThresholds {
		t = max(t, v)
	}
	if t == 0 {
		return 100
	}
	return t
}

// BundleID is the app's identifier, the same as the Swift releases so data, login item and Keychain carry over.
const BundleID = "dev.hanlun.simpletoken"

// readUserDefaults exports a defaults domain as an XML property list (defaults → plist → plutil) and decodes it.
// Values JSON cannot hold (dates, data, such as 0.1.x's dashboardLayout) are dropped, not fatal.
func readUserDefaults(domain string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := proc.Run(ctx, "/bin/sh", []string{"-c", "/usr/bin/defaults export " + domain + " - | /usr/bin/plutil -convert xml1 -o - -"}, 5*time.Second)
	if err != nil {
		return nil, err
	}
	return decodePlist(out.Stdout)
}

// decodePlist reads the top-level dictionary of an XML property list. Strings, numbers, booleans, arrays and
// dictionaries come through; dates and data are skipped.
func decodePlist(data []byte) (map[string]any, error) {
	d := xml.NewDecoder(bytes.NewReader(data))
	for {
		tok, err := d.Token()
		if err != nil {
			return nil, err
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "dict" {
			v, err := plistValue(d, se)
			if err != nil {
				return nil, err
			}
			return v.(map[string]any), nil
		}
	}
}

func plistValue(d *xml.Decoder, se xml.StartElement) (any, error) {
	switch se.Name.Local {
	case "dict", "array":
		m, a := map[string]any{}, []any{}
		key := ""
		for {
			tok, err := d.Token()
			if err != nil {
				return nil, err
			}
			switch t := tok.(type) {
			case xml.StartElement:
				if t.Name.Local == "key" {
					if err := d.DecodeElement(&key, &t); err != nil {
						return nil, err
					}
					continue
				}
				v, err := plistValue(d, t)
				if err != nil {
					return nil, err
				}
				if v == nil {
					continue
				}
				if se.Name.Local == "dict" {
					m[key] = v
				} else {
					a = append(a, v)
				}
			case xml.EndElement:
				if se.Name.Local == "dict" {
					return m, nil
				}
				return a, nil
			}
		}
	case "true", "false":
		return se.Name.Local == "true", d.Skip()
	}
	var text string
	if err := d.DecodeElement(&text, &se); err != nil {
		return nil, err
	}
	switch se.Name.Local {
	case "string":
		return text, nil
	case "integer":
		n, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64)
		if err != nil {
			return nil, nil
		}
		return n, nil
	case "real":
		f, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
		if err != nil {
			return nil, nil
		}
		return f, nil
	}
	return nil, nil // date, data
}

// importDefaults copies the keys the Swift app wrote. Unknown and malformed values are skipped.
func (s *Settings) importDefaults(m map[string]any) {
	data, err := json.Marshal(m)
	if err != nil {
		return
	}
	// Keys share names, so a second unmarshal onto the defaults picks up every value of the right type. Values of
	// the wrong type fail the whole decode, so decode key by key.
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil {
		return
	}
	for k, v := range raw {
		one, _ := json.Marshal(map[string]json.RawMessage{k: v})
		_ = json.Unmarshal(one, s)
	}
	// 0.1.x kept these under other names or shapes.
	if o, ok := m["modelColorMode"].(string); ok && o == "vendor" {
		// The v2 default is ink (owner decision, 2026-10-21); vendor stays one switch away.
		s.SeriesColors = "ink"
	}
	if items, ok := m["menuBarItems"].([]any); ok {
		s.MenuBarItems = s.MenuBarItems[:0]
		for _, it := range items {
			if v, ok := it.(string); ok {
				s.MenuBarItems = append(s.MenuBarItems, v)
			}
		}
	}
}
