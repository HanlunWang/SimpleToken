package limits

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNormalizeSessionKey(t *testing.T) {
	p, err := NewClaudeWebProbe("sessionKey=sk-ant-abc123")
	if err != nil || p.SessionKey != "sk-ant-abc123" {
		t.Fatalf("got %+v, %v", p, err)
	}
	p, err = NewClaudeWebProbe("  sk-ant-xyz  \n")
	if err != nil || p.SessionKey != "sk-ant-xyz" {
		t.Fatalf("got %+v, %v", p, err)
	}
	if _, err := NewClaudeWebProbe("not-a-key"); !errors.Is(err, ErrInvalidCookie) {
		t.Fatalf("want ErrInvalidCookie, got %v", err)
	}
}

func TestParseClaudeUsage(t *testing.T) {
	data, err := os.ReadFile("testdata/claude-usage.json")
	if err != nil {
		t.Fatal(err)
	}
	snap, err := parseClaudeUsage(data, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if snap.Provider != Claude || len(snap.Windows) != 3 {
		t.Fatalf("windows: %+v", snap.Windows)
	}
	session, _ := snap.Window(Session)
	if session.UsedPercent != 21 || session.Remaining() != 79 || session.ResetsAt == nil {
		t.Fatalf("session: %+v", session)
	}
	if !session.ResetsAt.Equal(time.Date(2026, 8, 21, 14, 0, 0, 0, time.UTC)) {
		t.Fatalf("session reset: %v", session.ResetsAt)
	}
	weekly, _ := snap.Window(Weekly)
	if weekly.UsedPercent != 52 || weekly.ResetsAt == nil {
		t.Fatalf("weekly: %+v", weekly)
	}
	fable, ok := snap.Window(Fable) // only display_name == Fable counts
	if !ok || fable.UsedPercent != 39 {
		t.Fatalf("fable: %+v", fable)
	}
	if _, err := parseClaudeUsage([]byte(`{"five_hour":null}`), time.Now()); err == nil {
		t.Fatal("want an error without windows")
	}
	if _, err := parseClaudeUsage([]byte(`<html>`), time.Now()); err == nil {
		t.Fatal("want an error for non-JSON")
	}
}

func TestSelectClaudeOrganization(t *testing.T) {
	id, err := selectClaudeOrganization([]byte(`[{"uuid":"api-org","capabilities":["api"]},
		{"uuid":"chat-org","capabilities":["chat","api"]}]`))
	if err != nil || id != "chat-org" {
		t.Fatalf("chat-capable: %q %v", id, err)
	}
	id, err = selectClaudeOrganization([]byte(`{"organizations":[{"uuid":"only-org","capabilities":["api"]}]}`))
	if err != nil || id != "only-org" {
		t.Fatalf("fallback: %q %v", id, err)
	}
	id, err = selectClaudeOrganization([]byte(`{"data":[{"uuid":"api-org","capabilities":["api"]},{"id":"other","capabilities":["claude_pro"]}]}`))
	if err != nil || id != "other" {
		t.Fatalf("not API-only: %q %v", id, err)
	}
	if _, err := selectClaudeOrganization([]byte(`[]`)); err == nil {
		t.Fatal("want an error without organisations")
	}
}

func TestRenewedSessionKey(t *testing.T) {
	// Several Set-Cookie headers joined by commas.
	h := http.Header{}
	h.Add("Set-Cookie", "cf_x=1; Path=/, sessionKey=sk-ant-renewed-42; Path=/; HttpOnly; Secure")
	if got := renewedSessionKey(h); got != "sk-ant-renewed-42" {
		t.Fatalf("merged: %q", got)
	}
	// Separate headers.
	h = http.Header{}
	h.Add("Set-Cookie", "cf_x=1; Path=/")
	h.Add("Set-Cookie", "sessionKey=sk-ant-second; Path=/")
	if got := renewedSessionKey(h); got != "sk-ant-second" {
		t.Fatalf("separate: %q", got)
	}
	h = http.Header{}
	h.Add("Set-Cookie", "sessionKey=deleted; Path=/")
	if got := renewedSessionKey(h); got != "" {
		t.Fatalf("non sk-ant value: %q", got)
	}
}

func TestClaudePlanLabel(t *testing.T) {
	cases := []struct{ sub, tier, want string }{
		{"max", "default_claude_max_20x", "Max 20x"},
		{"max", "", "Max"},
		{"pro", "default_claude_ai", "Pro"},
		{"", "default_claude_max_5x", "max 5x"},
		{"", "", ""},
		{"team", "x", "Team"},
	}
	for _, c := range cases {
		if got := ClaudePlanLabel(c.sub, c.tier); got != c.want {
			t.Errorf("ClaudePlanLabel(%q, %q) = %q, want %q", c.sub, c.tier, got, c.want)
		}
	}
	if got := claudePlanLabelFromCredentials([]byte(`{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}`)); got != "Max 20x" {
		t.Errorf("from credentials: %q", got)
	}
}

// fakeClaude is an httptest claude.ai: it records cookies and rotates the key on the organisations call.
type fakeClaude struct {
	mu        sync.Mutex
	cookies   []string
	agents    []string
	rotate    string
	usageCode int
	header    http.Header
}

func (f *fakeClaude) handler(t *testing.T) http.Handler {
	usage, err := os.ReadFile("testdata/claude-usage.json")
	if err != nil {
		t.Fatal(err)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.cookies = append(f.cookies, r.Header.Get("Cookie"))
		f.agents = append(f.agents, r.Header.Get("User-Agent"))
		rotate, code, extra := f.rotate, f.usageCode, f.header
		f.mu.Unlock()
		switch {
		case r.URL.Path == "/api/organizations":
			if rotate != "" {
				w.Header().Add("Set-Cookie", "sessionKey="+rotate+"; Path=/; HttpOnly")
			}
			_, _ = w.Write([]byte(`[{"uuid":"org-1","capabilities":["chat"]}]`))
		case r.URL.Path == "/api/organizations/org-1/usage":
			for k, v := range extra {
				w.Header()[k] = v
			}
			if code != 0 {
				w.WriteHeader(code)
				return
			}
			_, _ = w.Write(usage)
		default:
			http.NotFound(w, r)
		}
	})
}

func TestClaudeWebProbeFlow(t *testing.T) {
	fake := &fakeClaude{rotate: "sk-ant-rotated"}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()

	p, _ := NewClaudeWebProbe("sk-ant-original")
	p.BaseURL = srv.URL
	res, err := p.Probe(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if res.OrganizationID != "org-1" || res.RenewedSessionKey != "sk-ant-rotated" || len(res.Snapshot.Windows) != 3 {
		t.Fatalf("result: org %q renewed %q windows %d", res.OrganizationID, res.RenewedSessionKey, len(res.Snapshot.Windows))
	}
	fake.mu.Lock()
	cookies, agents := fake.cookies, fake.agents
	fake.mu.Unlock()
	if len(cookies) != 2 || cookies[0] != "sessionKey=sk-ant-original" || cookies[1] != "sessionKey=sk-ant-rotated" {
		t.Fatalf("cookies sent: %q", cookies)
	}
	if !strings.HasPrefix(agents[0], "Mozilla/5.0") {
		t.Fatalf("user agent: %q", agents[0])
	}

	// A cached organisation skips the list; no rotation means no renewed key.
	fake.mu.Lock()
	fake.cookies, fake.rotate = nil, ""
	fake.mu.Unlock()
	res, err = p.Probe(context.Background(), "org-1")
	if err != nil || res.RenewedSessionKey != "" {
		t.Fatalf("cached: %+v %v", res, err)
	}
	fake.mu.Lock()
	if len(fake.cookies) != 1 {
		t.Fatalf("cached org should make one request, made %d", len(fake.cookies))
	}
	fake.mu.Unlock()
}

func TestClaudeWebProbeErrors(t *testing.T) {
	cases := []struct {
		code   int
		header http.Header
		want   error
	}{
		{403, http.Header{"Cf-Mitigated": {"challenge"}}, ErrChallenge},
		{403, nil, ErrUnauthorized},
		{401, nil, ErrUnauthorized},
		{429, nil, ErrRateLimited},
	}
	for _, c := range cases {
		fake := &fakeClaude{usageCode: c.code, header: c.header}
		srv := httptest.NewServer(fake.handler(t))
		p := &ClaudeWebProbe{SessionKey: "sk-ant-x", BaseURL: srv.URL}
		_, err := p.Probe(context.Background(), "")
		srv.Close()
		if !errors.Is(err, c.want) {
			t.Errorf("HTTP %d %v: got %v, want %v", c.code, c.header, err, c.want)
		}
	}
	fake := &fakeClaude{usageCode: 500}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()
	_, err := (&ClaudeWebProbe{SessionKey: "sk-ant-x", BaseURL: srv.URL}).Probe(context.Background(), "org-1")
	var u Unavailable
	if !errors.As(err, &u) || u.Reason != "http 500" {
		t.Fatalf("HTTP 500: %v", err)
	}
}
