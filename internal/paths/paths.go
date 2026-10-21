// Package paths names SimpleToken's files. Everything lives under ~/Library/Application Support/SimpleToken,
// the same directory the Swift 0.1.x releases used, so an upgrade keeps all history.
package paths

import (
	"os"
	"path/filepath"
)

// Dir is the data directory. Tests and the demo mode point it elsewhere with SIMPLETOKEN_DATA_DIR.
func Dir() string {
	if d := os.Getenv("SIMPLETOKEN_DATA_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "SimpleToken")
}

// DailyArchive is the per-day history (tool × model rows per day).
func DailyArchive() string { return filepath.Join(Dir(), "daily-history-archive.json") }

// CollectorAnchor holds the last full scan, the base for derived month / all-time numbers.
func CollectorAnchor() string { return filepath.Join(Dir(), "collector-anchor.json") }

// HourlyHistory is the per-hour Claude Code history (the intraday scanner's archive).
func HourlyHistory() string { return filepath.Join(Dir(), "hourly-history.json") }

// TodayTimeline is today's cumulative samples.
func TodayTimeline() string { return filepath.Join(Dir(), "today-timeline.json") }

// Credentials holds the Claude session key (owner-pasted; file mode 0600).
func Credentials() string { return filepath.Join(Dir(), "credentials.json") }

// LegacyCredentials is the Electron Token Monitor's credentials file, imported once.
func LegacyCredentials() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Token Monitor", "credentials.json")
}

// Settings is the v2 settings file (the Swift app kept settings in UserDefaults; see the settings package for
// the one-time import).
func Settings() string { return filepath.Join(Dir(), "settings.json") }

// LegacyArchive is the Electron Token Monitor's history, imported once.
func LegacyArchive() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Token Monitor", "daily-history-archive.json")
}

// Ensure creates the data directory.
func Ensure() error { return os.MkdirAll(Dir(), 0o755) }
