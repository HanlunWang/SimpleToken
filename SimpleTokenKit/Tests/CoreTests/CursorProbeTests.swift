import Foundation
import Testing
@testable import Core

@Suite struct CursorProbeTests {
    @Test func parsesWeeklyWindowSpendAndMergedPlan() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let status: [String: Any] = ["usagePercent": 44.5, "nextResetTimestampUtc": "2026-10-19T00:00:06.766Z",
                                     "hasNonZeroIncludedLimit": true, "grokPlanLabel": "Premium"]
        let period: [String: Any] = ["spendLimitUsage": ["individualUsed": 250, "individualLimit": "1000"],
                                     "billingCycleEnd": "1794527129000"]
        let plan: [String: Any] = ["planInfo": ["planName": "Premium"], "isMerged": true]
        let limits = try CursorProbe.parse(status: status, period: period, plan: plan, now: now)
        #expect(limits.provider == .cursor)
        #expect(limits.accountLabel == "X Pass Premium")
        let weekly = try #require(limits.window(.weekly))
        #expect(weekly.usedPercent == 44.5)
        #expect(weekly.windowMinutes == 7 * 24 * 60)
        let expectedReset = try #require(ISO8601DateFormatter.fractional.date(from: "2026-10-19T00:00:06.766Z"))
        #expect(abs((weekly.resetsAt?.timeIntervalSince1970 ?? 0) - expectedReset.timeIntervalSince1970) < 0.01)
        let spend = try #require(limits.windows.first { $0.kind == .model })
        #expect(spend.usedPercent == 25)
        #expect(spend.resetsAt == Date(timeIntervalSince1970: 1_794_527_129))
    }

    @Test func skipsAbsentSpendLimitAndKeepsPlainPlanName() throws {
        let status: [String: Any] = ["usagePercent": "12", "nextResetTimestampUtc": ["seconds": 1_792_454_406]]
        let limits = try CursorProbe.parse(status: status, period: ["spendLimitUsage": ["individualUsed": 0, "individualLimit": 2_147_483_647]],
                                           plan: ["planInfo": ["planName": "Pro"], "isMerged": false])
        #expect(limits.windows.count == 1)
        #expect(limits.accountLabel == "Pro")
        #expect(limits.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_792_454_406))
    }

    @Test func failsWithoutAUsagePercent() {
        #expect(throws: LimitsError.self) { try CursorProbe.parse(status: ["grokPlanLabel": "Premium"], period: nil, plan: nil) }
    }

    @Test func readsTokscaleSessionsAndTokenSubjects() {
        let payload = Data(#"{"sub":"auth0|user_01ABC","exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        #expect(CursorProbe.userId(fromJWT: jwt) == "user_01ABC")
        #expect(CursorProbe.token(fromSession: "user_01ABC::\(jwt)") == CursorProbe.Token(userId: "user_01ABC", accessToken: jwt))
        #expect(CursorProbe.token(fromSession: "user_01ABC%3A%3A\(jwt)")?.userId == "user_01ABC")
        #expect(CursorProbe.token(fromSession: "no-separator") == nil)
        #expect(CursorProbe.Token(userId: "user_01ABC", accessToken: jwt).sessionCookie == "WorkosCursorSessionToken=user_01ABC%3A%3A\(jwt)")
    }

    @Test func grokBotIsItsOwnTool() {
        #expect(TokscaleReport.normalizeClient("cursor", model: "grok-bot-default") == "grokbot")
        #expect(TokscaleReport.normalizeClient("cursor", model: "claude-4-sonnet") == "cursor")
        #expect(TokscaleReport.normalizeClient("Claude Code", model: "grok-bot-cua") == "claude")
        #expect(TokscaleReport.normalizeClient(nil) == "unknown")
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
