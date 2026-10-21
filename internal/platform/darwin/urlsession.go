//go:build darwin

package darwin

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

// URLSessionTransport is an http.RoundTripper backed by the system's NSURLSession (ephemeral: no cookie
// storage, no cache, no credentials). claude.ai sits behind Cloudflare, which challenges Go's TLS client but
// not Apple's networking stack, the one the Swift releases used; requests through it look like any Mac app's.
type URLSessionTransport struct {
	// Fallback serves requests when Foundation cannot be loaded (nil: http.DefaultTransport).
	Fallback http.RoundTripper
}

var (
	foundationOnce sync.Once
	foundationErr  error
	selCache       sync.Map
)

func loadFoundation() error {
	foundationOnce.Do(func() {
		_, foundationErr = purego.Dlopen(frameworks+"Foundation.framework/Foundation", rtld)
	})
	return foundationErr
}

func sel(name string) objc.SEL {
	if s, ok := selCache.Load(name); ok {
		return s.(objc.SEL)
	}
	s := objc.RegisterName(name)
	selCache.Store(name, s)
	return s
}

func class(name string) objc.ID { return objc.ID(objc.GetClass(name)) }

// nsString makes an autoreleased NSString; the caller holds an autorelease pool.
func nsString(s string) objc.ID {
	b := append([]byte(s), 0)
	id := class("NSString").Send(sel("stringWithUTF8String:"), unsafe.Pointer(&b[0]))
	runtime.KeepAlive(b)
	return id
}

func goString(id objc.ID) string {
	if id == 0 {
		return ""
	}
	p := objc.Send[*byte](id, sel("UTF8String"))
	if p == nil {
		return ""
	}
	n := 0
	for *(*byte)(unsafe.Add(unsafe.Pointer(p), n)) != 0 {
		n++
	}
	return string(unsafe.Slice(p, n))
}

// RoundTrip sends req with NSURLSession and waits for the whole response.
func (t *URLSessionTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if loadFoundation() != nil {
		fb := t.Fallback
		if fb == nil {
			fb = http.DefaultTransport
		}
		return fb.RoundTrip(req)
	}
	var body []byte
	if req.Body != nil {
		var err error
		if body, err = io.ReadAll(req.Body); err != nil {
			return nil, err
		}
		_ = req.Body.Close()
	}
	timeout := 30 * time.Second
	if d, ok := req.Context().Deadline(); ok {
		timeout = max(time.Second, time.Until(d))
	}

	type result struct {
		status int
		header http.Header
		data   []byte
		err    error
	}
	done := make(chan result, 1)
	var task objc.ID

	func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		pool := class("NSAutoreleasePool").Send(sel("alloc")).Send(sel("init"))
		defer pool.Send(sel("drain"))

		url := class("NSURL").Send(sel("URLWithString:"), nsString(req.URL.String()))
		if url == 0 {
			done <- result{err: errors.New("invalid URL")}
			return
		}
		r := class("NSMutableURLRequest").Send(sel("requestWithURL:"), url)
		r.Send(sel("setHTTPMethod:"), nsString(req.Method))
		r.Send(sel("setHTTPShouldHandleCookies:"), false)
		r.Send(sel("setTimeoutInterval:"), timeout.Seconds())
		for k, vs := range req.Header {
			r.Send(sel("setValue:forHTTPHeaderField:"), nsString(strings.Join(vs, ", ")), nsString(k))
		}
		if len(body) > 0 {
			data := class("NSData").Send(sel("dataWithBytes:length:"), unsafe.Pointer(&body[0]), uint(len(body)))
			r.Send(sel("setHTTPBody:"), data)
		}
		cfg := class("NSURLSessionConfiguration").Send(sel("ephemeralSessionConfiguration"))
		cfg.Send(sel("setHTTPCookieStorage:"), objc.ID(0))
		cfg.Send(sel("setURLCache:"), objc.ID(0))
		session := class("NSURLSession").Send(sel("sessionWithConfiguration:"), cfg)

		var block objc.Block
		block = objc.NewBlock(func(_ objc.Block, data, resp, nserr objc.ID) {
			var res result
			if nserr != 0 {
				res.err = errors.New(goString(nserr.Send(sel("localizedDescription"))))
			} else {
				res.status = int(objc.Send[int64](resp, sel("statusCode")))
				res.header = http.Header{}
				fields := resp.Send(sel("allHeaderFields"))
				keys := fields.Send(sel("allKeys"))
				n := int(objc.Send[uint64](keys, sel("count")))
				for i := range n {
					k := keys.Send(sel("objectAtIndex:"), uint64(i))
					res.header.Add(goString(k), goString(fields.Send(sel("objectForKey:"), k)))
				}
				if data != 0 {
					l := int(objc.Send[uint64](data, sel("length")))
					if l > 0 {
						p := objc.Send[unsafe.Pointer](data, sel("bytes"))
						res.data = bytes.Clone(unsafe.Slice((*byte)(p), l))
					}
				}
			}
			done <- res
		})
		task = session.Send(sel("dataTaskWithRequest:completionHandler:"), r, block)
		task.Send(sel("retain"))
		task.Send(sel("resume"))
		session.Send(sel("finishTasksAndInvalidate"))
		runtime.KeepAlive(body)
		// The block must outlive the task even when the caller gives up early; release it once the task cannot
		// call it any more.
		time.AfterFunc(timeout+5*time.Second, block.Release)
	}()

	var res result
	select {
	case res = <-done:
	case <-req.Context().Done():
		if task != 0 {
			task.Send(sel("cancel"))
		}
		return nil, req.Context().Err()
	}
	if task != 0 {
		task.Send(sel("release"))
	}
	if res.err != nil {
		return nil, res.err
	}
	return &http.Response{
		Status: http.StatusText(res.status), StatusCode: res.status, Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1,
		Header: res.header, Body: io.NopCloser(bytes.NewReader(res.data)), ContentLength: int64(len(res.data)), Request: req,
	}, nil
}

// OptionKeyDown reports whether ⌥ is held right now ([NSEvent modifierFlags]), for ⌥-clicks on the menu bar item.
func OptionKeyDown() bool {
	if loadFoundation() != nil {
		return false
	}
	if _, err := purego.Dlopen(frameworks+"AppKit.framework/AppKit", rtld); err != nil {
		return false
	}
	const optionMask = 1 << 19 // NSEventModifierFlagOption
	return objc.Send[uint64](class("NSEvent"), sel("modifierFlags"))&optionMask != 0
}
