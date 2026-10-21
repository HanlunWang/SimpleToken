package gui

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/egoist/mygo"
)

// Automatic updates: 30 s after launch, then every 6 h, the app checks the signed manifests of the GitHub
// release (the only request it makes on its own besides the limit probes), installs a newer version over the
// installed app and runs it at the next launch. Builds without an update key, and dev builds, never check.

const (
	updateFirstCheck = 30 * time.Second
	updateEvery      = 6 * time.Hour
)

type updates struct {
	mu      sync.Mutex
	busy    bool
	ready   string // installed, waiting for a relaunch
	checked time.Time
	err     string
}

func (u *updates) state() (busy bool, ready string, checked time.Time, err string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.busy, u.ready, u.checked, u.err
}

func (a *ctrl) startUpdates() {
	if !mygo.Updater.Enabled() {
		return
	}
	go func() {
		t := time.NewTimer(updateFirstCheck)
		defer t.Stop()
		for {
			select {
			case <-a.ctx.Done():
				return
			case <-t.C:
			}
			if a.m.s.AutoUpdate {
				a.installUpdate()
			}
			t.Reset(updateEvery)
		}
	}()
}

// installUpdate checks and installs a newer version (background goroutine).
func (a *ctrl) installUpdate() {
	u := &a.upd
	u.mu.Lock()
	if u.busy {
		u.mu.Unlock()
		return
	}
	u.busy = true
	u.mu.Unlock()
	mygo.RunOnMain(a.invalidate)
	ctx, cancel := context.WithTimeout(a.ctx, 10*time.Minute)
	defer cancel()
	var errText string
	up, err := mygo.Updater.Check(ctx)
	if err == nil && up != nil && up.Version != u.readyVersion() {
		if err = up.Install(ctx, nil); err == nil {
			u.mu.Lock()
			u.ready = up.Version
			u.mu.Unlock()
			log.Printf("update: installed %s; it runs at the next launch", up.Version)
		}
	}
	if err != nil {
		errText = err.Error()
		log.Printf("update: %v", err)
	}
	u.mu.Lock()
	u.busy, u.checked, u.err = false, time.Now(), errText
	u.mu.Unlock()
	mygo.RunOnMain(a.invalidate)
}

func (u *updates) readyVersion() string {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.ready
}
