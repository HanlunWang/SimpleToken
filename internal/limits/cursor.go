package limits

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/proc"
)

// Cursor endpoints. Tests point a probe's URLs elsewhere.
const (
	CursorRPCBaseURL  = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
	CursorPlanInfoURL = "https://cursor.com/api/dashboard/get-plan-info"
)

// CursorToken is the Cursor desktop sign-in. Grok Bot is a Cursor app, so its usage and the weekly included-usage
// window live in the Cursor account (the merged "X Pass" plan). SimpleToken never stores the token.
type CursorToken struct {
	// UserID is the Cursor user id (user_…), from the token's subject.
	UserID      string
	AccessToken string
}

// SessionCookie is the dashboard's session cookie: user id and token, joined as the web app does.
func (t CursorToken) SessionCookie() string {
	return "WorkosCursorSessionToken=" + t.UserID + "%3A%3A" + t.AccessToken
}

// CursorStateDatabase is Cursor's desktop state database (VS Code global storage).
func CursorStateDatabase() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb")
}

// TokscaleCursorCredentials is tokscale's Cursor credentials file (written by `tokscale cursor login`).
func TokscaleCursorCredentials() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "tokscale", "cursor-credentials.json")
}

// LocateCursorToken finds the signed-in Cursor account: the desktop app's token first (Cursor keeps it fresh),
// else tokscale's copy.
func LocateCursorToken() (CursorToken, bool) {
	if t, ok := cursorTokenFromStateDB(context.Background(), CursorStateDatabase()); ok {
		return t, true
	}
	return cursorTokenFromTokscale(TokscaleCursorCredentials())
}

// CursorSignedIn reports whether there is a Cursor sign-in on this Mac (for the collector's Cursor sync).
func CursorSignedIn() bool {
	_, ok := LocateCursorToken()
	return ok
}

// sqlite3Path is the system sqlite3 shell, used instead of a cgo driver.
var sqlite3Path = "/usr/bin/sqlite3"

// cursorTokenFromStateDB reads cursorAuth/accessToken with the sqlite3 shell. The URI opens the file read-only and
// immutable, so no lock is ever taken on a database Cursor has open; -init /dev/null skips ~/.sqliterc so the
// owner's shell settings cannot change the output format.
func cursorTokenFromStateDB(ctx context.Context, path string) (CursorToken, bool) {
	if _, err := os.Stat(path); err != nil {
		return CursorToken{}, false
	}
	out, err := proc.Run(ctx, sqlite3Path, []string{
		"-init", "/dev/null", "-batch", "-readonly", "-noheader", "-list",
		sqliteURI(path) + "?mode=ro&immutable=1",
		"SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
	}, 5*time.Second)
	if err != nil || out.ExitCode != 0 {
		return CursorToken{}, false
	}
	access := strings.TrimSpace(string(out.Stdout))
	userID, ok := cursorUserIDFromJWT(access)
	if !ok {
		return CursorToken{}, false
	}
	return CursorToken{UserID: userID, AccessToken: access}, true
}

// sqliteURI is a file: URI for an absolute path, escaping the characters SQLite's URI parser treats specially.
func sqliteURI(path string) string {
	var b strings.Builder
	b.WriteString("file:")
	for _, r := range path {
		switch r {
		case '%':
			b.WriteString("%25")
		case '?':
			b.WriteString("%3f")
		case '#':
			b.WriteString("%23")
		case ' ':
			b.WriteString("%20")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func cursorTokenFromTokscale(path string) (CursorToken, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return CursorToken{}, false
	}
	root, ok := decodeObject(data)
	if !ok {
		return CursorToken{}, false
	}
	accounts := object(root["accounts"])
	var active map[string]any
	if id, ok := str(root["activeAccountId"]); ok {
		active = object(accounts[id])
	}
	if active == nil {
		keys := make([]string, 0, len(accounts))
		for k := range accounts {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if a := object(accounts[k]); a != nil {
				active = a
				break
			}
		}
	}
	session, ok := str(active["sessionToken"])
	if !ok {
		return CursorToken{}, false
	}
	return cursorTokenFromSession(session)
}

// cursorTokenFromSession parses tokscale's cookie value, `user_…::<jwt>` (the separator may be URL-encoded).
func cursorTokenFromSession(session string) (CursorToken, bool) {
	parts := strings.Split(strings.ReplaceAll(session, "%3A%3A", "::"), "::")
	if len(parts) != 2 || parts[1] == "" {
		return CursorToken{}, false
	}
	return CursorToken{UserID: parts[0], AccessToken: parts[1]}, true
}

// cursorUserIDFromJWT reads the token's `sub` claim (`auth0|user_…`) and keeps the part after the last "|".
func cursorUserIDFromJWT(jwt string) (string, bool) {
	segments := strings.Split(jwt, ".")
	if len(segments) < 2 {
		return "", false
	}
	payload := strings.TrimRight(segments[1], "=")
	payload = strings.NewReplacer("+", "-", "/", "_").Replace(payload)
	data, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return "", false
	}
	claims, ok := decodeObject(data)
	if !ok {
		return "", false
	}
	sub, ok := str(claims["sub"])
	if !ok {
		return "", false
	}
	parts := strings.Split(sub, "|")
	last := parts[len(parts)-1]
	if last == "" {
		return "", false
	}
	return last, true
}

// CursorProbe reads the Cursor limits: the weekly window from the dashboard RPC GetSandUsageStatus (the call Grok
// Bot's own usage view makes), the on-demand spend from GetCurrentPeriodUsage and the plan name from get-plan-info.
type CursorProbe struct {
	Token CursorToken
	// RPCBaseURL and PlanInfoURL default to the Cursor endpoints.
	RPCBaseURL  string
	PlanInfoURL string
	// Client defaults to a cookie-jar-free client with a 15 s timeout.
	Client *http.Client
}

// Probe reads the three responses; only the usage status is required, the other two add to the picture.
func (p CursorProbe) Probe(ctx context.Context) (Snapshot, error) {
	status, err := p.rpc(ctx, "GetSandUsageStatus")
	if err != nil {
		return Snapshot{}, err
	}
	period, _ := p.rpc(ctx, "GetCurrentPeriodUsage")
	planURL := p.PlanInfoURL
	if planURL == "" {
		planURL = CursorPlanInfoURL
	}
	plan, _ := p.post(ctx, planURL, map[string]string{"Cookie": p.Token.SessionCookie()})
	return parseCursor(status, period, plan, time.Now())
}

func (p CursorProbe) rpc(ctx context.Context, method string) (map[string]any, error) {
	base := p.RPCBaseURL
	if base == "" {
		base = CursorRPCBaseURL
	}
	return p.post(ctx, strings.TrimRight(base, "/")+"/"+method, map[string]string{
		"Authorization":            "Bearer " + p.Token.AccessToken,
		"Connect-Protocol-Version": "1",
	})
}

func (p CursorProbe) post(ctx context.Context, url string, headers map[string]string) (map[string]any, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, Unavailable{Reason: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://cursor.com")
	req.Header.Set("User-Agent", "SimpleToken")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	client := p.Client
	if client == nil {
		client = probeClient(15 * time.Second)
	}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, Unavailable{Reason: networkReason(err)}
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case 200:
	case 401, 403:
		return nil, ErrUnauthorized
	case 429:
		return nil, ErrRateLimited
	default:
		return nil, Unavailable{Reason: fmt.Sprintf("Cursor returned HTTP %d", resp.StatusCode)}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, Unavailable{Reason: networkReason(err)}
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil || m == nil {
		return nil, Unavailable{Reason: "Cursor returned something other than JSON"}
	}
	return m, nil
}

// parseCursor builds the windows. Numbers may arrive as numbers or strings (protobuf JSON); timestamps as RFC 3339
// strings, {seconds} objects or (milli)seconds.
func parseCursor(status, period, plan map[string]any, now time.Time) (Snapshot, error) {
	percent, ok := looseNumber(status["usagePercent"])
	if !ok {
		return Snapshot{}, Unavailable{Reason: "Cursor reported no usage window"}
	}
	windows := []Window{NewWindow(Weekly, percent, cursorDate(status["nextResetTimestampUtc"]), 7*24*60, "")}

	// On-demand spend against its limit, when the account has one (an int32-max limit means none).
	if spend := object(period["spendLimitUsage"]); spend != nil {
		limit, okLimit := looseNumber(spend["individualLimit"])
		used, okUsed := looseNumber(spend["individualUsed"])
		if okLimit && okUsed && limit > 0 && limit < 2_000_000_000 {
			windows = append(windows, NewWindow(Model, used/limit*100, cursorDate(period["billingCycleEnd"]), 0, "On-demand"))
		}
	}

	var label string
	if name, ok := str(object(plan["planInfo"])["planName"]); ok {
		label = name
	} else {
		label, _ = str(status["grokPlanLabel"])
	}
	label = strings.TrimSpace(label)
	if merged, _ := plan["isMerged"].(bool); merged && !strings.Contains(strings.ToLower(label), "x pass") {
		if label == "" {
			label = "X Pass"
		} else {
			label = "X Pass " + label
		}
	}
	return Snapshot{Provider: Cursor, Windows: windows, AccountLabel: label, UpdatedAt: now}, nil
}

func cursorDate(v any) *time.Time {
	epoch := func(n float64) *time.Time {
		if n > 1e11 {
			n /= 1000
		}
		return ptr(unixSeconds(n))
	}
	switch x := v.(type) {
	case string:
		if t, ok := parseISO(x); ok {
			return &t
		}
		if n, ok := looseNumber(x); ok {
			return epoch(n)
		}
	case map[string]any:
		if n, ok := looseNumber(x["seconds"]); ok {
			return ptr(unixSeconds(n))
		}
	case float64, json.Number:
		n, _ := jsonNumber(x)
		return epoch(n)
	}
	return nil
}
