import Foundation

/// Synthetic usage for screenshots and demos. Turned on with the environment variable
/// `SIMPLETOKEN_DEMO=1` (or the `demoMode` user default); the collectors do not run then,
/// so no real logs are read and nothing is written.
public enum DemoData {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SIMPLETOKEN_DEMO"] == "1" || UserDefaults.standard.bool(forKey: "demoMode")
    }

    /// (client, model, provider, share of the day's tokens, cost per million tokens)
    private static let mix: [(String, String, String, Double, Double)] = [
        ("claude", "claude-opus-5", "anthropic", 0.46, 0.92),
        ("claude", "claude-sonnet-5", "anthropic", 0.27, 0.41),
        ("claude", "claude-haiku-5", "anthropic", 0.06, 0.12),
        ("codex", "gpt-5.3-codex", "openai", 0.14, 0.55),
        ("gemini", "gemini-3-pro", "google", 0.05, 0.48),
        ("copilot", "gpt-5-mini", "openai", 0.02, 0.20),
    ]

    /// Small deterministic generator, so every screenshot shows the same numbers.
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Day totals for the last `days` days, oldest first.
    private static func dailyTokens(days: Int, today: Date) -> [(key: String, tokens: Double)] {
        var rng = Random(state: 42)
        let cal = Calendar.current
        return (0..<days).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: today)!
            let weekday = cal.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            // A slow upward trend, quieter weekends, the odd day off
            let trend = 0.45 + 0.55 * Double(days - offset) / Double(days)
            var tokens = (weekend ? 38e6 : 150e6) * trend * (0.55 + rng.next() * 0.9)
            if rng.next() < (weekend ? 0.35 : 0.04) { tokens = 0 }
            if offset == 0 { tokens = 96e6 }
            return (Fmt.dayKey(date), tokens)
        }
    }

    public static func archive(today: Date = Date()) -> DailyHistoryArchive {
        var archive = DailyHistoryArchive()
        var rng = Random(state: 7)
        for (key, total) in dailyTokens(days: 240, today: today) where total > 0 {
            var observations: [String: DailyHistoryArchive.Observation] = [:]
            for (client, model, provider, share, perMillion) in mix {
                let tokens = Int(total * share * (0.7 + rng.next() * 0.6))
                guard tokens > 0 else { continue }
                observations[DailyHistoryArchive.observationKey(client: client, modelId: model)] = .init(
                    client: client, modelId: model, providerId: provider, tokens: tokens,
                    cost: Double(tokens) / 1e6 * perMillion, messages: max(1, tokens / 280_000), reasoningTokens: nil)
            }
            archive.days[key] = .init(date: key, activeTimeMs: nil, observations: observations)
        }
        return archive
    }

    /// Today / this month / all time, derived from the same archive so every widget agrees.
    public static func snapshot(from archive: DailyHistoryArchive, today: Date = Date()) -> UsageSnapshot {
        let todayKey = Fmt.dayKey(today)
        let monthPrefix = String(todayKey.prefix(7))
        func period(_ include: (String) -> Bool) -> UsagePeriod {
            var p = UsagePeriod()
            for (key, day) in archive.days where include(key) {
                for o in day.observations.values {
                    let cacheRead = Int(Double(o.tokens) * 0.93)
                    let cacheWrite = Int(Double(o.tokens) * 0.035)
                    let output = Int(Double(o.tokens) * 0.012)
                    let input = o.tokens - cacheRead - cacheWrite - output
                    let slice = UsagePeriod.Slice(tokens: o.tokens, costUsd: o.cost, messages: o.messages,
                                                  input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                    p.totalTokens += o.tokens
                    p.costUsd += o.cost
                    p.messages += o.messages
                    p.inputTokens += input
                    p.outputTokens += output
                    p.cacheReadTokens += cacheRead
                    p.cacheWriteTokens += cacheWrite
                    p.byModel[o.modelId, default: .init()].add(slice)
                    p.byClient[o.client, default: .init()].add(slice)
                    p.byPair[UsagePeriod.pairKey(client: o.client, model: o.modelId), default: .init()].add(slice)
                }
            }
            return p
        }
        return UsageSnapshot(today: period { $0 == todayKey }, month: period { $0.hasPrefix(monthPrefix) },
                             allTime: period { _ in true }, collectedAt: today, dayKey: todayKey)
    }

    public static func limits(now: Date = Date()) -> (claude: ProviderLimits, codex: ProviderLimits) {
        let claude = ProviderLimits(provider: .claude, windows: [
            LimitWindow(kind: .session, usedPercent: 38, resetsAt: now.addingTimeInterval(2.4 * 3600), windowMinutes: 300),
            LimitWindow(kind: .weekly, usedPercent: 57, resetsAt: now.addingTimeInterval(2.6 * 86400)),
            LimitWindow(kind: .fable, usedPercent: 21, resetsAt: now.addingTimeInterval(2.6 * 86400)),
        ], accountLabel: "Max 20x", updatedAt: now.addingTimeInterval(-40))
        let codex = ProviderLimits(provider: .codex, windows: [
            LimitWindow(kind: .session, usedPercent: 12, resetsAt: now.addingTimeInterval(3.1 * 3600), windowMinutes: 300),
            LimitWindow(kind: .weekly, usedPercent: 26, resetsAt: now.addingTimeInterval(4.2 * 86400)),
        ], accountLabel: "Pro", updatedAt: now.addingTimeInterval(-40))
        return (claude, codex)
    }

    /// Half-hour buckets for the Claude models over the last 90 days (weekday office hours plus some evenings).
    public static func intraday(from archive: DailyHistoryArchive, today: Date = Date()) -> IntradayScanner.Snapshot {
        var snap = IntradayScanner.Snapshot()
        var rng = Random(state: 99)
        let cal = Calendar.current
        let nowSlot = cal.component(.hour, from: today) * 2 + (cal.component(.minute, from: today) >= 30 ? 1 : 0)
        let todayKey = Fmt.dayKey(today)
        let profile: [Double] = (0..<48).map { slot in
            let h = Double(slot) / 2
            let morning = exp(-pow((h - 10.5) / 1.6, 2))
            let afternoon = 1.2 * exp(-pow((h - 15) / 2.0, 2))
            let evening = 0.45 * exp(-pow((h - 21.5) / 1.3, 2))
            return morning + afternoon + evening
        }
        for key in archive.days.keys.sorted().suffix(90) {
            guard let day = archive.days[key] else { continue }
            var byModel: [String: [Int]] = [:]
            for o in day.observations.values where o.client == "claude" {
                let lastSlot = key == todayKey ? nowSlot : 47
                let weights = profile.enumerated().map { i, w in i <= lastSlot ? w * (0.4 + rng.next() * 1.2) : 0 }
                let sum = max(1e-9, weights.reduce(0, +))
                byModel[o.modelId] = weights.map { Int(Double(o.tokens) * $0 / sum) }
            }
            snap.byModel[key] = byModel
        }
        return snap
    }
}
