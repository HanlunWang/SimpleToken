import Testing
import Foundation
@testable import Core

@Suite struct AnalyticsTests {
    private func day(_ date: String, _ tokens: Int, cost: Double = 0, model: String = "m", client: String = "claude") -> DailyHistoryArchive.DaySummary {
        .init(date: date, tokens: tokens, cost: cost, messages: tokens / 100,
              byModel: [model: tokens], costByModel: [model: cost], byClient: [client: tokens])
    }

    @Test func rangeStarts() {
        #expect(RangeAnalytics.startDay(for: .day, todayKey: "2026-09-28", firstKey: "2025-05-05") == "2026-09-28")
        #expect(RangeAnalytics.startDay(for: .week, todayKey: "2026-09-28", firstKey: "2025-05-05") == "2026-09-22")
        #expect(RangeAnalytics.startDay(for: .month, todayKey: "2026-09-28", firstKey: "2025-05-05") == "2026-08-30")
        #expect(RangeAnalytics.startDay(for: .ytd, todayKey: "2026-09-28", firstKey: "2025-05-05") == "2026-01-01")
        #expect(RangeAnalytics.startDay(for: .all, todayKey: "2026-09-28", firstKey: "2025-05-05") == "2025-05-05")
    }

    @Test func weekReportFillsGapsAndComparesPreviousWeek() {
        let history = [day("2026-09-20", 50), day("2026-09-22", 100), day("2026-09-24", 300), day("2026-09-28", 10)]
        let report = RangeAnalytics.report(range: .week, metric: .tokens, history: history, liveToday: nil, todayKey: "2026-09-28")
        #expect(report.days.count == 7)                       // 9/22…9/28, missing days filled with zero
        #expect(report.total == 410)
        #expect(report.previousTotal == 50)                   // 9/15…9/21
        #expect(report.current.last?.position == 1)
        #expect(report.current.map(\.cumulative) == [100, 100, 400, 400, 400, 400, 410])
        #expect(report.stats.activeDays == 3)
        #expect(report.stats.peak?.date == "2026-09-24")
        #expect(report.changePercent == 720)
    }

    @Test func liveTodayOverridesArchive() {
        let history = [day("2026-09-28", 10)]
        let live = day("2026-09-28", 999)
        let report = RangeAnalytics.report(range: .day, metric: .tokens, history: history, liveToday: live, todayKey: "2026-09-28")
        #expect(report.total == 999)
    }

    @Test func longRangesBucketWeekly() {
        let report = RangeAnalytics.report(range: .year, metric: .tokens, history: [day("2026-09-28", 1)], liveToday: nil, todayKey: "2026-09-28")
        #expect(report.weeklyBuckets)
        #expect(report.buckets.count == 53)                   // 365 days → 52 full weeks + 1 day
        let short = RangeAnalytics.report(range: .month, metric: .tokens, history: [], liveToday: nil, todayKey: "2026-09-28")
        #expect(!short.weeklyBuckets && short.buckets.count == 30)
    }

    @Test func streakCountsBackFromToday() {
        let history = [day("2026-09-25", 5), day("2026-09-26", 5), day("2026-09-27", 5), day("2026-09-28", 5), day("2026-09-23", 5)]
        let report = RangeAnalytics.report(range: .month, metric: .tokens, history: history, liveToday: nil, todayKey: "2026-09-28")
        #expect(report.stats.streak == 4)
    }

    @Test func ytdComparesSameSpanLastYear() {
        let history = [day("2025-03-01", 40), day("2025-10-01", 999), day("2026-02-01", 60)]
        let report = RangeAnalytics.report(range: .ytd, metric: .tokens, history: history, liveToday: nil, todayKey: "2026-09-28")
        #expect(report.previousTotal == 40)                   // 2025-01-01…2025-09-28, October excluded
        #expect(report.total == 60)
    }

    @Test func monthCostProjectsToMonthEnd() {
        let history = [day("2026-08-15", 1, cost: 70), day("2026-09-01", 1, cost: 10), day("2026-09-02", 1, cost: 20)]
        let m = RangeAnalytics.monthCost(history: history, liveToday: nil, todayKey: "2026-09-02")
        #expect(m.days.last?.cumulative == 30)
        #expect(m.daysInMonth == 30)
        #expect(abs(m.projected - 450) < 0.001)               // daily average 15 × 30
        #expect(m.lastMonthTotal == 70)
    }

    @Test func absorbIsIdempotentAndLargerWins() {
        let key = DailyHistoryArchive.observationKey(client: "claude", modelId: "m")
        var mine = DailyHistoryArchive()
        mine.days["2026-01-01"] = .init(date: "2026-01-01", activeTimeMs: nil,
                                         observations: [key: .init(client: "claude", modelId: "m", providerId: nil, tokens: 100, cost: 1, messages: 1, reasoningTokens: nil)])
        var legacy = DailyHistoryArchive()
        legacy.days["2026-01-01"] = .init(date: "2026-01-01", activeTimeMs: 5,
                                           observations: [key: .init(client: "claude", modelId: "m", providerId: nil, tokens: 80, cost: 9, messages: 1, reasoningTokens: nil)])
        legacy.days["2025-06-01"] = .init(date: "2025-06-01", activeTimeMs: nil,
                                           observations: [key: .init(client: "claude", modelId: "m", providerId: nil, tokens: 7, cost: 0, messages: 1, reasoningTokens: nil)])
        let firstChanged = mine.absorb(legacy, todayKey: "2026-09-28")
        #expect(firstChanged)
        #expect(mine.days["2026-01-01"]?.observations[key]?.tokens == 100)   // a smaller one does not overwrite
        #expect(mine.days["2026-01-01"]?.activeTimeMs == 5)
        #expect(mine.days["2025-06-01"] != nil)                              // old history is filled in
        let secondChanged = mine.absorb(legacy, todayKey: "2026-09-28")
        #expect(!secondChanged)                                              // no change the second time
    }

    @Test func limitProjection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = LimitWindow(kind: .session, usedPercent: 20, resetsAt: now.addingTimeInterval(2.5 * 3600))
        #expect(abs((w.elapsedFraction(now: now) ?? 0) - 0.5) < 1e-9)
        #expect(abs((w.projectedPercent(now: now) ?? 0) - 40) < 1e-9)
        let fresh = LimitWindow(kind: .weekly, usedPercent: 1, resetsAt: now.addingTimeInterval(7 * 86400 - 3600))
        #expect(fresh.projectedPercent(now: now) == nil)                     // no projection early in the window
    }
}

@Suite struct CodexProbeTests {
    @Test func parsesRateLimitsAndAdditionalBuckets() throws {
        // Structure taken from a real codex-cli 0.153.x app-server response on this machine
        let json = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1789226514},
          "secondary":null,"planType":"prolite"},
         "rateLimitsByLimitId":{
           "codex":{"limitId":"codex","primary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1789226514}},
           "codex_bengalfox":{"limitName":"GPT-5.3-Codex-Spark",
             "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1788666028},
             "secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1789252828}}}}
        """
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let limits = try CodexProbe.parse(rateLimits: obj, account: ["account": ["planType": "prolite"]])
        #expect(limits.provider == .codex)
        #expect(limits.accountLabel == "Pro 5x")
        #expect(limits.windows.first?.kind == .weekly)
        #expect(limits.windows.first?.usedPercent == 4)
        #expect(limits.windows.filter { $0.kind == .model }.count == 2)
        #expect(limits.windows.contains { $0.title == "GPT-5.3-Codex-Spark · Session" })
    }

    @Test func emptyPayloadIsNotConfigured() {
        #expect(throws: LimitsError.notConfigured) {
            _ = try CodexProbe.parse(rateLimits: [:], account: nil)
        }
    }
}

@Suite struct IntradayScannerTests {
    @Test func dedupesStreamingLinesAndDefersPartialLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simpletoken-intraday-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let stamp = ISO8601DateFormatter().string(from: Date())
        func line(_ id: String, _ tokens: Int) -> String {
            #"{"timestamp":"\#(stamp)","requestId":"r-\#(id)","message":{"id":"\#(id)","usage":{"input_tokens":\#(tokens),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        }
        // a appears twice (streaming duplicate); b's line is only half written
        try (line("a", 100) + "\n" + line("a", 100) + "\n" + #"{"type":"user","message":{"content":"x"}}"# + "\n" + String(line("b", 7).prefix(40)))
            .write(to: file, atomically: true, encoding: .utf8)
        let scanner = IntradayScanner(root: dir)
        let first = await scanner.scan()
        #expect(first.buckets(for: Fmt.dayKey()).reduce(0, +) == 100)
        // Finish b's line: only the new part is read
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(line("b", 7).dropFirst(40)) + "\n").utf8))
        try handle.close()
        let second = await scanner.scan()
        #expect(second.buckets(for: Fmt.dayKey()).reduce(0, +) == 107)
    }
}

@Suite struct IntradayModelTests {
    @Test func bucketsByModelAndExcludes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simpletoken-intraday-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        func line(_ id: String, _ model: String, _ tokens: Int) -> String {
            #"{"parentUuid":null,"message":{"model":"\#(model)","id":"msg_\#(id)","content":[{"type":"text","text":"he said \"model\":\"fake\""}],"usage":{"input_tokens":\#(tokens),"output_tokens":0}},"requestId":"r-\#(id)","timestamp":"\#(stamp)"}"#
        }
        try [line("a", "claude-opus-5-5", 100), line("b", "claude-fable-5", 30), line("c", "claude-opus-5-5", 5)]
            .joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let snap = await IntradayScanner(root: dir).scan()
        let today = Fmt.dayKey()
        #expect(snap.modelBuckets(for: today)["claude-opus-5-5"]?.reduce(0, +) == 105)
        #expect(snap.modelBuckets(for: today)["claude-fable-5"]?.reduce(0, +) == 30)
        #expect(snap.buckets(for: today, excluding: ["claude-fable-5"]).reduce(0, +) == 105)
        let card = snap.punchcard(days: 7, todayKey: today)
        #expect(card.grid.flatMap { $0 }.reduce(0, +) == 135)
        #expect(card.dayCount.reduce(0, +) == 7)
    }
}

@Suite struct UsageFilterTests {
    private func period() -> UsagePeriod {
        let json = """
        {"entries":[
          {"client":"claude","model":"claude-opus-5-5","input":10,"output":5,"cacheRead":100,"cacheWrite":20,"messageCount":2,"cost":1.5},
          {"client":"claude","model":"claude-fable-5","input":4,"output":1,"cacheRead":0,"cacheWrite":0,"messageCount":1,"cost":0.5},
          {"client":"codex","model":"gpt-5.3-codex","input":50,"output":10,"cacheRead":40,"cacheWrite":0,"messageCount":3,"cost":2}
        ]}
        """
        return try! TokscaleReport.decode(Data(json.utf8)).aggregate()
    }

    @Test func excludesClientsAndModelsExactly() {
        let p = period()
        #expect(p.totalTokens == 240)
        let noCodex = UsageFilter(excludedClients: ["codex"]).apply(p)
        #expect(noCodex.totalTokens == 140)
        #expect(noCodex.byModel["gpt-5.3-codex"] == nil)
        #expect(noCodex.cacheReadTokens == 100)
        #expect(abs(noCodex.costUsd - 2.0) < 1e-9)
        let noFable = UsageFilter(excludedModels: ["claude-fable-5"]).apply(p)
        #expect(noFable.totalTokens == 235)
        #expect(noFable.byClient["claude"]?.tokens == 135)
        #expect(noFable.messages == 5)
    }

    @Test func emptyFilterIsIdentity() {
        let p = period()
        #expect(UsageFilter().apply(p) == p)
    }

    @Test func archiveSummariesHonourFilter() {
        var archive = DailyHistoryArchive()
        let today = Fmt.dayKey()
        archive.days[today] = .init(date: today, activeTimeMs: nil, observations: [
            DailyHistoryArchive.observationKey(client: "claude", modelId: "opus"): .init(client: "claude", modelId: "opus", providerId: nil, tokens: 100, cost: 1, messages: 1, reasoningTokens: nil),
            DailyHistoryArchive.observationKey(client: "codex", modelId: "gpt"): .init(client: "codex", modelId: "gpt", providerId: nil, tokens: 50, cost: 2, messages: 1, reasoningTokens: nil),
        ])
        let all = archive.dailySummaries(todayKey: today)
        #expect(all.first?.tokens == 150)
        let filtered = archive.dailySummaries(todayKey: today, filter: UsageFilter(excludedClients: ["codex"]))
        #expect(filtered.first?.tokens == 100)
        #expect(filtered.first?.byModel["gpt"] == nil)
        let catalog = archive.catalog()
        #expect(catalog.models.map(\.key) == ["opus", "gpt"])
        #expect(catalog.clients.first?.key == "claude")
    }
}

@Suite struct TimestampParserTests {
    private func parse(_ s: String) -> Int? {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBytes { IntradayScanner.parseTimestamp($0, 0..<bytes.count) }
    }

    @Test func matchesISO8601Formatter() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for s in ["2026-09-29T14:03:12.345Z", "2025-01-01T00:00:00Z", "2024-02-29T23:59:59.9Z",
                  "2026-03-08T07:30:00+08:00", "2026-11-01T01:15:00-04:00", "1999-12-31T23:59:59.000Z"] {
            let expected = (fractional.date(from: s) ?? plain.date(from: s)).map { Int($0.timeIntervalSince1970.rounded(.down)) }
            #expect(parse(s) == expected, "\(s)")
        }
    }

    @Test func rejectsGarbage() {
        #expect(parse("not-a-timestamp-at-all") == nil)
        #expect(parse("2026-13-01T00:00:00Z") == nil)
    }

    @Test func civilRoundTrip() {
        for day in stride(from: -800_000, through: 800_000, by: 997) {
            let (y, m, d) = IntradayScanner.civilFromDays(day)
            #expect(IntradayScanner.daysFromCivil(y, m, d) == day)
        }
        #expect(IntradayScanner.daysFromCivil(1970, 1, 1) == 0)
        #expect(IntradayScanner.daysFromCivil(2000, 3, 1) == 11017)
    }
}
