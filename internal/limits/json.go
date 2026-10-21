package limits

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Loosely typed JSON access: the providers' responses are undocumented and drift, so every probe reads them
// field by field from decoded maps rather than through fixed structs.

func decodeObject(data []byte) (map[string]any, bool) {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return nil, false
	}
	return m, true
}

func object(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func objects(v any) []map[string]any {
	list, _ := v.([]any)
	out := make([]map[string]any, 0, len(list))
	for _, e := range list {
		if m, ok := e.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func str(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

// first returns the first present (non-nil) value among keys.
func first(m map[string]any, keys ...string) any {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			return v
		}
	}
	return nil
}

// jsonNumber reads a JSON number only (no strings).
func jsonNumber(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}

// looseNumber also accepts numeric strings (protobuf JSON encodes 64-bit integers as strings).
func looseNumber(v any) (float64, bool) {
	if f, ok := jsonNumber(v); ok {
		return f, true
	}
	if s, ok := v.(string); ok {
		f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
		return f, err == nil
	}
	return 0, false
}

// parseISO reads an RFC 3339 timestamp, with or without fractional seconds.
func parseISO(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(s))
	return t, err == nil
}

// unixSeconds converts fractional epoch seconds to a time.
func unixSeconds(f float64) time.Time {
	sec := int64(f)
	return time.Unix(sec, int64((f-float64(sec))*1e9))
}

func ptr(t time.Time) *time.Time { return &t }

// networkReason is a short, URL-free description of a transport error for the UI (the URL can carry an
// organisation id; the UI only needs the cause).
func networkReason(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "the request timed out"
	}
	return err.Error()
}
