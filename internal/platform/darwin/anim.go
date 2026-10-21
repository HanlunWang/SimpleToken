//go:build darwin

// Package darwin holds the few AppKit calls mygo does not expose, made through purego (no cgo).
package darwin

import (
	"runtime"
	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

// Window animations run in Core Animation: the window server interpolates every frame, which is far smoother
// than stepping the alpha from Go. (Adapted from SimpleToggle, same author, MIT.)

const (
	rtld       = purego.RTLD_NOW | purego.RTLD_GLOBAL
	frameworks = "/System/Library/Frameworks/"
)

type nsPoint struct{ X, Y float64 }
type nsSize struct{ W, H float64 }
type nsRect struct {
	Origin nsPoint
	Size   nsSize
}

var (
	animOnce        sync.Once
	animErr         error
	msgRect         func(obj objc.ID, sel objc.SEL) nsRect
	msgSetFrame     func(obj objc.ID, sel objc.SEL, r nsRect, display bool)
	msgSetDouble    func(obj objc.ID, sel objc.SEL, v float64)
	msgTimingPoints func(cls objc.Class, sel objc.SEL, a, b, c, d float32) objc.ID
)

func loadAnim() error {
	animOnce.Do(func() {
		objcLib, err := purego.Dlopen("/usr/lib/libobjc.A.dylib", rtld)
		if err != nil {
			animErr = err
			return
		}
		for _, fw := range []string{"QuartzCore.framework/QuartzCore", "AppKit.framework/AppKit"} {
			if _, err := purego.Dlopen(frameworks+fw, rtld); err != nil {
				animErr = err
				return
			}
		}
		send, err := purego.Dlsym(objcLib, "objc_msgSend")
		if err != nil {
			animErr = err
			return
		}
		stret := send // struct returns over 16 bytes use another entry point on amd64
		if runtime.GOARCH == "amd64" {
			if stret, err = purego.Dlsym(objcLib, "objc_msgSend_stret"); err != nil {
				animErr = err
				return
			}
		}
		purego.RegisterFunc(&msgRect, stret)
		purego.RegisterFunc(&msgSetFrame, send)
		purego.RegisterFunc(&msgSetDouble, send)
		purego.RegisterFunc(&msgTimingPoints, send)
	})
	return animErr
}

// RevealWindow fades a window in while it drops dy points into place (main thread). instant shows it at once.
func RevealWindow(handle uintptr, seconds, dy float64, instant bool) {
	win := objc.ID(handle)
	if win == 0 {
		return
	}
	if loadAnim() != nil || instant {
		if loadAnim() == nil {
			msgSetDouble(win, objc.RegisterName("setAlphaValue:"), 1)
		}
		return
	}
	frame := msgRect(win, objc.RegisterName("frame"))
	start := frame
	start.Origin.Y += dy // Cocoa's y axis points up: start dy points higher
	msgSetFrame(win, objc.RegisterName("setFrame:display:"), start, false)
	runAnimation(win, seconds, func(animator objc.ID) {
		msgSetDouble(animator, objc.RegisterName("setAlphaValue:"), 1)
		msgSetFrame(animator, objc.RegisterName("setFrame:display:"), frame, true)
	})
}

// FadeOutWindow fades a window out over seconds (main thread); the caller closes it afterwards.
func FadeOutWindow(handle uintptr, seconds float64) {
	win := objc.ID(handle)
	if win == 0 || loadAnim() != nil {
		return
	}
	runAnimation(win, seconds, func(animator objc.ID) {
		msgSetDouble(animator, objc.RegisterName("setAlphaValue:"), 0)
	})
}

func runAnimation(win objc.ID, seconds float64, body func(animator objc.ID)) {
	ctxCls := objc.ID(objc.GetClass("NSAnimationContext"))
	ctxCls.Send(objc.RegisterName("beginGrouping"))
	ctx := ctxCls.Send(objc.RegisterName("currentContext"))
	msgSetDouble(ctx, objc.RegisterName("setDuration:"), seconds)
	timing := msgTimingPoints(objc.GetClass("CAMediaTimingFunction"), objc.RegisterName("functionWithControlPoints::::"), 0.2, 0.9, 0.3, 1)
	ctx.Send(objc.RegisterName("setTimingFunction:"), timing)
	body(win.Send(objc.RegisterName("animator")))
	ctxCls.Send(objc.RegisterName("endGrouping"))
}
