package tokscale

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// DefaultCursorSyncInterval is the minimum gap between automatic Cursor syncs: a sync pulls the account's whole
// usage history (tens of seconds, a few MB).
const DefaultCursorSyncInterval = 59 * time.Minute

// CursorSync keeps tokscale's Cursor cache (~/.config/tokscale/cursor-cache) current. Cursor and Grok Bot keep no
// usage logs on the Mac: their usage lives in the Cursor account, and tokscale fetches it into that cache, which its
// scans then read like any other client. The first sync signs tokscale in from the Cursor desktop app's session.
// Nothing runs unless Cursor is signed in on this Mac.
//
// CursorSync is safe for concurrent use.
type CursorSync struct {
	runner *Runner
	// signedIn reports whether a Cursor sign-in exists (the limits package's Cursor token lookup).
	signedIn func() bool

	// CredentialsPath is tokscale's own Cursor credentials file; only its existence is checked.
	CredentialsPath string
	// Interval is the minimum gap between SyncIfDue runs.
	Interval time.Duration

	mu      sync.Mutex
	last    time.Time
	lastErr string
}

// NewCursorSync returns a sync that runs through runner. signedIn reports whether Cursor is signed in on this
// Mac; nil means never.
func NewCursorSync(runner *Runner, signedIn func() bool) *CursorSync {
	home, _ := os.UserHomeDir()
	return &CursorSync{
		runner:          runner,
		signedIn:        signedIn,
		CredentialsPath: filepath.Join(home, ".config", "tokscale", "cursor-credentials.json"),
		Interval:        DefaultCursorSyncInterval,
	}
}

// Available reports whether there is a Cursor sign-in to sync from.
func (c *CursorSync) Available() bool { return c.signedIn != nil && c.signedIn() }

// Sync updates the cache, signing tokscale in first when it has no Cursor account yet. It returns a short error
// description, or "" on success or when Cursor is not signed in. Errors are reported, not fatal: the scans go on
// with whatever the cache holds.
func (c *CursorSync) Sync(ctx context.Context) string {
	if !c.Available() {
		return ""
	}
	if !fileExists(c.CredentialsPath) {
		out, err := c.runner.exec(ctx, []string{"cursor", "login", "--name", "simpletoken"}, 60*time.Second)
		if err != nil || out.ExitCode != 0 {
			return "tokscale could not sign in to Cursor"
		}
	}
	out, err := c.runner.exec(ctx, []string{"cursor", "sync", "--json"}, 240*time.Second)
	if err != nil {
		return "tokscale cursor sync did not finish"
	}
	var res map[string]any
	if json.Unmarshal(out.Stdout, &res) != nil || res == nil {
		if out.ExitCode == 0 {
			return ""
		}
		return "tokscale cursor sync failed"
	}
	if msg, ok := res["error"].(string); ok && msg != "" {
		return msg
	}
	return ""
}

// SyncIfDue runs Sync when Interval has passed since the last attempt (or there was none) and records its
// result for LastError. Use it as the collector's before-full-scan hook.
func (c *CursorSync) SyncIfDue(ctx context.Context) {
	c.mu.Lock()
	due := c.last.IsZero() || time.Since(c.last) > c.Interval
	if due {
		c.last = time.Now()
	}
	c.mu.Unlock()
	if !due {
		return
	}
	msg := c.Sync(ctx)
	c.mu.Lock()
	c.lastErr = msg
	c.mu.Unlock()
}

// MarkDue makes the next SyncIfDue run regardless of the interval (a manual refresh syncs Cursor as well).
func (c *CursorSync) MarkDue() {
	c.mu.Lock()
	c.last = time.Time{}
	c.mu.Unlock()
}

// LastError is the last SyncIfDue result: "" when it went through or never ran.
func (c *CursorSync) LastError() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastErr
}
