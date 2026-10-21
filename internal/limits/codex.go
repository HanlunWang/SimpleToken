package limits

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/proc"
)

// CodexProbe reads the Codex limits by starting the local codex CLI's app-server and talking JSON-RPC over stdio:
//
//	initialize → initialized → account/rateLimits/read → account/read {refreshToken:false}
//
// The approval policy is `-a never` (newer CLIs removed `untrusted`), the child gets proc.CleanEnv, and the codex
// binary may live only inside ChatGPT.app or Codex.app, so the app bundles are checked first.
type CodexProbe struct {
	Executable string
	// Timeout bounds the whole exchange; 20 s when zero.
	Timeout time.Duration
}

// CodexCandidates are the places codex is looked for, in order.
func CodexCandidates() []string {
	home, _ := os.UserHomeDir()
	return []string{
		"/Applications/Codex.app/Contents/Resources/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex",
		filepath.Join(home, ".local/bin/codex"),
		"/opt/homebrew/bin/codex",
		"/usr/local/bin/codex",
	}
}

// LocateCodex returns the first executable codex binary, or "" when there is none.
func LocateCodex() string {
	for _, c := range CodexCandidates() {
		if st, err := os.Stat(c); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0 {
			return c
		}
	}
	return ""
}

// Probe runs one app-server session. ErrNotConfigured means the CLI answered but reported no limits.
func (p CodexProbe) Probe(ctx context.Context) (Snapshot, error) {
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.Command(p.Executable, "-s", "read-only", "-a", "never", "app-server")
	cmd.Env = proc.CleanEnv()
	cmd.Dir, _ = os.UserHomeDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return Snapshot{}, Unavailable{Reason: "Couldn't start codex: " + err.Error()}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Snapshot{}, Unavailable{Reason: "Couldn't start codex: " + err.Error()}
	}
	if err := cmd.Start(); err != nil {
		return Snapshot{}, Unavailable{Reason: "Couldn't start codex: " + err.Error()}
	}

	type result struct {
		snap Snapshot
		err  error
	}
	done := make(chan result, 1)
	go func() {
		s := &rpcSession{in: stdin, out: bufio.NewReaderSize(stdout, 64<<10)}
		snap, err := s.run(time.Now)
		done <- result{snap, err}
	}()

	var res result
	select {
	case res = <-done:
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			res.err = Unavailable{Reason: "codex app-server timed out"}
		} else {
			res.err = ctx.Err()
		}
	}
	// Tear down: close stdin, end the process group, unblock the reader, then reap.
	_ = stdin.Close()
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	_ = stdout.Close()
	reaped := make(chan struct{})
	go func() { _ = cmd.Wait(); close(reaped) }()
	select {
	case <-reaped:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-reaped
	}
	return res.snap, res.err
}

// rpcSession is minimal line-delimited JSON-RPC: requests are strictly serial and responses are matched by id;
// notifications and other messages are skipped.
type rpcSession struct {
	in  io.Writer
	out *bufio.Reader
}

func (s *rpcSession) run(now func() time.Time) (Snapshot, error) {
	if _, err := s.request(1, "initialize", map[string]any{
		"clientInfo": map[string]any{"name": "simpletoken", "title": "SimpleToken", "version": "0.1"},
	}); err != nil {
		return Snapshot{}, err
	}
	s.write(map[string]any{"method": "initialized", "params": map[string]any{}})
	limits, err := s.request(2, "account/rateLimits/read", nil)
	if err != nil {
		return Snapshot{}, err
	}
	account, err := s.request(3, "account/read", map[string]any{"refreshToken": false})
	if err != nil {
		account = nil
	}
	return parseCodex(limits, account, now())
}

func (s *rpcSession) write(msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	_, _ = s.in.Write(append(data, '\n'))
}

func (s *rpcSession) request(id int, method string, params map[string]any) (map[string]any, error) {
	msg := map[string]any{"method": method, "id": id}
	if params != nil {
		msg["params"] = params
	}
	s.write(msg)
	for {
		line, err := s.out.ReadBytes('\n')
		if len(line) == 0 && err != nil {
			return nil, Unavailable{Reason: "codex app-server exited"}
		}
		obj, ok := decodeObject(line)
		if !ok {
			continue
		}
		if got, ok := jsonNumber(obj["id"]); !ok || got != float64(id) {
			continue
		}
		if e := object(obj["error"]); e != nil {
			reason, _ := str(e["message"])
			if reason == "" {
				reason = "codex RPC error"
			}
			return nil, Unavailable{Reason: reason}
		}
		res := object(obj["result"])
		if res == nil {
			res = map[string]any{}
		}
		return res, nil
	}
}

// parseCodex builds the windows: the main codex limit's primary / secondary windows, then per-model extras
// (e.g. GPT-5.3-Codex-Spark) titled "<name> · Weekly" or "<name> · Session".
func parseCodex(rateLimits, account map[string]any, now time.Time) (Snapshot, error) {
	direct := object(first(rateLimits, "rateLimits", "rate_limits"))
	byID := object(first(rateLimits, "rateLimitsByLimitId", "rate_limits_by_limit_id"))
	main := direct
	if main == nil {
		main = object(byID["codex"])
	}
	if main == nil {
		main = map[string]any{}
	}

	window := func(raw any, title string) (Window, bool) {
		w := object(raw)
		if w == nil {
			return Window{}, false
		}
		used, ok := jsonNumber(first(w, "usedPercent", "used_percent"))
		if !ok {
			return Window{}, false
		}
		minutes := 0
		if m, ok := jsonNumber(first(w, "windowDurationMins", "window_duration_mins")); ok {
			minutes = int(m)
		}
		var reset *time.Time
		if r, ok := jsonNumber(first(w, "resetsAt", "resets_at")); ok {
			reset = ptr(unixSeconds(r))
		}
		kind := Session
		switch {
		case title != "":
			kind = Model
		case minutes >= 7*24*60:
			kind = Weekly
		}
		return NewWindow(kind, used, reset, minutes, title), true
	}

	var windows []Window
	for _, key := range []string{"primary", "secondary"} {
		if w, ok := window(main[key], ""); ok {
			windows = append(windows, w)
		}
	}
	ids := make([]string, 0, len(byID))
	for id := range byID {
		if id != "codex" {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids) // deterministic order for the extras
	for _, id := range ids {
		snap := object(byID[id])
		if snap == nil {
			continue
		}
		name, ok := str(first(snap, "limitName", "limit_name"))
		if !ok {
			name = id
		}
		for _, key := range []string{"primary", "secondary"} {
			if w, ok := window(snap[key], name); ok {
				span := "Session"
				if w.Span() >= 7*24*time.Hour {
					span = "Weekly"
				}
				w.Title = name + " · " + span
				windows = append(windows, w)
			}
		}
	}
	slices.SortStableFunc(windows, func(a, b Window) int { return kindOrder(a.Kind) - kindOrder(b.Kind) })
	if len(windows) == 0 {
		return Snapshot{}, ErrNotConfigured
	}

	plan, ok := str(object(account["account"])["planType"])
	if !ok {
		plan, _ = str(main["planType"])
	}
	return Snapshot{Provider: Codex, Windows: windows, AccountLabel: CodexPlanLabel(plan), UpdatedAt: now}, nil
}

func kindOrder(k Kind) int {
	switch k {
	case Session:
		return 0
	case Weekly:
		return 1
	case Fable:
		return 2
	}
	return 3
}

// CodexPlanLabel maps Codex plan types to labels (pro → "Pro 20x", prolite → "Pro 5x", …); anything else is
// capitalised.
func CodexPlanLabel(raw string) string {
	key := strings.ToLower(strings.TrimSpace(raw))
	exact := map[string]string{
		"pro": "Pro 20x", "prolite": "Pro 5x", "pro_lite": "Pro 5x", "pro-lite": "Pro 5x", "pro lite": "Pro 5x",
		"free": "Free", "plus": "Plus", "max": "Max", "team": "Team", "teams": "Team",
		"enterprise": "Enterprise", "business": "Business",
	}
	if l, ok := exact[key]; ok {
		return l
	}
	if key == "" {
		return ""
	}
	r := []rune(key)
	return strings.ToUpper(string(r[0])) + string(r[1:])
}
