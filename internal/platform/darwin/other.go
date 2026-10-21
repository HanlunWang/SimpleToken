//go:build !darwin

package darwin

import "net/http"

// RevealWindow and FadeOutWindow do nothing off macOS.
func RevealWindow(uintptr, float64, float64, bool) {}
func FadeOutWindow(uintptr, float64)               {}

// URLSessionTransport falls back to Go's transport off macOS.
type URLSessionTransport struct{ Fallback http.RoundTripper }

func (t *URLSessionTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if t.Fallback != nil {
		return t.Fallback.RoundTrip(req)
	}
	return http.DefaultTransport.RoundTrip(req)
}

// OptionKeyDown is always false off macOS.
func OptionKeyDown() bool { return false }
