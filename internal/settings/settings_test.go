package settings

import (
	"os"
	"slices"
	"testing"
)

func TestLoadDefaultsAndRoundTrip(t *testing.T) {
	t.Setenv("SIMPLETOKEN_DATA_DIR", t.TempDir())
	s := Load()
	if s.Range != "1M" || s.SeriesColors != "ink" || len(s.CardOrder) != len(Cards) {
		t.Fatalf("defaults: %+v", s)
	}
	s.Palette, s.PanelLimitStyle = "signal", "rings"
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	got := Load()
	if got.Palette != "signal" || got.PanelLimitStyle != "gauges" {
		t.Fatalf("round trip: palette %q, style %q", got.Palette, got.PanelLimitStyle)
	}
}

func TestImportDefaultsKeepsKnownKeys(t *testing.T) {
	s := Default()
	s.importDefaults(map[string]any{
		"dashboardRange": "3M", "statsExactNumber": true, "panelLimitStyle": "bars",
		"menuBarItems": []any{"claude.weekly", "today.tokens"}, "alertThresholds": []any{60.0, 90.0},
		"modelColorMode": "vendor", "panelWidth": "not a number",
	})
	s.normalize()
	if s.Range != "3M" || !s.ExactNumbers || s.PanelLimitStyle != "meters" || s.SeriesColors != "ink" {
		t.Fatalf("import: %+v", s)
	}
	if !slices.Equal(s.MenuBarItems, []string{"claude.weekly", "today.tokens"}) || s.TopThreshold() != 90 {
		t.Fatalf("items %v thresholds %v", s.MenuBarItems, s.AlertThresholds)
	}
	if s.PanelWidth != 360 {
		t.Fatalf("a malformed value must keep the default, got %d", s.PanelWidth)
	}
	_ = os.Getenv
}

func TestDecodePlistSkipsDataAndDates(t *testing.T) {
	// 0.1.x keeps a binary dashboardLayout, which JSON cannot hold; it must not cost the other keys.
	xml := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>dashboardLayout</key><data>AAEC</data>
	<key>lastRun</key><date>2026-10-21T00:00:00Z</date>
	<key>dashboardRange</key><string>3M</string>
	<key>panelWidth</key><integer>420</integer>
	<key>alertThresholds</key><array><real>60</real><integer>90</integer><data>AA==</data></array>
	<key>statsExactNumber</key><true/>
	<key>limitShowUsed</key><false/>
	<key>widgetSizes</key><dict><key>models</key><string>large</string><key>cost</key><string>M</string></dict>
	<key>cardAccents</key><dict><key>card.hero</key><string>blue</string></dict>
</dict>
</plist>`
	m, err := decodePlist([]byte(xml))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m["dashboardLayout"]; ok {
		t.Fatal("data values must be dropped")
	}
	s := Default()
	s.importDefaults(m)
	s.normalize()
	if s.Range != "3M" || s.PanelWidth != 420 || !s.ExactNumbers || s.LimitShowUsed || s.CardSizes["models"] != "L" || s.CardSizes["cost"] != "M" || s.CardAccents["hero"] != "blue" {
		t.Fatalf("import: %+v", s)
	}
	if !slices.Equal(s.AlertThresholds, []float64{60, 90}) {
		t.Fatalf("thresholds %v", s.AlertThresholds)
	}
}
