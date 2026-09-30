import Testing
import Foundation
@testable import Core

@Suite struct PeriodDeltaTests {
    private func period(tokens: Int, cost: Double, models: [String: Int] = [:]) -> UsagePeriod {
        var p = UsagePeriod()
        p.totalTokens = tokens
        p.costUsd = cost
        for (m, t) in models { p.byModel[m] = .init(tokens: t, costUsd: 0) }
        return p
    }

    @Test func appendOnlyDeltaIsIdentity() {
        // Append-only logs: base + (fresh − anchor) always equals the true wide-window value
        let anchorToday = period(tokens: 30, cost: 3)
        let baseMonth = period(tokens: 100, cost: 10)
        let freshToday = period(tokens: 45, cost: 4.5)
        let r = UsagePeriod.delta(base: baseMonth, fresh: freshToday, anchor: anchorToday)
        #expect(r.totalTokens == 115)
        #expect(abs(r.costUsd - 11.5) < 0.0001)
    }

    @Test func negativeClampProtectsWiderWindows() {
        // Logs cleaned up: fresh < anchor; the wide window undercounts rather than go negative
        let anchorToday = period(tokens: 30, cost: 3)
        let baseMonth = period(tokens: 20, cost: 2)   // extreme: base smaller than the difference
        let freshToday = period(tokens: 0, cost: 0)
        let r = UsagePeriod.delta(base: baseMonth, fresh: freshToday, anchor: anchorToday)
        #expect(r.totalTokens == 0)
        #expect(r.costUsd == 0)
    }

    @Test func sliceUnionMergesAllKeys() {
        let anchorToday = period(tokens: 10, cost: 0, models: ["opus": 10])
        let baseMonth = period(tokens: 50, cost: 0, models: ["opus": 40, "sonnet": 10])
        let freshToday = period(tokens: 25, cost: 0, models: ["opus": 15, "fable": 10])
        let r = UsagePeriod.delta(base: baseMonth, fresh: freshToday, anchor: anchorToday)
        #expect(r.byModel["opus"]?.tokens == 45)    // 40 + 15 − 10
        #expect(r.byModel["sonnet"]?.tokens == 10)  // only in base
        #expect(r.byModel["fable"]?.tokens == 10)   // new today
    }

    @Test func zeroSlicesArePruned() {
        let anchorToday = period(tokens: 10, cost: 0, models: ["opus": 10])
        let baseMonth = period(tokens: 10, cost: 0, models: ["opus": 10])
        let freshToday = period(tokens: 0, cost: 0)
        let r = UsagePeriod.delta(base: baseMonth, fresh: freshToday, anchor: anchorToday)
        #expect(r.byModel["opus"] == nil)
    }
}
