package tokscale

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/proc"
)

type fakeCall struct {
	args []string
}

type fake struct {
	mu      sync.Mutex
	calls   []fakeCall
	reply   func(args []string) (proc.Output, error)
	active  atomic.Int32
	overlap atomic.Bool
}

func (f *fake) run(_ context.Context, _ string, args []string, _ time.Duration) (proc.Output, error) {
	if f.active.Add(1) > 1 {
		f.overlap.Store(true)
	}
	defer f.active.Add(-1)
	time.Sleep(2 * time.Millisecond)
	f.mu.Lock()
	f.calls = append(f.calls, fakeCall{args: args})
	f.mu.Unlock()
	return f.reply(args)
}

func newFakeRunner(reply func([]string) (proc.Output, error)) (*Runner, *fake) {
	f := &fake{reply: reply}
	r := NewRunner("/nonexistent/tokscale")
	r.run = f.run
	return r, f
}

func TestScanArgsAndDecode(t *testing.T) {
	r, f := newFakeRunner(func([]string) (proc.Output, error) {
		return proc.Output{Stdout: []byte(`note\n{"entries":[{"client":"claude-code","model":"m","input":1,"output":2,"messageCount":1,"cost":0.1}]}`)}, nil
	})
	r.Clients, r.AllTimeSince = "claude", "2025-01-01"
	for _, s := range []Scan{Today, Month, AllTime} {
		rep, err := r.Scan(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if p := rep.Aggregate(); p.TotalTokens != 3 || p.ByClient["claude"].Tokens != 3 {
			t.Errorf("%v: %+v", s, p)
		}
	}
	want := [][]string{
		{"--json", "--client", "claude", "--group-by", "client,session,model", "--today"},
		{"--json", "--client", "claude", "--group-by", "client,session,model", "--month"},
		{"--json", "--client", "claude", "--group-by", "client,session,model", "--since", "2025-01-01"},
	}
	for i, c := range f.calls {
		if !slices.Equal(c.args, want[i]) {
			t.Errorf("call %d: %v, want %v", i, c.args, want[i])
		}
	}
	if r.Fingerprint() != "claude|2025-01-01" {
		t.Errorf("fingerprint %q", r.Fingerprint())
	}
}

func TestNonZeroExitIsAnError(t *testing.T) {
	r, _ := newFakeRunner(func([]string) (proc.Output, error) {
		return proc.Output{ExitCode: 2, Stderr: []byte("boom\n")}, nil
	})
	_, err := r.Graph(context.Background())
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 2 || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("err %v", err)
	}
}

func TestCallsAreSerial(t *testing.T) {
	r, f := newFakeRunner(func([]string) (proc.Output, error) { return proc.Output{Stdout: []byte(`{}`)}, nil })
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			_, _ = r.Scan(context.Background(), Today)
			_, _ = r.Graph(context.Background())
		})
	}
	wg.Wait()
	if f.overlap.Load() {
		t.Fatal("two tokscale runs overlapped")
	}
	if len(f.calls) != 16 {
		t.Fatalf("%d calls", len(f.calls))
	}
}

func TestCursorSync(t *testing.T) {
	dir := t.TempDir()
	signedIn := false
	r, f := newFakeRunner(func(args []string) (proc.Output, error) {
		if args[1] == "login" {
			return proc.Output{}, nil
		}
		return proc.Output{Stdout: []byte(`{"error":"rate limited"}`)}, nil
	})
	c := NewCursorSync(r, func() bool { return signedIn })
	c.CredentialsPath = filepath.Join(dir, "cursor-credentials.json")

	// Not signed in: nothing runs
	if msg := c.Sync(context.Background()); msg != "" || len(f.calls) != 0 {
		t.Fatalf("msg %q calls %d", msg, len(f.calls))
	}
	// Signed in, no tokscale credentials: login, then sync; the sync's error is reported
	signedIn = true
	if msg := c.Sync(context.Background()); msg != "rate limited" {
		t.Fatalf("msg %q", msg)
	}
	if len(f.calls) != 2 || f.calls[0].args[1] != "login" || f.calls[1].args[1] != "sync" {
		t.Fatalf("calls %v", f.calls)
	}
	// With credentials there is no login; the hourly gate holds the second SyncIfDue back
	if err := os.WriteFile(c.CredentialsPath, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.calls = nil
	c.SyncIfDue(context.Background())
	c.SyncIfDue(context.Background())
	if len(f.calls) != 1 || c.LastError() != "rate limited" {
		t.Fatalf("calls %v err %q", f.calls, c.LastError())
	}
	c.MarkDue()
	c.SyncIfDue(context.Background())
	if len(f.calls) != 2 {
		t.Fatalf("MarkDue did not force a sync: %v", f.calls)
	}
}

func TestLocateBinaryHonoursEnv(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "tokscale")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(EnvBinary, bin)
	got, err := LocateBinary()
	if err != nil || got != bin {
		t.Fatalf("got %q, %v", got, err)
	}
}
