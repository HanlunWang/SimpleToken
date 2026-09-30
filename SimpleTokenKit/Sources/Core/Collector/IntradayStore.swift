import Foundation
import Observation

/// Intraday usage: tokscale only has daily resolution, so this sums Claude Code session logs by timestamp
/// (assistant messages with message.usage in ~/.claude/projects/**/*.jsonl).
/// Only timestamps, model names and token counts are read, never conversation content. Files are read
/// incrementally by offset and deduplicated by message.id + requestId (streaming writes one message on
/// several lines). Keeps half-hour buckets per model for the last 90 days.
public actor IntradayScanner {
    public struct Snapshot: Sendable, Equatable {
        /// dayKey → model → 48 half-hour buckets (tokens)
        public var byModel: [String: [String: [Int]]] = [:]

        public init() {}

        /// Half-hour totals of a day (models can be excluded)
        public func buckets(for dayKey: String, excluding: Set<String> = []) -> [Int] {
            var out = Array(repeating: 0, count: 48)
            for (model, list) in byModel[dayKey] ?? [:] where !excluding.contains(model) {
                for i in 0..<min(48, list.count) { out[i] += list[i] }
            }
            return out
        }

        /// Half-hour buckets of a day, per model
        public func modelBuckets(for dayKey: String, excluding: Set<String> = []) -> [String: [Int]] {
            (byModel[dayKey] ?? [:]).filter { !excluding.contains($0.key) }
        }

        /// Days with intraday data (ascending)
        public var days: [String] { byModel.keys.sorted() }

        /// Weekday × hour matrix of the last N days (row 0 = Monday); each cell has a per-model split and the days it covers
        public func punchcard(days: Int, todayKey: String, excluding: Set<String> = []) -> Punchcard {
            var card = Punchcard()
            let cal = Calendar.current
            let today = RangeAnalytics.date(todayKey)
            for back in 0..<days {
                guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
                let weekday = (cal.component(.weekday, from: day) + 5) % 7   // Monday = 0
                card.dayCount[weekday] += 1
                for (model, list) in byModel[Fmt.dayKey(day)] ?? [:] where !excluding.contains(model) {
                    for (i, v) in list.enumerated() where v > 0 {
                        card.grid[weekday][i / 2] += v
                        card.models[weekday][i / 2][model, default: 0] += v
                    }
                }
            }
            return card
        }
    }

    /// Weekday × hour aggregate
    public struct Punchcard: Sendable, Equatable {
        public var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        public var models = Array(repeating: Array(repeating: [String: Int](), count: 24), count: 7)
        /// How often each weekday occurs in the window (for "average Monday")
        public var dayCount = Array(repeating: 0, count: 7)
        public init() {}
    }

    private let root: URL
    private let keepDays: Int
    private var offsets: [String: UInt64] = [:]
    /// Counted messages (64-bit FNV-1a hash of message.id + requestId):
    /// hashes instead of strings keep 90 days of several hundred thousand messages to a few MB
    private var seen: Set<UInt64> = []
    private var snapshot = Snapshot()

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                keepDays: Int = 90) {
        self.root = root
        self.keepDays = keepDays
    }

    /// Incremental scan: reads only the complete lines added to each file since last time
    public func scan(now: Date = Date()) -> Snapshot {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: now) ?? now
        let cutoffKey = Fmt.dayKey(cutoff)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return snapshot }

        var readBytes = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            let size = UInt64(values.fileSize ?? 0)
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 }            // file rewritten: read from the start; the dedup set prevents double counting
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            // Chunked reads: one chunk in memory, a partial line carries into the next (a partial line at EOF waits for the next scan)
            var carry = Data()
            while true {
                let chunk: Data? = autoreleasepool { try? handle.read(upToCount: Self.chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                carry.append(chunk)
                // Drain the autorelease pool per chunk so temporaries (date parsing etc.) do not pile up across chunks
                let consumed = autoreleasepool { carry.withUnsafeBytes { raw in ingestLines(raw, cutoffKey: cutoffKey) } }
                guard consumed > 0 else { continue }
                offset += UInt64(consumed)
                readBytes += consumed
                carry = carry.subdata(in: consumed..<carry.count)
            }
            offsets[url.path] = offset
        }
        snapshot.byModel = snapshot.byModel.filter { $0.key >= cutoffKey }
        // After the first full pass over hundreds of MB of logs, return the buffer pages to the system (otherwise tens of MB stay resident)
        if readBytes > 32 << 20 { malloc_zone_pressure_relief(nil, 0) }
        return snapshot
    }

    private static let chunkSize = 1 << 20

    // Byte-level field extraction: quotes inside JSON string values are escaped as \",
    // so an unescaped "usage":{ can only be a real key, never conversation text.
    // Searches use memchr / memmem directly on the raw buffer, with no slices or copies.
    private static let usageKey = Array("\"usage\":{".utf8)
    private static let timestampKey = Array("\"timestamp\":\"".utf8)
    private static let requestKey = Array("\"requestId\":\"".utf8)
    private static let messageIdKey = Array("\"id\":\"msg_".utf8)
    private static let modelKey = Array("\"model\":\"".utf8)
    private static let tokenKeys = ["\"input_tokens\":", "\"output_tokens\":",
                                    "\"cache_read_input_tokens\":", "\"cache_creation_input_tokens\":"].map { Array($0.utf8) }

    /// Local UTC offset (seconds), cached per UTC hour: correct across DST changes without a time zone lookup per line
    private var offsetCache: [Int: Int] = [:]
    /// Local day number → "yyyy-MM-dd"
    private var dayKeyCache: [Int: String] = [:]

    /// Processes complete lines; returns the bytes consumed (up to just after the last newline)
    private func ingestLines(_ raw: UnsafeRawBufferPointer, cutoffKey: String) -> Int {
        guard let base = raw.baseAddress else { return 0 }
        var lineStart = 0
        while lineStart < raw.count, let newline = memchr(base + lineStart, 0x0A, raw.count - lineStart) {
            let lineEnd = base.distance(to: UnsafeRawPointer(newline))
            if lineEnd > lineStart {
                ingest(UnsafeRawBufferPointer(rebasing: raw[lineStart..<lineEnd]), cutoffKey: cutoffKey)
            }
            lineStart = lineEnd + 1
        }
        return lineStart
    }

    /// First occurrence of needle in buf[from...]
    private static func find(_ needle: [UInt8], in buf: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        guard from < buf.count, let base = buf.baseAddress else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let hit = memmem(base + from, buf.count - from, n.baseAddress, n.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Last occurrence of needle in buf
    private static func findLast(_ needle: [UInt8], in buf: UnsafeRawBufferPointer) -> Int? {
        var last: Int?
        var from = 0
        while let i = find(needle, in: buf, from: from) {
            last = i
            from = i + 1
        }
        return last
    }

    /// Byte range of the string value after a key (up to the next quote)
    private static func valueRange(_ key: [UInt8], in buf: UnsafeRawBufferPointer, last: Bool) -> Range<Int>? {
        guard let at = last ? findLast(key, in: buf) : find(key, in: buf) else { return nil }
        let start = at + key.count
        var end = start
        while end < buf.count, buf[end] != UInt8(ascii: "\"") { end += 1 }
        guard end < buf.count else { return nil }
        return start..<end
    }

    /// String value after a key
    private static func stringValue(_ key: [UInt8], in buf: UnsafeRawBufferPointer, last: Bool) -> String? {
        valueRange(key, in: buf, last: last).map { String(decoding: UnsafeRawBufferPointer(rebasing: buf[$0]), as: UTF8.self) }
    }

    /// FNV-1a 64 over the raw bytes (no string is built)
    private static func fnv1a(_ ranges: [Range<Int>?], in buf: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for range in ranges {
            if let range { for i in range { hash = (hash ^ UInt64(buf[i])) &* 0x100000001b3 } }
            hash = (hash ^ 0x7C) &* 0x100000001b3   // separator, so "ab"+"c" and "a"+"bc" do not collide
        }
        return hash
    }

    /// Integer value after a key (searched in buf[from...])
    private static func intValue(_ key: [UInt8], in buf: UnsafeRawBufferPointer, from: Int) -> Int {
        guard let at = find(key, in: buf, from: from) else { return 0 }
        var i = at + key.count
        while i < buf.count, buf[i] == UInt8(ascii: " ") { i += 1 }
        var value = 0
        while i < buf.count, buf[i] >= 48, buf[i] <= 57 {
            value = value * 10 + Int(buf[i] - 48)
            i += 1
        }
        return value
    }

    private func ingest(_ line: UnsafeRawBufferPointer, cutoffKey: String) {
        // The usage object follows the assistant message body, so take the last occurrence; top-level timestamp / requestId are at the end too
        guard let usageAt = Self.findLast(Self.usageKey, in: line),
              let stampRange = Self.valueRange(Self.timestampKey, in: line, last: true),
              let epoch = Self.parseTimestamp(line, stampRange)
        else { return }
        let messageId = Self.valueRange(Self.messageIdKey, in: line, last: false)
        let requestId = Self.valueRange(Self.requestKey, in: line, last: true)
        guard messageId != nil || requestId != nil,
              seen.insert(Self.fnv1a([messageId, requestId], in: line)).inserted else { return }
        let tokens = Self.tokenKeys.reduce(0) { $0 + Self.intValue($1, in: line, from: usageAt) }
        guard tokens > 0 else { return }
        // Convert to local time: day number + half-hour index within the day
        let hour = Int((Double(epoch) / 3600).rounded(.down))
        let offset = offsetCache[hour] ?? {
            let o = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(hour * 3600)))
            offsetCache[hour] = o
            return o
        }()
        let local = epoch + offset
        let dayNumber = Int((Double(local) / 86400).rounded(.down))
        let dayKey = dayKeyCache[dayNumber] ?? {
            let (y, m, d) = Self.civilFromDays(dayNumber)
            let key = String(format: "%04d-%02d-%02d", y, m, d)
            dayKeyCache[dayNumber] = key
            return key
        }()
        guard dayKey >= cutoffKey else { return }
        let slot = (local - dayNumber * 86400) / 1800
        // model is the first key of the message object (before the body), so take the first occurrence
        var model = Self.stringValue(Self.modelKey, in: line, last: false) ?? "unknown"
        if model.isEmpty { model = "unknown" }
        var buckets = snapshot.byModel[dayKey]?[model] ?? Array(repeating: 0, count: 48)
        buckets[min(47, max(0, slot))] += tokens
        snapshot.byModel[dayKey, default: [:]][model] = buckets
    }

    // MARK: - Timestamps (parsed by hand: ISO8601DateFormatter goes through ICU and took 85% of scan time)

    /// "2026-09-29T14:03:12.345Z" / "…+08:00" → Unix seconds; nil if malformed
    static func parseTimestamp(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> Int? {
        let s = r.lowerBound
        guard r.count >= 19 else { return nil }
        func digits(_ at: Int, _ n: Int) -> Int? {
            var v = 0
            for i in at..<(at + n) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b[s + 4] == UInt8(ascii: "-"), b[s + 7] == UInt8(ascii: "-"), b[s + 10] == UInt8(ascii: "T"),
              let y = digits(s, 4), let mo = digits(s + 5, 2), let d = digits(s + 8, 2),
              let h = digits(s + 11, 2), let mi = digits(s + 14, 2), let sec = digits(s + 17, 2),
              (1...12).contains(mo), (1...31).contains(d)
        else { return nil }
        // Skip fractional seconds, read the time zone
        var i = s + 19
        if i < r.upperBound, b[i] == UInt8(ascii: ".") {
            i += 1
            while i < r.upperBound, b[i] >= 48, b[i] <= 57 { i += 1 }
        }
        var zone = 0
        if i < r.upperBound, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
            guard i + 6 <= r.upperBound, let zh = digits(i + 1, 2), let zm = digits(i + 4, 2) else { return nil }
            zone = (zh * 3600 + zm * 60) * (b[i] == UInt8(ascii: "+") ? 1 : -1)
        }
        return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - zone
    }

    /// Gregorian date → days since 1970-01-01 (Howard Hinnant's algorithm)
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Days → Gregorian date
    static func civilFromDays(_ z: Int) -> (Int, Int, Int) {
        let z = z + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Main-thread side: periodic incremental scans, publishes snapshots
@Observable
@MainActor
public final class IntradayStore {
    public private(set) var snapshot = IntradayScanner.Snapshot()
    private let scanner: IntradayScanner
    private var timer: Task<Void, Never>?

    public init(scanner: IntradayScanner = IntradayScanner()) {
        self.scanner = scanner
    }

    /// Demo mode: synthetic half-hour buckets, no log scanning
    public func loadDemo(_ demo: IntradayScanner.Snapshot) {
        isDemo = true
        snapshot = demo
    }
    private var isDemo = false

    /// Paused while no UI is visible (the menu bar needs no intraday data); catches up at once on resume
    public var paused = false {
        didSet { if !paused, oldValue { Task { await refresh() } } }
    }

    public func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if self?.paused == false { await self?.refresh() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    public func stop() { timer?.cancel() }

    public func refresh() async {
        guard !isDemo else { return }
        let next = await scanner.scan()
        if next != snapshot { snapshot = next }
    }
}
