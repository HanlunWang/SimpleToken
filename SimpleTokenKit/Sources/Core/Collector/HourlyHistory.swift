import Foundation

/// Half-hourly usage history (last 14 days): the collection timeline recomputes today's buckets on every snapshot and saves them.
/// Source for the fine-grained "today / last 48 hours" stats — tokscale only has daily resolution, so we record this ourselves.
public struct HourlyHistory: Codable, Equatable, Sendable {
    /// dayKey → 48 half-hour buckets (net token increase)
    public var days: [String: [Int]]

    public init() { days = [:] }

    public mutating func set(dayKey: String, halfHourBuckets: [Int], todayKey: String) {
        days[dayKey] = halfHourBuckets
        // Keep 14 days
        let sorted = days.keys.sorted()
        if sorted.count > 14 {
            for stale in sorted.prefix(sorted.count - 14) { days.removeValue(forKey: stale) }
        }
        days = days.filter { $0.key <= todayKey }
    }

    /// Hourly buckets of the last N hours (joined across days; last = current hour)
    public func rollingHourly(hours: Int, now: Date = Date()) -> [Int] {
        var out: [Int] = []
        let cal = Calendar.current
        let currentHour = cal.component(.hour, from: now)
        var cursorDay = now
        var cursorHour = currentHour
        for _ in 0..<hours {
            let key = Fmt.dayKey(cursorDay)
            let buckets = days[key] ?? []
            let a = cursorHour * 2, b = a + 1
            let v = (buckets.indices.contains(a) ? buckets[a] : 0)
                  + (buckets.indices.contains(b) ? buckets[b] : 0)
            out.append(v)
            cursorHour -= 1
            if cursorHour < 0 {
                cursorHour = 23
                cursorDay = cal.date(byAdding: .day, value: -1, to: cursorDay)!
            }
        }
        return out.reversed()
    }

    // MARK: - Persistence

    public static var fileURL: URL { AppPaths.appSupport.appendingPathComponent("hourly-history.json") }

    public static func load() -> HourlyHistory? {
        guard let data = try? Data(contentsOf: fileURL),
              let h = try? JSONDecoder().decode(HourlyHistory.self, from: data)
        else { return nil }
        return h
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

public extension TodayTimeline {
    /// 48 half-hour buckets (today)
    func halfHourBuckets(now: Date = Date()) -> [Int] {
        var buckets = [Int](repeating: 0, count: 48)
        guard Fmt.dayKey(now) == dayKey, !samples.isEmpty else { return buckets }
        var lastValue = 0
        let cal = Calendar.current
        for sample in samples {
            let hour = cal.component(.hour, from: sample.at)
            let half = cal.component(.minute, from: sample.at) >= 30 ? 1 : 0
            let delta = max(0, sample.totalTokens - lastValue)
            buckets[hour * 2 + half] += delta
            lastValue = max(lastValue, sample.totalTokens)
        }
        return buckets
    }
}
