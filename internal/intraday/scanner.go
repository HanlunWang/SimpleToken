// Package intraday adds the resolution tokscale lacks: a half-hour scanner over Claude Code's session logs, the
// sampled timeline of today's cumulative total, and the half-hourly archive of recent days.
package intraday

import (
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

// SlotsPerDay is the number of half-hour buckets in a day.
const SlotsPerDay = 48

// Snapshot is the scanner's state: dayKey → model → 48 half-hour token buckets. Treat it as read-only: Scan
// returns a fresh copy every time.
type Snapshot struct {
	ByModel map[string]map[string][]int64
}

// NewSnapshot returns an empty snapshot.
func NewSnapshot() Snapshot { return Snapshot{ByModel: map[string]map[string][]int64{}} }

// Buckets are a day's half-hour totals, without the excluded models.
func (s Snapshot) Buckets(dayKey string, excluding map[string]bool) []int64 {
	out := make([]int64, SlotsPerDay)
	for model, list := range s.ByModel[dayKey] {
		if excluding[model] {
			continue
		}
		for i := 0; i < min(SlotsPerDay, len(list)); i++ {
			out[i] += list[i]
		}
	}
	return out
}

// ModelBuckets are a day's half-hour buckets per model, without the excluded models.
func (s Snapshot) ModelBuckets(dayKey string, excluding map[string]bool) map[string][]int64 {
	out := map[string][]int64{}
	for model, list := range s.ByModel[dayKey] {
		if !excluding[model] {
			out[model] = list
		}
	}
	return out
}

// Days are the days with intraday data, ascending.
func (s Snapshot) Days() []string {
	keys := make([]string, 0, len(s.ByModel))
	for k := range s.ByModel {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Equal compares two snapshots bucket by bucket.
func (s Snapshot) Equal(o Snapshot) bool {
	if len(s.ByModel) != len(o.ByModel) {
		return false
	}
	for day, models := range s.ByModel {
		other, ok := o.ByModel[day]
		if !ok || len(other) != len(models) {
			return false
		}
		for m, list := range models {
			ol, ok := other[m]
			if !ok || !slicesEqual(list, ol) {
				return false
			}
		}
	}
	return true
}

func slicesEqual(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func (s Snapshot) clone() Snapshot {
	out := Snapshot{ByModel: make(map[string]map[string][]int64, len(s.ByModel))}
	for day, models := range s.ByModel {
		m := make(map[string][]int64, len(models))
		for k, v := range models {
			m[k] = append([]int64(nil), v...)
		}
		out.ByModel[day] = m
	}
	return out
}

// Punchcard is a weekday × hour aggregate (row 0 = Monday).
type Punchcard struct {
	Grid   [7][24]int64
	Models [7][24]map[string]int64
	// DayCount is how often each weekday occurs in the window (for "average Monday").
	DayCount [7]int
}

// Punchcard aggregates the last `days` days up to todayKey into a weekday × hour matrix, each cell with a
// per-model split, without the excluded models.
func (s Snapshot) Punchcard(days int, todayKey string, excluding map[string]bool) Punchcard {
	var card Punchcard
	for w := range card.Models {
		for h := range card.Models[w] {
			card.Models[w][h] = map[string]int64{}
		}
	}
	today, ok := format.DateFromKey(todayKey)
	if !ok {
		today = time.Now()
	}
	for back := 0; back < days; back++ {
		day := today.AddDate(0, 0, -back)
		weekday := format.WeekdayIndex(day)
		card.DayCount[weekday]++
		for model, list := range s.ByModel[format.DayKey(day)] {
			if excluding[model] {
				continue
			}
			for i, v := range list {
				if v > 0 && i < SlotsPerDay {
					card.Grid[weekday][i/2] += v
					card.Models[weekday][i/2][model] += v
				}
			}
		}
	}
	return card
}

// DefaultRoot is Claude Code's session log directory, ~/.claude/projects.
func DefaultRoot() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

// Scanner sums Claude Code session logs by timestamp: assistant messages with message.usage in
// <root>/**/*.jsonl. Only timestamps, model names and token counts are read, never conversation content. Files
// are read incrementally by offset and deduplicated by message.id + requestId (streaming writes one message on
// several lines). It keeps half-hour buckets per model for the last keepDays days. Safe for concurrent use;
// scans are serialised.
type Scanner struct {
	mu       sync.Mutex
	root     string
	keepDays int
	offsets  map[string]int64
	// seen holds counted messages as 64-bit FNV-1a hashes of message.id + requestId: hashes instead of strings
	// keep 90 days of several hundred thousand messages to a few MB.
	seen     map[uint64]struct{}
	snapshot Snapshot
	// offsetCache is the local UTC offset (seconds) per UTC hour: correct across DST without a zone lookup per line.
	offsetCache map[int64]int64
	// dayKeyCache maps a local day number to "yyyy-MM-dd".
	dayKeyCache map[int64]string
	cutoffKey   string
	buf         []byte
}

// NewScanner scans root (DefaultRoot when empty) and keeps keepDays days (90 when ≤ 0).
func NewScanner(root string, keepDays int) *Scanner {
	if root == "" {
		root = DefaultRoot()
	}
	if keepDays <= 0 {
		keepDays = 90
	}
	return &Scanner{
		root: root, keepDays: keepDays,
		offsets: map[string]int64{}, seen: map[uint64]struct{}{}, snapshot: NewSnapshot(),
		offsetCache: map[int64]int64{}, dayKeyCache: map[int64]string{},
	}
}

const chunkSize = 1 << 20

// Scan is an incremental scan: it reads only the complete lines added to each file since the last scan, and
// returns a copy of the state.
func (s *Scanner) Scan(now time.Time) Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := now.AddDate(0, 0, -s.keepDays)
	s.cutoffKey = format.DayKey(cutoff)

	if _, err := os.Stat(s.root); err != nil {
		return s.snapshot.clone()
	}
	readBytes := 0
	_ = filepath.WalkDir(s.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() && path != s.root {
				return fs.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") && path != s.root {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() || !d.Type().IsRegular() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		readBytes += s.readFile(path, info.Size())
		return nil
	})
	for k := range s.snapshot.ByModel {
		if k < s.cutoffKey {
			delete(s.snapshot.ByModel, k)
		}
	}
	// After the first full pass over hundreds of MB of logs, return the buffer pages to the system
	if readBytes > 32<<20 {
		s.buf = nil
		debug.FreeOSMemory()
	}
	return s.snapshot.clone()
}

// readFile ingests the complete lines past the stored offset; returns the bytes consumed.
func (s *Scanner) readFile(path string, size int64) int {
	offset := s.offsets[path]
	if size < offset {
		offset = 0 // file rewritten: read from the start; the dedup set prevents double counting
	}
	if size <= offset {
		return 0
	}
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return 0
	}
	if cap(s.buf) < 2*chunkSize {
		s.buf = make([]byte, 0, 2*chunkSize)
	}
	// Chunked reads: one chunk in memory, a partial line carries into the next (a partial line at EOF waits for
	// the next scan)
	carry := s.buf[:0]
	read := 0
	for {
		if cap(carry)-len(carry) < chunkSize {
			grown := make([]byte, len(carry), 2*cap(carry)+chunkSize)
			copy(grown, carry)
			carry = grown
		}
		n, err := f.Read(carry[len(carry) : len(carry)+chunkSize])
		if n > 0 {
			carry = carry[:len(carry)+n]
			if consumed := s.ingestLines(carry); consumed > 0 {
				offset += int64(consumed)
				read += consumed
				rest := copy(carry, carry[consumed:])
				carry = carry[:rest]
			}
		}
		if err != nil || n == 0 {
			break
		}
	}
	if cap(carry) <= 4*chunkSize {
		s.buf = carry[:0]
	}
	s.offsets[path] = offset
	return read
}

// ingestLines processes complete lines; returns the bytes consumed (up to just after the last newline).
func (s *Scanner) ingestLines(buf []byte) int {
	start := 0
	for start < len(buf) {
		nl := bytes.IndexByte(buf[start:], '\n')
		if nl < 0 {
			break
		}
		if nl > 0 {
			s.ingest(buf[start : start+nl])
		}
		start += nl + 1
	}
	return start
}

// Byte-level field extraction: quotes inside JSON string values are escaped as \", so an unescaped "usage":{
// can only be a real key, never conversation text.
var (
	usageKey     = []byte(`"usage":{`)
	timestampKey = []byte(`"timestamp":"`)
	requestKey   = []byte(`"requestId":"`)
	messageIDKey = []byte(`"id":"msg_`)
	modelKey     = []byte(`"model":"`)
	tokenKeys    = [][]byte{
		[]byte(`"input_tokens":`), []byte(`"output_tokens":`),
		[]byte(`"cache_read_input_tokens":`), []byte(`"cache_creation_input_tokens":`),
	}
)

type span struct{ start, end int }

// lastIndex is the last occurrence of key in line, found by repeated forward searches: bytes.Index is
// vectorised, bytes.LastIndex is not, and log lines run to megabytes.
func lastIndex(line, key []byte) int {
	at := bytes.Index(line, key)
	if at < 0 {
		return -1
	}
	for {
		next := bytes.Index(line[at+1:], key)
		if next < 0 {
			return at
		}
		at += 1 + next
	}
}

// valueRange is the byte range of the string value after a key (up to the next quote).
func valueRange(key, line []byte, last bool) (span, bool) {
	var at int
	if last {
		at = lastIndex(line, key)
	} else {
		at = bytes.Index(line, key)
	}
	if at < 0 {
		return span{}, false
	}
	start := at + len(key)
	end := bytes.IndexByte(line[start:], '"')
	if end < 0 {
		return span{}, false
	}
	return span{start, start + end}, true
}

// intValue is the integer after a key, searched in line[from:].
func intValue(key, line []byte, from int) int64 {
	at := bytes.Index(line[from:], key)
	if at < 0 {
		return 0
	}
	i := from + at + len(key)
	for i < len(line) && line[i] == ' ' {
		i++
	}
	var v int64
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		v = v*10 + int64(line[i]-'0')
		i++
	}
	return v
}

// fnv1a is FNV-1a 64 over the ranges, each followed by a separator so "ab"+"c" and "a"+"bc" do not collide.
func fnv1a(line []byte, ranges ...*span) uint64 {
	h := uint64(0xcbf29ce484222325)
	for _, r := range ranges {
		if r != nil {
			for _, c := range line[r.start:r.end] {
				h = (h ^ uint64(c)) * 0x100000001b3
			}
		}
		h = (h ^ 0x7C) * 0x100000001b3
	}
	return h
}

func (s *Scanner) ingest(line []byte) {
	// The usage object follows the assistant message body, so take the last occurrence; top-level timestamp /
	// requestId are at the end too
	usageAt := lastIndex(line, usageKey)
	if usageAt < 0 {
		return
	}
	stamp, ok := valueRange(timestampKey, line, true)
	if !ok {
		return
	}
	epoch, ok := ParseTimestamp(line[stamp.start:stamp.end])
	if !ok {
		return
	}
	var mid, rid *span
	if r, ok := valueRange(messageIDKey, line, false); ok {
		mid = &r
	}
	if r, ok := valueRange(requestKey, line, true); ok {
		rid = &r
	}
	if mid == nil && rid == nil {
		return
	}
	h := fnv1a(line, mid, rid)
	if _, dup := s.seen[h]; dup {
		return
	}
	s.seen[h] = struct{}{}
	var tokens int64
	for _, k := range tokenKeys {
		tokens += intValue(k, line, usageAt)
	}
	if tokens <= 0 {
		return
	}
	// Convert to local time: day number + half-hour index within the day
	hour := floorDiv(epoch, 3600)
	offset, ok := s.offsetCache[hour]
	if !ok {
		_, o := time.Unix(hour*3600, 0).In(time.Local).Zone()
		offset = int64(o)
		s.offsetCache[hour] = offset
	}
	local := epoch + offset
	dayNumber := floorDiv(local, 86400)
	dayKey, ok := s.dayKeyCache[dayNumber]
	if !ok {
		y, m, d := CivilFromDays(dayNumber)
		dayKey = pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
		s.dayKeyCache[dayNumber] = dayKey
	}
	if dayKey < s.cutoffKey {
		return
	}
	slot := min(SlotsPerDay-1, max(0, int((local-dayNumber*86400)/1800)))
	// model is the first key of the message object (before the body), so take the first occurrence
	model := "unknown"
	if r, ok := valueRange(modelKey, line, false); ok && r.end > r.start {
		model = string(line[r.start:r.end])
	}
	day := s.snapshot.ByModel[dayKey]
	if day == nil {
		day = map[string][]int64{}
		s.snapshot.ByModel[dayKey] = day
	}
	buckets := day[model]
	if buckets == nil {
		buckets = make([]int64, SlotsPerDay)
		day[model] = buckets
	}
	buckets[slot] += tokens
}

func pad(v int64, width int) string {
	s := strconv.FormatInt(v, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

// ParseTimestamp parses "2026-09-29T14:03:12.345Z" / "…+08:00" into Unix seconds (fraction dropped) by hand:
// a general ISO 8601 parser per line dominated the scan time. ok is false when malformed.
func ParseTimestamp(b []byte) (int64, bool) {
	if len(b) < 19 {
		return 0, false
	}
	digits := func(at, n int) (int64, bool) {
		var v int64
		for i := at; i < at+n; i++ {
			c := b[i]
			if c < '0' || c > '9' {
				return 0, false
			}
			v = v*10 + int64(c-'0')
		}
		return v, true
	}
	if b[4] != '-' || b[7] != '-' || b[10] != 'T' {
		return 0, false
	}
	y, ok1 := digits(0, 4)
	mo, ok2 := digits(5, 2)
	d, ok3 := digits(8, 2)
	h, ok4 := digits(11, 2)
	mi, ok5 := digits(14, 2)
	sec, ok6 := digits(17, 2)
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) || mo < 1 || mo > 12 || d < 1 || d > 31 {
		return 0, false
	}
	// Skip fractional seconds, read the time zone
	i := 19
	if i < len(b) && b[i] == '.' {
		i++
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
	}
	var zone int64
	if i < len(b) && (b[i] == '+' || b[i] == '-') {
		if i+6 > len(b) {
			return 0, false
		}
		zh, okh := digits(i+1, 2)
		zm, okm := digits(i+4, 2)
		if !okh || !okm {
			return 0, false
		}
		zone = zh*3600 + zm*60
		if b[i] == '-' {
			zone = -zone
		}
	}
	return DaysFromCivil(y, mo, d)*86400 + h*3600 + mi*60 + sec - zone, true
}

// DaysFromCivil is a Gregorian date as days since 1970-01-01 (Howard Hinnant's algorithm).
func DaysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := y
	if y < 0 {
		era = y - 399
	}
	era /= 400
	yoe := y - era*400
	mp := m + 9
	if m > 2 {
		mp = m - 3
	}
	doy := (153*mp+2)/5 + d - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// CivilFromDays is the inverse of DaysFromCivil.
func CivilFromDays(z int64) (y, m, d int64) {
	z += 719468
	era := z
	if z < 0 {
		era = z - 146096
	}
	era /= 146097
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = doy - (153*mp+2)/5 + 1
	m = mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	y = yoe + era*400
	if m <= 2 {
		y++
	}
	return y, m, d
}

// ── store ──

// Store is the app side: periodic incremental scans (every minute while not paused) and the latest snapshot.
type Store struct {
	scanner *Scanner
	mu      sync.Mutex
	snap    Snapshot
	demo    bool
	paused  bool
	wake    chan struct{}
}

// NewStore wraps a scanner.
func NewStore(scanner *Scanner) *Store {
	return &Store{scanner: scanner, snap: NewSnapshot(), wake: make(chan struct{}, 1)}
}

// Snapshot is the latest snapshot (read-only).
func (s *Store) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snap
}

// LoadDemo switches to synthetic buckets; logs are never scanned afterwards.
func (s *Store) LoadDemo(demo Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.demo = true
	s.snap = demo
}

// SetPaused pauses scanning while no UI is visible (the menu bar needs no intraday data); resuming catches up at
// once.
func (s *Store) SetPaused(paused bool) {
	s.mu.Lock()
	was := s.paused
	s.paused = paused
	s.mu.Unlock()
	if was && !paused {
		select {
		case s.wake <- struct{}{}:
		default:
		}
	}
}

// Refresh scans now; changed reports whether the snapshot differs from the previous one.
func (s *Store) Refresh() (snap Snapshot, changed bool) {
	s.mu.Lock()
	demo := s.demo
	s.mu.Unlock()
	if demo {
		return s.Snapshot(), false
	}
	next := s.scanner.Scan(time.Now())
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.demo {
		return s.snap, false
	}
	if next.Equal(s.snap) {
		return s.snap, false
	}
	s.snap = next
	return next, true
}

// Run scans every interval (60 s when ≤ 0) while not paused, and on resume, until done is closed. onChange,
// when set, gets every changed snapshot.
func (s *Store) Run(done <-chan struct{}, interval time.Duration, onChange func(Snapshot)) {
	if interval <= 0 {
		interval = time.Minute
	}
	tick := time.NewTicker(interval)
	defer tick.Stop()
	refresh := func() {
		s.mu.Lock()
		paused := s.paused
		s.mu.Unlock()
		if paused {
			return
		}
		if snap, changed := s.Refresh(); changed && onChange != nil {
			onChange(snap)
		}
	}
	refresh()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			refresh()
		case <-s.wake:
			refresh()
		}
	}
}
