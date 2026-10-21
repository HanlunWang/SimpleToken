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
