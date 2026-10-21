package limits

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"
)

// ClaudeWebBaseURL is claude.ai. Tests point a probe's BaseURL elsewhere.
const ClaudeWebBaseURL = "https://claude.ai"

// claudeBrowserUA is a browser user agent: claude.ai answers an honest client with a Cloudflare 403.
const claudeBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

// ClaudeWebProbe reads the Claude plan limits from claude.ai with the owner-pasted sessionKey cookie (new Claude
// Code builds keep no OAuth token on disk). Flow:
//
//	GET /api/organizations           → pick an organisation (chat-capable first)
//	GET /api/organizations/{id}/usage → five_hour / seven_day / limits[] (Fable)
//
// A response may rotate the sessionKey through Set-Cookie; the caller must persist the renewed key or the old
// one stops working.
type ClaudeWebProbe struct {
	SessionKey string
	// BaseURL defaults to ClaudeWebBaseURL.
	BaseURL string
	// Client defaults to a cookie-jar-free client with a 12 s timeout.
	Client *http.Client
}

// ClaudeWebResult is one successful probe.
type ClaudeWebResult struct {
	Snapshot Snapshot
	// RenewedSessionKey is non-empty when claude.ai rotated the key; the caller must persist it.
	RenewedSessionKey string
	// OrganizationID is the organisation read, for the caller to cache.
	OrganizationID string
}

// NormalizeSessionKey trims a pasted cookie, drops a leading "sessionKey=" and checks the sk-ant- prefix.
func NormalizeSessionKey(cookie string) (string, error) {
	key := strings.TrimSpace(cookie)
	key = strings.ReplaceAll(key, "sessionKey=", "")
	if !strings.HasPrefix(key, "sk-ant-") {
		return "", ErrInvalidCookie
	}
	return key, nil
}

// NewClaudeWebProbe validates the cookie (ErrInvalidCookie unless it is an sk-ant- key).
func NewClaudeWebProbe(cookie string) (*ClaudeWebProbe, error) {
	key, err := NormalizeSessionKey(cookie)
	if err != nil {
		return nil, err
	}
	return &ClaudeWebProbe{SessionKey: key}, nil
}

// Transport, when set, carries the probes' HTTPS (the app sets the system's URLSession: claude.ai's Cloudflare
// challenges Go's TLS client). Nil uses Go's default transport, as the tests do.
var Transport http.RoundTripper

func probeClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, Transport: Transport}
}

// Probe reads the usage. With a cached organisation id the organisation list is skipped.
func (p *ClaudeWebProbe) Probe(ctx context.Context, cachedOrganizationID string) (ClaudeWebResult, error) {
	current := p.SessionKey
	orgID := cachedOrganizationID
	if orgID == "" {
		data, renewed, err := p.get(ctx, "/api/organizations", current)
		if err != nil {
			return ClaudeWebResult{}, err
		}
		if renewed != "" {
			current = renewed
		}
		if orgID, err = selectClaudeOrganization(data); err != nil {
			return ClaudeWebResult{}, err
		}
	}
	data, renewed, err := p.get(ctx, "/api/organizations/"+orgID+"/usage", current)
	if err != nil {
		return ClaudeWebResult{}, err
	}
	if renewed != "" {
		current = renewed
	}
	snap, err := parseClaudeUsage(data, time.Now())
	if err != nil {
		return ClaudeWebResult{}, err
	}
	res := ClaudeWebResult{Snapshot: snap, OrganizationID: orgID}
	if current != p.SessionKey {
		res.RenewedSessionKey = current
	}
	return res, nil
}

func (p *ClaudeWebProbe) get(ctx context.Context, path, key string) ([]byte, string, error) {
	base := p.BaseURL
	if base == "" {
		base = ClaudeWebBaseURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+path, nil)
	if err != nil {
		return nil, "", Unavailable{Reason: err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Cookie", "sessionKey="+key)
	req.Header.Set("User-Agent", claudeBrowserUA)
	client := p.Client
	if client == nil {
		client = probeClient(12 * time.Second)
	}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, "", ctx.Err()
		}
		return nil, "", Unavailable{Reason: networkReason(err)}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode <= 299:
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		if resp.Header.Get("cf-mitigated") == "challenge" {
			return nil, "", ErrChallenge
		}
		return nil, "", ErrUnauthorized
	case resp.StatusCode == 429:
		return nil, "", ErrRateLimited
	default:
		return nil, "", Unavailable{Reason: fmt.Sprintf("http %d", resp.StatusCode)}
	}
	if err != nil {
		return nil, "", Unavailable{Reason: networkReason(err)}
	}
	return body, renewedSessionKey(resp.Header), nil
}

// renewedSessionKey is the latest sk-ant- sessionKey set by the response. Set-Cookie may arrive as several
// headers or comma-joined into one; both are split the same way.
func renewedSessionKey(h http.Header) string {
	latest := ""
	for _, header := range h.Values("Set-Cookie") {
		for _, chunk := range strings.FieldsFunc(header, func(r rune) bool { return r == ',' || r == '\r' || r == '\n' }) {
			trimmed := strings.TrimSpace(chunk)
			if !strings.HasPrefix(strings.ToLower(trimmed), "sessionkey=") {
				continue
			}
			value := trimmed[len("sessionKey="):]
			value, _, _ = strings.Cut(value, ";")
			value = strings.TrimSpace(value)
			if strings.HasPrefix(value, "sk-ant-") {
				latest = value
			}
		}
	}
	return latest
}

// selectClaudeOrganization picks the organisation: chat-capable, else not API-only, else the first.
func selectClaudeOrganization(data []byte) (string, error) {
	var root any
	if err := json.Unmarshal(data, &root); err != nil {
		return "", Unavailable{Reason: "organizations: not json"}
	}
	var list []map[string]any
	switch r := root.(type) {
	case []any:
		list = objects(r)
	case map[string]any:
		list = objects(first(r, "organizations", "data"))
	}
	orgID := func(o map[string]any) string {
		for _, k := range []string{"uuid", "id", "organization_uuid"} {
			if v, ok := str(o[k]); ok && v != "" {
				return v
			}
		}
		return ""
	}
	capabilities := func(o map[string]any) []string {
		var caps []string
		for _, c := range asSlice(o["capabilities"]) {
			if s, ok := c.(string); ok && !slices.Contains(caps, s) {
				caps = append(caps, s)
			}
		}
		return caps
	}
	var candidates []map[string]any
	for _, o := range list {
		if orgID(o) != "" {
			candidates = append(candidates, o)
		}
	}
	for _, o := range candidates {
		if slices.Contains(capabilities(o), "chat") {
			return orgID(o), nil
		}
	}
	for _, o := range candidates {
		if c := capabilities(o); !(len(c) == 1 && c[0] == "api") {
			return orgID(o), nil
		}
	}
	if len(candidates) > 0 {
		return orgID(candidates[0]), nil
	}
	return "", Unavailable{Reason: "no organization"}
}

// parseClaudeUsage turns the usage response into windows: five_hour (session), seven_day (weekly) and the
// weekly_scoped Fable entry of limits[] (a time-limited quota found only in the structured array).
func parseClaudeUsage(data []byte, now time.Time) (Snapshot, error) {
	root, ok := decodeObject(data)
	if !ok {
		return Snapshot{}, Unavailable{Reason: "usage: not json"}
	}
	percent := func(o map[string]any) (float64, bool) {
		for _, k := range []string{"utilization", "usedPercent", "used_percent", "percent"} {
			if v, ok := jsonNumber(o[k]); ok {
				return v, true
			}
		}
		return 0, false
	}
	reset := func(o map[string]any) *time.Time {
		for _, k := range []string{"resets_at", "resetsAt"} {
			if s, ok := str(o[k]); ok {
				if t, ok := parseISO(s); ok {
					return &t
				}
				return nil
			}
		}
		return nil
	}
	var windows []Window
	window := func(kind Kind, keys ...string) {
		for _, k := range keys {
			o := object(root[k])
			if o == nil {
				continue
			}
			if p, ok := percent(o); ok {
				windows = append(windows, NewWindow(kind, p, reset(o), 0, ""))
				return
			}
		}
	}
	window(Session, "five_hour", "fiveHour")
	window(Weekly, "seven_day", "sevenDay")

	for _, entry := range objects(root["limits"]) {
		if k, _ := str(entry["kind"]); k != "weekly_scoped" {
			continue
		}
		display, _ := str(object(object(entry["scope"])["model"])["display_name"])
		if strings.ToLower(display) != "fable" {
			continue
		}
		source := object(entry["usage"])
		if source == nil {
			source = entry
		}
		p, ok := percent(source)
		if !ok {
			continue
		}
		r := reset(source)
		if r == nil {
			r = reset(entry)
		}
		windows = append(windows, NewWindow(Fable, p, r, 0, ""))
	}
	if len(windows) == 0 {
		return Snapshot{}, Unavailable{Reason: "usage: no windows"}
	}
	return Snapshot{Provider: Claude, Windows: windows, UpdatedAt: now}, nil
}

// ClaudePlanLabel turns Claude Code's subscriptionType / rateLimitTier metadata into a plan label: max with a
// *_20x tier is "Max 20x"; otherwise the capitalised subscription name, else the tier words.
func ClaudePlanLabel(subscriptionType, rateLimitTier string) string {
	sub := strings.ToLower(strings.TrimSpace(subscriptionType))
	var tierWords []string
	for _, w := range strings.FieldsFunc(rateLimitTier, func(r rune) bool { return r == '_' || r == '-' || r == ' ' }) {
		if !slices.Contains([]string{"default", "claude", "ai", "raven"}, strings.ToLower(w)) {
			tierWords = append(tierWords, w)
		}
	}
	tierParts := make([]string, len(tierWords))
	for i, w := range tierWords {
		if len([]rune(w)) <= 3 {
			tierParts[i] = strings.ToLower(w)
		} else {
			tierParts[i] = capitalize(w)
		}
	}
	subLabel := ""
	if sub == "max" {
		subLabel = "Max"
	} else if sub != "" {
		subLabel = capitalizeWords(sub)
	}
	if subLabel == "Max" {
		for i := len(tierWords) - 1; i >= 0; i-- {
			if strings.HasSuffix(strings.ToLower(tierWords[i]), "x") {
				return "Max " + strings.ToLower(tierWords[i])
			}
		}
	}
	if subLabel == "" {
		return strings.Join(tierParts, " ")
	}
	return subLabel
}

// capitalize upper-cases the first letter and lower-cases the rest (Foundation's `capitalized` for one word).
func capitalize(w string) string {
	r := []rune(strings.ToLower(w))
	if len(r) == 0 {
		return ""
	}
	return strings.ToUpper(string(r[0])) + string(r[1:])
}

func capitalizeWords(s string) string {
	words := strings.Fields(s)
	for i, w := range words {
		words[i] = capitalize(w)
	}
	return strings.Join(words, " ")
}

func asSlice(v any) []any {
	s, _ := v.([]any)
	return s
}
