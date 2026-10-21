package limits

import (
	"context"
	"encoding/base64"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseCursorWeeklySpendAndMergedPlan(t *testing.T) {
	now := time.Unix(1_760_000_000, 0)
	status := map[string]any{"usagePercent": 44.5, "nextResetTimestampUtc": "2026-10-19T00:00:06.766Z",
		"hasNonZeroIncludedLimit": true, "grokPlanLabel": "Premium"}
	period := map[string]any{"spendLimitUsage": map[string]any{"individualUsed": 250.0, "individualLimit": "1000"},
		"billingCycleEnd": "1794527129000"}
	plan := map[string]any{"planInfo": map[string]any{"planName": "Premium"}, "isMerged": true}
	snap, err := parseCursor(status, period, plan, now)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Provider != Cursor || snap.AccountLabel != "X Pass Premium" || !snap.UpdatedAt.Equal(now) {
		t.Fatalf("snapshot: %+v", snap)
	}
	weekly, ok := snap.Window(Weekly)
	if !ok || weekly.UsedPercent != 44.5 || weekly.WindowMinutes != 7*24*60 || weekly.ResetsAt == nil {
		t.Fatalf("weekly: %+v", weekly)
	}
	want := time.Date(2026, 10, 19, 0, 0, 6, 766_000_000, time.UTC)
	if math.Abs(weekly.ResetsAt.Sub(want).Seconds()) > 0.01 {
		t.Fatalf("weekly reset: %v", weekly.ResetsAt)
	}
	spend, ok := snap.Window(Model)
	if !ok || spend.UsedPercent != 25 || spend.Title != "On-demand" || spend.ResetsAt == nil ||
		!spend.ResetsAt.Equal(time.Unix(1_794_527_129, 0)) {
		t.Fatalf("spend: %+v", spend)
	}
}

func TestParseCursorSkipsAbsentSpendLimitAndKeepsPlainPlanName(t *testing.T) {
	status := map[string]any{"usagePercent": "12", "nextResetTimestampUtc": map[string]any{"seconds": 1_792_454_406.0}}
	period := map[string]any{"spendLimitUsage": map[string]any{"individualUsed": 0.0, "individualLimit": 2_147_483_647.0}}
	plan := map[string]any{"planInfo": map[string]any{"planName": "Pro"}, "isMerged": false}
	snap, err := parseCursor(status, period, plan, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Windows) != 1 || snap.AccountLabel != "Pro" {
		t.Fatalf("snapshot: %+v", snap)
	}
	if w, _ := snap.Window(Weekly); w.ResetsAt == nil || !w.ResetsAt.Equal(time.Unix(1_792_454_406, 0)) || w.UsedPercent != 12 {
		t.Fatalf("weekly: %+v", w)
	}
	// Merged with no plan name; the status label is used when planInfo is absent.
	snap, _ = parseCursor(map[string]any{"usagePercent": 1.0, "grokPlanLabel": " Premium "}, nil, nil, time.Now())
	if snap.AccountLabel != "Premium" {
		t.Fatalf("status label: %q", snap.AccountLabel)
	}
	snap, _ = parseCursor(map[string]any{"usagePercent": 1.0}, nil, map[string]any{"isMerged": true}, time.Now())
	if snap.AccountLabel != "X Pass" {
		t.Fatalf("merged without a name: %q", snap.AccountLabel)
	}
}

func TestParseCursorFailsWithoutUsagePercent(t *testing.T) {
	_, err := parseCursor(map[string]any{"grokPlanLabel": "Premium"}, nil, nil, time.Now())
	var u Unavailable
	if !errors.As(err, &u) {
		t.Fatalf("want Unavailable, got %v", err)
	}
}

// fakeJWT is an unsigned token with the given subject (test data only).
func fakeJWT(sub string) string {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"` + sub + `","exp":1}`))
	return "eyJhbGciOiJIUzI1NiJ9." + payload + ".sig"
}

func TestCursorTokensAndSubjects(t *testing.T) {
	jwt := fakeJWT("auth0|user_01ABC")
	if id, ok := cursorUserIDFromJWT(jwt); !ok || id != "user_01ABC" {
		t.Fatalf("subject: %q %v", id, ok)
	}
	if _, ok := cursorUserIDFromJWT("not-a-jwt"); ok {
		t.Fatal("want no subject")
	}
	tok, ok := cursorTokenFromSession("user_01ABC::" + jwt)
	if !ok || tok != (CursorToken{UserID: "user_01ABC", AccessToken: jwt}) {
		t.Fatalf("session: %+v", tok)
	}
	if tok, ok := cursorTokenFromSession("user_01ABC%3A%3A" + jwt); !ok || tok.UserID != "user_01ABC" {
		t.Fatalf("encoded session: %+v", tok)
	}
	if _, ok := cursorTokenFromSession("no-separator"); ok {
		t.Fatal("want no token")
	}
	if got := (CursorToken{UserID: "user_01ABC", AccessToken: jwt}).SessionCookie(); got != "WorkosCursorSessionToken=user_01ABC%3A%3A"+jwt {
		t.Fatalf("cookie: %q", got)
	}
}

func TestCursorTokenFromTokscale(t *testing.T) {
	jwt := fakeJWT("auth0|user_B")
	path := filepath.Join(t.TempDir(), "cursor-credentials.json")
	data := `{"activeAccountId":"b","accounts":{"a":{"sessionToken":"user_A::` + fakeJWT("auth0|user_A") + `"},
		"b":{"sessionToken":"user_B%3A%3A` + jwt + `"}}}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	tok, ok := cursorTokenFromTokscale(path)
	if !ok || tok.UserID != "user_B" || tok.AccessToken != jwt {
		t.Fatalf("active account: %+v %v", tok.UserID, ok)
	}
	if _, ok := cursorTokenFromTokscale(filepath.Join(t.TempDir(), "missing.json")); ok {
		t.Fatal("want no token from a missing file")
	}
}

func TestCursorTokenFromStateDatabaseFixture(t *testing.T) {
	if _, err := exec.LookPath(sqlite3Path); err != nil {
		t.Skip("no sqlite3 shell")
	}
	// A fixture database in a directory with a space, like "Application Support".
	dir := filepath.Join(t.TempDir(), "Application Support")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(dir, "state.vscdb")
	jwt := fakeJWT("auth0|user_01DB")
	setup := "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);" +
		"INSERT INTO ItemTable VALUES ('other', 'x');" +
		"INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '" + jwt + "');"
	if out, err := exec.Command(sqlite3Path, db, setup).CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v %s", err, out)
	}
	before, _ := os.ReadDir(dir)
	tok, ok := cursorTokenFromStateDB(context.Background(), db)
	if !ok || tok.UserID != "user_01DB" || tok.AccessToken != jwt {
		t.Fatalf("token: %+v %v", tok.UserID, ok)
	}
	after, _ := os.ReadDir(dir)
	if len(after) != len(before) {
		t.Fatalf("reading created files: %d → %d", len(before), len(after))
	}
	if _, ok := cursorTokenFromStateDB(context.Background(), filepath.Join(dir, "missing.vscdb")); ok {
		t.Fatal("want no token from a missing database")
	}
}

func TestCursorProbeAgainstFakeServer(t *testing.T) {
	jwt := fakeJWT("auth0|user_01ABC")
	tok := CursorToken{UserID: "user_01ABC", AccessToken: jwt}
	var mu sync.Mutex
	seen := map[string]http.Header{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen[r.URL.Path] = r.Header.Clone()
		mu.Unlock()
		if r.Method != http.MethodPost {
			w.WriteHeader(405)
			return
		}
		switch r.URL.Path {
		case "/rpc/GetSandUsageStatus":
			_, _ = w.Write([]byte(`{"usagePercent":61,"nextResetTimestampUtc":"2026-10-26T00:00:00Z"}`))
		case "/rpc/GetCurrentPeriodUsage":
			_, _ = w.Write([]byte(`{"spendLimitUsage":{"individualUsed":"5","individualLimit":"20"},"billingCycleEnd":{"seconds":"1794527129"}}`))
		case "/plan":
			_, _ = w.Write([]byte(`{"planInfo":{"planName":"Premium"},"isMerged":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	p := CursorProbe{Token: tok, RPCBaseURL: srv.URL + "/rpc/", PlanInfoURL: srv.URL + "/plan"}
	snap, err := p.Probe(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snap.AccountLabel != "X Pass Premium" || len(snap.Windows) != 2 {
		t.Fatalf("snapshot: %+v", snap)
	}
	if w, _ := snap.Window(Model); w.UsedPercent != 25 || w.ResetsAt == nil || !w.ResetsAt.Equal(time.Unix(1_794_527_129, 0)) {
		t.Fatalf("spend: %+v", w)
	}
	mu.Lock()
	defer mu.Unlock()
	rpc := seen["/rpc/GetSandUsageStatus"]
	if rpc.Get("Authorization") != "Bearer "+jwt || rpc.Get("Connect-Protocol-Version") != "1" || rpc.Get("Cookie") != "" {
		t.Fatal("RPC headers: wrong authorization headers")
	}
	if seen["/plan"].Get("Cookie") != tok.SessionCookie() || seen["/plan"].Get("Authorization") != "" {
		t.Fatal("plan-info headers: wrong cookie")
	}
}

func TestCursorProbeErrors(t *testing.T) {
	for code, want := range map[int]error{401: ErrUnauthorized, 403: ErrUnauthorized, 429: ErrRateLimited} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }))
		_, err := CursorProbe{Token: CursorToken{UserID: "u", AccessToken: "t"}, RPCBaseURL: srv.URL, PlanInfoURL: srv.URL}.Probe(context.Background())
		srv.Close()
		if !errors.Is(err, want) {
			t.Errorf("HTTP %d: got %v, want %v", code, err, want)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("<html>")) }))
	defer srv.Close()
	_, err := CursorProbe{Token: CursorToken{UserID: "u", AccessToken: "t"}, RPCBaseURL: srv.URL, PlanInfoURL: srv.URL}.Probe(context.Background())
	if err == nil || !strings.Contains(err.Error(), "other than JSON") {
		t.Fatalf("non-JSON: %v", err)
	}
}

func TestSQLiteURI(t *testing.T) {
	if got := sqliteURI("/a b/c?d#e%f"); got != "file:/a%20b/c%3fd%23e%25f" {
		t.Fatalf("uri: %q", got)
	}
}
