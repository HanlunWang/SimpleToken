package limits

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseCodex(t *testing.T) {
	data, err := os.ReadFile("testdata/codex-rate-limits.json")
	if err != nil {
		t.Fatal(err)
	}
	limits, _ := decodeObject(data)
	now := time.Unix(1_792_000_000, 0)
	snap, err := parseCodex(limits, map[string]any{"account": map[string]any{"planType": "pro"}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Provider != Codex || snap.AccountLabel != "Pro 20x" || !snap.UpdatedAt.Equal(now) {
		t.Fatalf("snapshot: %+v", snap)
	}
	if len(snap.Windows) != 4 {
		t.Fatalf("windows: %+v", snap.Windows)
	}
	if w := snap.Windows[0]; w.Kind != Session || w.UsedPercent != 12 || w.WindowMinutes != 300 || !w.ResetsAt.Equal(time.Unix(1_792_454_406, 0)) {
		t.Fatalf("session: %+v", w)
	}
	if w := snap.Windows[1]; w.Kind != Weekly || w.UsedPercent != 48.5 {
		t.Fatalf("weekly: %+v", w)
	}
	if w := snap.Windows[2]; w.Kind != Model || w.Title != "GPT-5.3-Codex-Spark · Session" || w.UsedPercent != 3 {
		t.Fatalf("model session: %+v", w)
	}
	if w := snap.Windows[3]; w.Kind != Model || w.Title != "GPT-5.3-Codex-Spark · Weekly" || w.UsedPercent != 7 || w.ResetsAt != nil {
		t.Fatalf("model weekly: %+v", w)
	}
	// The plan falls back to the limits' planType without an account.
	snap, _ = parseCodex(limits, nil, now)
	if snap.AccountLabel != "Plus" {
		t.Fatalf("fallback plan: %q", snap.AccountLabel)
	}
	if _, err := parseCodex(map[string]any{}, nil, now); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("empty: %v", err)
	}
}

func TestCodexPlanLabel(t *testing.T) {
	for raw, want := range map[string]string{"pro": "Pro 20x", " ProLite ": "Pro 5x", "teams": "Team", "": "", "edu": "Edu"} {
		if got := CodexPlanLabel(raw); got != want {
			t.Errorf("CodexPlanLabel(%q) = %q, want %q", raw, got, want)
		}
	}
}

// fakeCodex writes a shell script that plays the app-server side of the exchange.
func fakeCodex(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCodexProbeAppServer(t *testing.T) {
	exe := fakeCodex(t, `
[ "$1 $2 $3 $4 $5" = "-s read-only -a never app-server" ] || { echo "bad args: $*" >&2; exit 2; }
env | grep -q '^CLAUDE_CODE_' && exit 3
read init
echo '{"method":"note","params":{}}'
echo '{"id":1,"result":{"userAgent":"fake"}}'
read initialized
read ratelimits
case "$ratelimits" in *account/rateLimits/read*) ;; *) exit 4 ;; esac
echo 'not json'
echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1792800000}}}}'
read account
echo '{"id":3,"result":{"account":{"planType":"plus"}}}'
cat >/dev/null
`)
	t.Setenv("CLAUDE_CODE_ENTRYPOINT", "test") // must not reach the child
	snap, err := CodexProbe{Executable: exe, Timeout: 10 * time.Second}.Probe(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snap.AccountLabel != "Plus" || len(snap.Windows) != 1 || snap.Windows[0].Kind != Weekly || snap.Windows[0].UsedPercent != 30 {
		t.Fatalf("snapshot: %+v", snap)
	}
}

func TestCodexProbeErrors(t *testing.T) {
	// The account call failing is tolerated; an RPC error on the limits is not.
	exe := fakeCodex(t, `
read l; echo '{"id":1,"result":{}}'
read l; read l
echo '{"id":2,"error":{"message":"not signed in"}}'
cat >/dev/null
`)
	_, err := CodexProbe{Executable: exe, Timeout: 10 * time.Second}.Probe(context.Background())
	if err == nil || err.Error() != "not signed in" {
		t.Fatalf("rpc error: %v", err)
	}

	exe = fakeCodex(t, "read l\nexit 0\n")
	_, err = CodexProbe{Executable: exe, Timeout: 10 * time.Second}.Probe(context.Background())
	if err == nil || !strings.Contains(err.Error(), "exited") {
		t.Fatalf("exit: %v", err)
	}

	exe = fakeCodex(t, "exec sleep 30\n")
	start := time.Now()
	_, err = CodexProbe{Executable: exe, Timeout: 300 * time.Millisecond}.Probe(context.Background())
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("timeout: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("timeout took %v", time.Since(start))
	}

	_, err = CodexProbe{Executable: filepath.Join(t.TempDir(), "missing")}.Probe(context.Background())
	if err == nil || !strings.HasPrefix(err.Error(), "Couldn't start codex") {
		t.Fatalf("missing binary: %v", err)
	}
}
