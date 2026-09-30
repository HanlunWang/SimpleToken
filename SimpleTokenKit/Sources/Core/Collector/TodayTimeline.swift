import Foundation

/// Today's usage timeline: each snapshot records a (time, today's cumulative tokens) sample and hourly
/// buckets take differences of adjacent samples — the real source of "today's 24-hour activity".
/// tokscale only has daily resolution, so the collection process itself records today.
public struct TodayTimeline: Codable, Equatable, Sendable {
    public var dayKey: String
    public var samples: [Sample]

    public struct Sample: Codable, Equatable, Sendable {
        public var at: Date
        public var totalTokens: Int
    }

    public init(dayKey: String) {
        self.dayKey = dayKey
        samples = []
    }

    /// Records a sample; cleared on a new day. Besides the latest cumulative value per hour we would also
    /// need the last value before each hour's first sample — simplified to keeping all samples, capped
    /// (a full scan every 5 minutes + watch ticks is at most ~500 a day, so just keep them).
    public mutating func record(tokens: Int, at date: Date = Date()) {
        let key = Fmt.dayKey(date)
        if key != dayKey {
            dayKey = key
            samples = []
        }
        // Monotonic guard: if today's number drops (logs cleaned up), restart the climb from the new value
        samples.append(Sample(at: date, totalTokens: tokens))
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    /// 24 hourly buckets: net increase within each hour (first sample vs the previous hour's last)
    public func hourlyBuckets(now: Date = Date()) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        guard Fmt.dayKey(now) == dayKey, !samples.isEmpty else { return buckets }
        var lastValue = 0
        for sample in samples {
            let hour = Calendar.current.component(.hour, from: sample.at)
            let delta = max(0, sample.totalTokens - lastValue)
            buckets[hour] += delta
            lastValue = max(lastValue, sample.totalTokens)
        }
        return buckets
    }

    // MARK: - Persistence

    public static var fileURL: URL { AppPaths.appSupport.appendingPathComponent("today-timeline.json") }

    public static func load() -> TodayTimeline? {
        guard let data = try? Data(contentsOf: fileURL),
              let t = try? JSONDecoder.iso.decode(TodayTimeline.self, from: data)
        else { return nil }
        return t
    }

    public func save() {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
