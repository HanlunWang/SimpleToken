import Testing
import Foundation
@testable import Core

@Suite struct LimitForecastTests {
    let calendar = Calendar.current

    /// A day with the same tokens in every half-hour from 9:00 to 17:00
    func workday(_ tokens: Int, model: String = "claude-opus-5") -> [String: [Int]] {
        [model: (0..<48).map { (18..<34).contains($0) ? tokens : 0 }]
    }

    /// September 2026: no daylight-saving change inside the windows below
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func snapshot(days: ClosedRange<Int>, today: [String: [Int]]) -> IntradayScanner.Snapshot {
        var s = IntradayScanner.Snapshot()
        for d in days { s.byModel[Fmt.dayKey(date(d, 12))] = workday(100) }
        s.byModel[Fmt.dayKey(date(20, 12))] = today
        return s
    }

    @Test func projectsFromUsualHoursEarlyInTheWindow() {
        // Weekly window opened Sunday 10:00; by 12:00 four busy half-hours (400 tokens) spent 2%
        let now = date(20, 12)
        var today = workday(0)
        for i in 20..<24 { today["claude-opus-5"]![i] = 100 }
        let w = LimitWindow(kind: .weekly, usedPercent: 2, resetsAt: date(20, 10).addingTimeInterval(7 * 86400))
        let s = snapshot(days: 6...19, today: today)
        let projected = LimitForecast.projectedPercent(w, snapshot: s, now: now, calendar: calendar)
        // Still to come: 10 half-hours today (12:00–17:00) + 16 a day for six days + 2 on the last morning
        // (9:00–10:00), 108 half-hours × 100 tokens at 2% per 400 tokens
        #expect(projected.map { abs($0 - (2 + 2.0 / 400 * 108 * 100)) < 0.01 } == true)
        // A straight line from 1% of the window would say nothing yet
        #expect(w.projectedPercent(now: now) == nil)
    }

    @Test func countsOnlyTheWindowsModels() {
        let now = date(20, 12)
        var today = workday(0)
        today["claude-opus-5"]![22] = 400
        let fable = LimitWindow(kind: .fable, usedPercent: 1, resetsAt: date(20, 10).addingTimeInterval(7 * 86400))
        let s = snapshot(days: 6...19, today: today)
        // No Fable tokens in the window: no forecast
        #expect(LimitForecast.projectedPercent(fable, snapshot: s, models: LimitsStore.counts(fable), now: now, calendar: calendar) == nil)
    }

    @Test func idleDaysLowerTheProfile() {
        // Only every other day had work: the average half-hour is half as busy
        let now = date(20, 12)
        var today = workday(0)
        for i in 20..<24 { today["claude-opus-5"]![i] = 100 }
        var s = IntradayScanner.Snapshot()
        for d in stride(from: 6, through: 19, by: 2) { s.byModel[Fmt.dayKey(date(d, 12))] = workday(100) }
        s.byModel[Fmt.dayKey(date(20, 12))] = today
        let w = LimitWindow(kind: .weekly, usedPercent: 2, resetsAt: date(20, 10).addingTimeInterval(7 * 86400))
        let projected = LimitForecast.projectedPercent(w, snapshot: s, now: now, calendar: calendar)
        #expect(projected.map { abs($0 - (2 + 2.0 / 400 * 108 * 50)) < 0.01 } == true)
    }

    @Test func noForecastWithoutUsageOrHistory() {
        let now = date(20, 12)
        let w = LimitWindow(kind: .weekly, usedPercent: 0, resetsAt: date(20, 10).addingTimeInterval(7 * 86400))
        #expect(LimitForecast.projectedPercent(w, snapshot: snapshot(days: 6...19, today: workday(100)), now: now) == nil)
        let used = LimitWindow(kind: .weekly, usedPercent: 3, resetsAt: date(20, 10).addingTimeInterval(7 * 86400))
        #expect(LimitForecast.projectedPercent(used, snapshot: IntradayScanner.Snapshot(), now: now) == nil)
    }
}
