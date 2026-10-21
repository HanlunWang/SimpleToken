// Package tokscale runs the bundled tokscale CLI: the period scans and the per-day graph that every usage number
// comes from, and the Cursor account sync that feeds tokscale's Cursor cache.
//
// Every spawn goes through one Runner, which serializes them: concurrent scans triple CPU and IO, and each one
// already costs about 1.2 CPU-s and a 570 MB child process.
package tokscale

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/proc"
	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// DefaultClients is the client list the app scans. Pure-JSONL tools cost nothing when they have no data; cursor
// (which carries Grok Bot) reads tokscale's synced cache of the Cursor account.
const DefaultClients = "claude,codex,copilot,opencode,gemini,cursor,grok"

// DefaultAllTimeSince is the start of the all-time scan.
const DefaultAllTimeSince = "2024-01-01"

// EnvBinary overrides the binary lookup.
const EnvBinary = "SIMPLETOKEN_TOKSCALE_PATH"

const scanTimeout = 120 * time.Second

// Scan is one of the three period scans.
type Scan int

const (
	// Today is the current local day (--today).
	Today Scan = iota
	// Month is the current calendar month (--month).
	Month
	// AllTime is everything since the runner's AllTimeSince (--since).
	AllTime
)

func (s Scan) String() string {
	switch s {
	case Today:
		return "today"
	case Month:
		return "month"
	case AllTime:
		return "all time"
	}
	return fmt.Sprintf("Scan(%d)", int(s))
}

// ExitError reports a tokscale run that exited non-zero.
type ExitError struct {
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	msg := strings.TrimSpace(e.Stderr)
	if len(msg) > 300 {
		msg = msg[:300]
	}
	if msg == "" {
		return fmt.Sprintf("tokscale exited with status %d", e.Code)
	}
	return fmt.Sprintf("tokscale exited with status %d: %s", e.Code, msg)
}

// runFunc is proc.Run's signature; tests replace it.
type runFunc func(ctx context.Context, bin string, args []string, timeout time.Duration) (proc.Output, error)

// Runner is the single entry point for the tokscale CLI. It is safe for concurrent use; calls run one at a time.
type Runner struct {
	// Binary is the tokscale executable.
	Binary string
	// Clients is the comma-separated --client list.
	Clients string
	// AllTimeSince is the --since date of the all-time scan.
	AllTimeSince string

	mu  sync.Mutex
	run runFunc
}

// NewRunner returns a runner for binary with the default client list and all-time start.
func NewRunner(binary string) *Runner {
	return &Runner{Binary: binary, Clients: DefaultClients, AllTimeSince: DefaultAllTimeSince}
}

// Fingerprint identifies the scan configuration: a changed client list or all-time start invalidates a saved anchor.
func (r *Runner) Fingerprint() string { return r.Clients + "|" + r.AllTimeSince }

// Scan runs one period scan and decodes it.
func (r *Runner) Scan(ctx context.Context, s Scan) (usage.Report, error) {
	args := []string{"--json", "--client", r.Clients, "--group-by", "client,session,model"}
	switch s {
	case Today:
		args = append(args, "--today")
	case Month:
		args = append(args, "--month")
	case AllTime:
		args = append(args, "--since", r.AllTimeSince)
	default:
		return usage.Report{}, fmt.Errorf("unknown scan %d", int(s))
	}
	out, err := r.exec(ctx, args, scanTimeout)
	if err != nil {
		return usage.Report{}, err
	}
	if out.ExitCode != 0 {
		return usage.Report{}, &ExitError{Code: out.ExitCode, Stderr: string(out.Stderr)}
	}
	rep, err := usage.DecodeReport(ExtractJSON(out.Stdout))
	if err != nil {
		return usage.Report{}, fmt.Errorf("decode tokscale %s scan: %w", s, err)
	}
	return rep, nil
}

// Graph runs `tokscale graph`, the per-day history source.
func (r *Runner) Graph(ctx context.Context) (usage.Graph, error) {
	out, err := r.exec(ctx, []string{"graph", "--client", r.Clients, "--no-spinner"}, scanTimeout)
	if err != nil {
		return usage.Graph{}, err
	}
	if out.ExitCode != 0 {
		return usage.Graph{}, &ExitError{Code: out.ExitCode, Stderr: string(out.Stderr)}
	}
	g, err := usage.DecodeGraph(ExtractJSON(out.Stdout))
	if err != nil {
		return usage.Graph{}, fmt.Errorf("decode tokscale graph: %w", err)
	}
	return g, nil
}

// exec runs tokscale with args, one call at a time, in a clean environment.
func (r *Runner) exec(ctx context.Context, args []string, timeout time.Duration) (proc.Output, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return proc.Output{}, err
	}
	run := r.run
	if run == nil {
		run = proc.Run
	}
	return run(ctx, r.Binary, args, timeout)
}

// ExtractJSON skips a non-JSON prefix (warnings, progress) before the first '{' or '['.
func ExtractJSON(data []byte) []byte {
	if i := bytes.IndexAny(data, "{["); i > 0 {
		return data[i:]
	}
	return data
}

// ErrNotFound is returned by LocateBinary when no executable tokscale exists.
var ErrNotFound = errors.New("tokscale binary not found")

// LocateBinary finds the tokscale executable: the SIMPLETOKEN_TOKSCALE_PATH override, then the app bundle
// (<bundle>/Contents/Resources/tokscale/tokscale next to Contents/MacOS/<exe>), then Resources/tokscale/tokscale
// in the source checkout (development builds and tests), searched upward from the working directory and from
// the executable.
func LocateBinary() (string, error) {
	var candidates []string
	if p := os.Getenv(EnvBinary); p != "" {
		candidates = append(candidates, p)
	}
	exe, err := os.Executable()
	if err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "..", "Resources", "tokscale", "tokscale"))
	}
	var roots []string
	if wd, err := os.Getwd(); err == nil {
		roots = append(roots, wd)
	}
	if exe != "" {
		roots = append(roots, filepath.Dir(exe))
	}
	for _, root := range roots {
		if repo := findRepo(root); repo != "" {
			candidates = append(candidates, filepath.Join(repo, "Resources", "tokscale", "tokscale"))
		}
	}
	for _, c := range candidates {
		if isExecutable(c) {
			return filepath.Clean(c), nil
		}
	}
	return "", ErrNotFound
}

// findRepo walks up from dir to the directory holding go.mod and Resources/tokscale.
func findRepo(dir string) string {
	for {
		if fileExists(filepath.Join(dir, "go.mod")) && fileExists(filepath.Join(dir, "Resources", "tokscale")) {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}
