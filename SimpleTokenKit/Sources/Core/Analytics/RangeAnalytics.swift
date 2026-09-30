import Foundation

/// Global time range (1D → ALL)
public enum TimeRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case day = "1D", week = "1W", month = "1M", quarter = "3M", half = "6M", ytd = "YTD", year = "1Y", all = "ALL"

    public var id: String { rawValue }

    public var localizedLabel: String {
        switch self {
        case .day: L("Today")
        case .week: L("Last 7 days")
        case .month: L("Last 30 days")
        case .quarter: L("Last 3 months")
        case .half: L("Last 6 months")
        case .ytd: L("Year to date")
        case .year: L("Last 12 months")
        case .all: L("All time")
        }
    }
}

/// Switchable main metric
public enum UsageMetric: String, CaseIterable, Codable, Sendable, Identifiable {
    case tokens, cost, messages
    public var id: String { rawValue }

    public var localizedLabel: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: L("Cost")
        case .messages: L("Messages")
        }
    }

    public func value(_ day: DailyHistoryArchive.DaySummary) -> Double {
        switch self {
        case .tokens: Double(day.tokens)
        case .cost: day.cost
        case .messages: Double(day.messages)
        }
    }
}

/// Full report for one time range: every card reads from it so they all agree.
public struct RangeReport: Sendable {
    public struct CumulativePoint: Sendable, Identifiable {
        public var id: Int { index }
        public let index: Int
        public let date: String
        /// Horizontal position in 0…1 (aligns this period with the previous one)
        public let position: Double
        public let cumulative: Double
        public let value: Double
    }

    public struct Share: Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let tokens: Int
        public let cost: Double
    }

    public struct Bucket: Sendable, Identifiable {
        public var id: String { start }
        public let start: String
        public let label: String
        /// Metric value per model (keyed by model id)
        public let byModel: [String: Double]
        public var total: Double { byModel.values.reduce(0, +) }
    }

    public struct Stats: Sendable {
        public let averagePerDay: Double
        public let averagePerActiveDay: Double
        public let peak: DailyHistoryArchive.DaySummary?
        public let activeDays: Int
        public let totalDays: Int
        public let streak: Int
        public let costPerMillion: Double
        public let totalCost: Double
    }

    public let range: TimeRange
    public let metric: UsageMetric
    /// Consecutive days in the range (missing days count as zero)
    public let days: [DailyHistoryArchive.DaySummary]
    public let previousDays: [DailyHistoryArchive.DaySummary]?
    public let current: [CumulativePoint]
    public let previous: [CumulativePoint]?
    public let total: Double
    public let previousTotal: Double?
    public let models: [Share]
    public let clients: [Share]
    public let buckets: [Bucket]
    public let weeklyBuckets: Bool
    public let stats: Stats

    /// Change from the previous period (%); nil without a previous period or when it is 0
    public var changePercent: Double? {
        guard let previousTotal, previousTotal > 0 else { return nil }
        return (total - previousTotal) / previousTotal * 100
    }
}

public enum RangeAnalytics {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    public static func date(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? Date()
    }

    /// Start of the range (inclusive). 1D = today; ALL = the earliest recorded day.
    public static func startDay(for range: TimeRange, todayKey: String, firstKey: String) -> String {
        let today = date(todayKey)
        func back(_ n: Int) -> String { Fmt.dayKey(calendar.date(byAdding: .day, value: -n, to: today)!) }
        switch range {
        case .day: return todayKey
        case .week: return back(6)
        case .month: return back(29)
        case .quarter: return back(89)
        case .half: return back(181)
        case .ytd: return String(todayKey.prefix(4)) + "-01-01"
        case .year: return back(364)
        case .all: return min(firstKey, todayKey)
        }
    }

    /// Consecutive days (endpoints included; missing days filled with zero)
    static func continuous(from start: String, to end: String,
                           byDate: [String: DailyHistoryArchive.DaySummary]) -> [DailyHistoryArchive.DaySummary] {
        guard start <= end else { return [] }
        var out: [DailyHistoryArchive.DaySummary] = []
        var cursor = date(start)
        let endDate = date(end)
        while cursor <= endDate {
            let key = Fmt.dayKey(cursor)
            out.append(byDate[key] ?? .init(date: key))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return out
    }

    /// Builds the report. `history` holds archived daily summaries; `liveToday`, if given, replaces today (it is newer than the archive).
    public static func report(range: TimeRange, metric: UsageMetric,
                              history: [DailyHistoryArchive.DaySummary],
                              liveToday: DailyHistoryArchive.DaySummary?,
                              todayKey: String = Fmt.dayKey()) -> RangeReport {
        var byDate = Dictionary(history.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        if let liveToday { byDate[todayKey] = liveToday }
        let firstKey = byDate.keys.min() ?? todayKey
        let start = startDay(for: range, todayKey: todayKey, firstKey: firstKey)
        let days = continuous(from: start, to: todayKey, byDate: byDate)

        // Previous period: the adjacent one of equal length; YTD uses the same span last year; ALL has none
        var previousDays: [DailyHistoryArchive.DaySummary]?
        switch range {
        case .all:
            previousDays = nil
        case .ytd:
            let lastYear = calendar.date(byAdding: .year, value: -1, to: date(todayKey))!
            let pEnd = Fmt.dayKey(lastYear)
            previousDays = continuous(from: String(pEnd.prefix(4)) + "-01-01", to: pEnd, byDate: byDate)
        default:
            let pEnd = Fmt.dayKey(calendar.date(byAdding: .day, value: -1, to: date(start))!)
            let pStart = Fmt.dayKey(calendar.date(byAdding: .day, value: -(days.count - 1), to: date(pEnd))!)
            previousDays = continuous(from: pStart, to: pEnd, byDate: byDate)
        }

        func cumulative(_ list: [DailyHistoryArchive.DaySummary]) -> [RangeReport.CumulativePoint] {
            var acc = 0.0
            let n = max(1, list.count - 1)
            return list.enumerated().map { i, d in
                let v = metric.value(d)
                acc += v
                return .init(index: i, date: d.date, position: list.count > 1 ? Double(i) / Double(n) : 1,
                             cumulative: acc, value: v)
            }
        }
        let current = cumulative(days)
        let previous = previousDays.map(cumulative)

        // Distribution: models and tools (tokens + cost)
        var modelTokens: [String: Int] = [:], modelCost: [String: Double] = [:], clientTokens: [String: Int] = [:]
        for d in days {
            for (m, t) in d.byModel { modelTokens[m, default: 0] += t }
            for (m, c) in d.costByModel { modelCost[m, default: 0] += c }
            for (c, t) in d.byClient { clientTokens[c, default: 0] += t }
        }
        let models = modelTokens.filter { $0.value > 0 }
            .map { RangeReport.Share(key: $0.key, tokens: $0.value, cost: modelCost[$0.key] ?? 0) }
            .sorted { $0.tokens > $1.tokens }
        let clients = clientTokens.filter { $0.value > 0 }
            .map { RangeReport.Share(key: $0.key, tokens: $0.value, cost: 0) }
            .sorted { $0.tokens > $1.tokens }

        // Bar buckets: weekly beyond 120 days, otherwise daily
        let weekly = days.count > 120
        let size = weekly ? 7 : 1
        var buckets: [RangeReport.Bucket] = []
        var i = 0
        while i < days.count {
            let group = days[i..<min(days.count, i + size)]
            var byModel: [String: Double] = [:]
            for d in group {
                let dayTotalTokens = Double(max(1, d.tokens))
                for (m, t) in d.byModel {
                    let v: Double
                    switch metric {
                    case .tokens: v = Double(t)
                    case .cost: v = d.costByModel[m] ?? 0
                    case .messages: v = Double(d.messages) * Double(t) / dayTotalTokens   // messages split by token share
                    }
                    if v > 0 { byModel[m, default: 0] += v }
                }
            }
            let first = group.first!.date
            buckets.append(.init(start: first, label: first, byModel: byModel))
            i += size
        }

        // Stat tiles
        let active = days.filter { $0.tokens > 0 }
        let totalTokens = days.reduce(0) { $0 + $1.tokens }
        let totalCost = days.reduce(0) { $0 + $1.cost }
        var streak = 0
        var cursor = date(todayKey)
        while let d = byDate[Fmt.dayKey(cursor)], d.tokens > 0 {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        let stats = RangeReport.Stats(
            averagePerDay: days.isEmpty ? 0 : Double(totalTokens) / Double(days.count),
            averagePerActiveDay: active.isEmpty ? 0 : Double(totalTokens) / Double(active.count),
            peak: days.max { $0.tokens < $1.tokens }.flatMap { $0.tokens > 0 ? $0 : nil },
            activeDays: active.count,
            totalDays: days.count,
            streak: streak,
            costPerMillion: totalTokens > 0 ? totalCost / (Double(totalTokens) / 1e6) : 0,
            totalCost: totalCost
        )

        return RangeReport(
            range: range, metric: metric, days: days, previousDays: previousDays,
            current: current, previous: previous,
            total: current.last?.cumulative ?? 0,
            previousTotal: previous?.last?.cumulative,
            models: models, clients: clients,
            buckets: buckets, weeklyBuckets: weekly, stats: stats
        )
    }

    /// Builds a daily summary from the live (today) snapshot, replacing the older today in the archive
    public static func liveDay(from period: UsagePeriod, dayKey: String) -> DailyHistoryArchive.DaySummary {
        .init(date: dayKey, tokens: period.totalTokens, cost: period.costUsd, messages: period.messages,
              byModel: period.byModel.mapValues(\.tokens),
              costByModel: period.byModel.mapValues(\.costUsd),
              byClient: period.byClient.mapValues(\.tokens))
    }

    /// This month's cost: cumulative by day, projected to month end from the daily average, plus last month's total
    public struct MonthCost: Sendable {
        public let days: [(date: String, cost: Double, cumulative: Double)]
        public let daysInMonth: Int
        public let projected: Double
        public let lastMonthTotal: Double
    }

    public static func monthCost(history: [DailyHistoryArchive.DaySummary],
                                 liveToday: DailyHistoryArchive.DaySummary?,
                                 todayKey: String = Fmt.dayKey()) -> MonthCost {
        var byDate = Dictionary(history.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        if let liveToday { byDate[todayKey] = liveToday }
        let today = date(todayKey)
        let monthStart = String(todayKey.prefix(7)) + "-01"
        let span = continuous(from: monthStart, to: todayKey, byDate: byDate)
        var acc = 0.0
        let days = span.map { d -> (String, Double, Double) in acc += d.cost; return (d.date, d.cost, acc) }
        let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
        let average = span.isEmpty ? 0 : acc / Double(span.count)
        let projected = acc + average * Double(daysInMonth - span.count)
        let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: date(monthStart))!
        let lastStart = Fmt.dayKey(lastMonthDate)
        let lastEnd = Fmt.dayKey(calendar.date(byAdding: .day, value: -1, to: date(monthStart))!)
        let lastTotal = continuous(from: lastStart, to: lastEnd, byDate: byDate).reduce(0) { $0 + $1.cost }
        return MonthCost(days: days, daysInMonth: daysInMonth, projected: projected, lastMonthTotal: lastTotal)
    }
}
