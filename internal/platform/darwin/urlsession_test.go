//go:build darwin

package darwin

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestURLSessionTransport(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		w.Header().Set("X-Echo", r.Header.Get("X-Probe"))
		w.Header().Set("Set-Cookie", "k=v; Path=/")
		w.WriteHeader(201)
		_, _ = w.Write([]byte(r.Method + " " + string(b) + " " + r.Header.Get("Cookie")))
	}))
	defer srv.Close()
	c := &http.Client{Transport: &URLSessionTransport{}, Timeout: 10 * time.Second}
	for range 3 { // cookies must not persist between requests
		req, _ := http.NewRequestWithContext(context.Background(), "POST", srv.URL, strings.NewReader("{}"))
		req.Header.Set("X-Probe", "hello")
		req.Header.Set("Cookie", "a=b")
		resp, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != 201 || resp.Header.Get("X-Echo") != "hello" || string(b) != "POST {} a=b" {
			t.Fatalf("status %d echo %q body %q", resp.StatusCode, resp.Header.Get("X-Echo"), b)
		}
	}
	// A dead server is an error, not a hang.
	srv.Close()
	if _, err := c.Get(srv.URL); err == nil {
		t.Fatal("want an error from a closed server")
	}
}
