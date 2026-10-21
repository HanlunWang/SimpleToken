package history

import (
	"context"
	"sync"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/usage"
)

// RefreshInterval is how often Start merges a fresh tokscale graph.
const RefreshInterval = 15 * time.Minute

// GraphSource produces tokscale graph output (tokscale.Runner).
type GraphSource interface {
	Graph(ctx context.Context) (usage.Graph, error)
}

// Store owns the archive file: it loads it, absorbs the legacy Token Monitor archive once, merges a tokscale graph
// every RefreshInterval, and keeps the filtered daily summaries and the catalog derived from it.
//
// Store is safe for concurrent use. Everything it returns is shared and read-only: the archive is replaced, never
// mutated, on every change.
type Store struct {
	src         GraphSource
	path        string
	persist     bool
	interval    time.Duration
	refreshMu   sync.Mutex // one refresh at a time
	loopMu      sync.Mutex
	cancel      context.CancelFunc
	done        chan struct{}
	onChangeFn  func()
	mu          sync.RWMutex
	archive     *Archive
	daily       []DaySummary
	catalog     Catalog
	version     int
	imported    bool
	filter      Filter
	lastRefresh error
}

// NewStore loads the archive at path (an empty one when missing or unreadable) and absorbs the legacy archive at
// legacyPath, saving when that added anything. The legacy file is only read, never written. legacyPath may be "".
func NewStore(src GraphSource, path, legacyPath string) *Store {
	s := &Store{src: src, path: path, persist: true, interval: RefreshInterval}
	a, err := Load(path)
	if err != nil {
		a = NewArchive()
	}
	if legacyPath != "" {
		if legacy, err := Load(legacyPath); err == nil && a.Absorb(legacy, usage.DayKey(time.Now())) {
			_ = a.Save(path)
			s.imported = true
		}
	}
	s.archive = a
	s.recomputeLocked()
	return s
}

// SetOnChange sets the callback run (from any goroutine) after the summaries change. Set it before Start.
func (s *Store) SetOnChange(f func()) {
	s.loopMu.Lock()
	s.onChangeFn = f
	s.loopMu.Unlock()
}

func (s *Store) notify() {
	s.loopMu.Lock()
	f := s.onChangeFn
	s.loopMu.Unlock()
	if f != nil {
		f()
	}
}

// Start refreshes now and then every RefreshInterval until Stop or ctx ends. Starting twice is a no-op.
func (s *Store) Start(ctx context.Context) {
	s.loopMu.Lock()
	defer s.loopMu.Unlock()
	if s.cancel != nil {
		return
	}
	ctx, s.cancel = context.WithCancel(ctx)
	s.done = make(chan struct{})
	go func(done chan struct{}) {
		defer close(done)
		t := time.NewTicker(s.interval)
		defer t.Stop()
		for {
			_ = s.Refresh(ctx)
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}(s.done)
}

// Stop ends the refresh loop and waits for it (a running tokscale graph is cancelled).
func (s *Store) Stop() {
	s.loopMu.Lock()
	cancel, done := s.cancel, s.done
	s.cancel, s.done = nil, nil
	s.loopMu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
}

// Refresh merges a fresh tokscale graph and saves the archive. On error the archive is left as it was.
func (s *Store) Refresh(ctx context.Context) error {
	s.refreshMu.Lock()
	defer s.refreshMu.Unlock()
	g, err := s.src.Graph(ctx)
	s.mu.Lock()
	s.lastRefresh = err
	if err != nil {
		s.mu.Unlock()
		return err
	}
	next := s.archive.Clone()
	next.Merge(g, usage.DayKey(time.Now()))
	s.archive = next
	persist := s.persist
	s.recomputeLocked()
	s.mu.Unlock()
	var saveErr error
	if persist {
		saveErr = next.Save(s.path)
	}
	s.notify()
	return saveErr
}

// SetFilter replaces the usage filter and recomputes the summaries (nil includes everything).
func (s *Store) SetFilter(f Filter) {
	s.mu.Lock()
	s.filter = f
	s.recomputeLocked()
	s.mu.Unlock()
	s.notify()
}

// LoadDemo replaces the archive with synthetic data; nothing is saved from then on.
func (s *Store) LoadDemo(a *Archive) {
	s.mu.Lock()
	s.archive = a
	s.persist = false
	s.imported = false
	s.recomputeLocked()
	s.mu.Unlock()
	s.notify()
}

func (s *Store) recomputeLocked() {
	s.daily = s.archive.DailySummaries(0, usage.DayKey(time.Now()), s.filter)
	s.catalog = s.archive.Catalog()
	s.version++
}

// Archive is the current archive (read-only).
func (s *Store) Archive() *Archive {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.archive
}

// Daily is every archived day up to today, oldest first, after the filter (read-only).
func (s *Store) Daily() []DaySummary {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.daily
}

// Catalog lists every model and tool ever seen, regardless of the filter (read-only).
func (s *Store) Catalog() Catalog {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.catalog
}

// Version increases on every recompute: a cache key for data derived from Daily.
func (s *Store) Version() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.version
}

// ImportedFromLegacy reports whether this launch absorbed new data from the Token Monitor archive.
func (s *Store) ImportedFromLegacy() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.imported
}

// LastError is the last refresh's error, nil when it went through or none ran.
func (s *Store) LastError() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastRefresh
}
