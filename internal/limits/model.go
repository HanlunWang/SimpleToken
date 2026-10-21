// Package limits reads the plan limits of each provider (Claude, Codex, Cursor) and normalises them into windows.
package limits

import (
	"errors"
	"time"
)

// Provider is a limit source. The UI picks colour and mark by it; they never follow the ranking.
type Provider string

const (
	Claude Provider = "claude"
	Codex  Provider = "codex"
	Cursor Provider = "cursor"
)

// Providers lists every provider in display order.
var Providers = []Provider{Claude, Codex, Cursor}

// DisplayName is the provider's name in the UI.
func (p Provider) DisplayName() string {
	switch p {
	case Claude:
		return "Claude"
	case Codex:
		return "Codex"
	case Cursor:
		return "Cursor"
	}
	return string(p)
}

// Kind is the type of a window.
type Kind string

const (
	Session Kind = "session"
	Weekly  Kind = "weekly"
	Fable   Kind = "fable"
	Model   Kind = "model"
)

// Window is one normalised limit window. Claude: 5 h session / weekly / Fable; Codex: weekly (maybe session) plus
// per-model extras (Kind Model, Title = model); Cursor: the weekly included usage shared by Grok Bot and Cursor and,
// as a titled extra, the on-demand spend against its limit.
type Window struct {
	Kind        Kind       `json:"kind"`
	UsedPercent float64    `json:"usedPercent"`
	ResetsAt    *time.Time `json:"resetsAt,omitempty"`
	// WindowMinutes is the window length, for elapsed time and pace; inferred from Kind when zero.
	WindowMinutes int    `json:"windowMinutes,omitempty"`
	Title         string `json:"title,omitempty"`
}

// NewWindow clamps the percentage to 0…100.
func NewWindow(kind Kind, used float64, resetsAt *time.Time, minutes int, title string) Window {
	return Window{Kind: kind, UsedPercent: max(0, min(100, used)), ResetsAt: resetsAt, WindowMinutes: minutes, Title: title}
}

// ID identifies the window within a provider.
func (w Window) ID() string { return string(w.Kind) + "|" + w.Title }

// Remaining is 100 − used, clamped.
func (w Window) Remaining() float64 { return max(0, min(100, 100-w.UsedPercent)) }

// Span is the window length: the explicit value, otherwise the kind's standard length.
func (w Window) Span() time.Duration {
	if w.WindowMinutes > 0 {
		return time.Duration(w.WindowMinutes) * time.Minute
	}
	if w.Kind == Session {
		return 5 * time.Hour
	}
	return 7 * 24 * time.Hour
}

// Elapsed is the fraction of the window elapsed (0…1); ok is false without a reset time.
func (w Window) Elapsed(now time.Time) (float64, bool) {
	if w.ResetsAt == nil {
		return 0, false
	}
	f := 1 - float64(w.ResetsAt.Sub(now))/float64(w.Span())
	return max(0, min(1, f)), true
}

// Projected is the usage at reset at the current pace (%); ok is false early in the window (< 10 %), where
// extrapolation is unreliable.
func (w Window) Projected(now time.Time) (float64, bool) {
	e, ok := w.Elapsed(now)
	if !ok || w.UsedPercent <= 0 || e < 0.1 {
		return 0, false
	}
	return w.UsedPercent / e, true
}

// Snapshot is one provider's limits.
type Snapshot struct {
	Provider     Provider  `json:"provider"`
	Windows      []Window  `json:"windows"`
	AccountLabel string    `json:"accountLabel"` // plan label: Max 20x, Pro, X Pass Premium…
	UpdatedAt    time.Time `json:"updatedAt"`
}

// Window returns the first window of a kind.
func (s Snapshot) Window(k Kind) (Window, bool) {
	for _, w := range s.Windows {
		if w.Kind == k {
			return w, true
		}
	}
	return Window{}, false
}

// Primary is the main window for the UI: session, then weekly, then the first one.
func (s Snapshot) Primary() (Window, bool) {
	if w, ok := s.Window(Session); ok {
		return w, true
	}
	if w, ok := s.Window(Weekly); ok {
		return w, true
	}
	if len(s.Windows) > 0 {
		return s.Windows[0], true
	}
	return Window{}, false
}

// Errors a probe reports.
var (
	ErrNotConfigured = errors.New("not configured")      // no credentials / no CLI
	ErrInvalidCookie = errors.New("invalid session key") // not sk-ant-
	ErrUnauthorized  = errors.New("unauthorized")        // 401/403: expired
	ErrRateLimited   = errors.New("rate limited")        // 429
	ErrChallenge     = errors.New("blocked by a challenge page")
)

// Unavailable is any other failure, with a reason for the UI.
type Unavailable struct{ Reason string }

func (e Unavailable) Error() string { return e.Reason }
