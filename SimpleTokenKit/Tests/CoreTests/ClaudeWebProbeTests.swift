import Testing
import Foundation
@testable import Core

@Suite struct ClaudeWebProbeTests {
    @Test func cookieNormalization() throws {
        let a = try ClaudeWebProbe(cookie: "sessionKey=sk-ant-abc123")
        #expect(a.sessionKey == "sk-ant-abc123")
        let b = try ClaudeWebProbe(cookie: "  sk-ant-xyz  ")
        #expect(b.sessionKey == "sk-ant-xyz")
        #expect(throws: LimitsError.invalidCookie) {
            _ = try ClaudeWebProbe(cookie: "not-a-key")
        }
    }

    @Test func parsesUsageWindows() throws {
        let json = """
        {"five_hour":{"utilization":21,"resets_at":"2026-08-21T14:00:00Z"},
         "seven_day":{"utilization":52,"resets_at":"2026-08-25T01:00:00Z"},
         "limits":[
           {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},
            "usage":{"utilization":39,"resets_at":"2026-08-27T00:00:00Z"}},
           {"kind":"weekly_scoped","scope":{"model":{"display_name":"Other"}},
            "usage":{"utilization":10}}
         ]}
        """
        let limits = try ClaudeWebProbe.parseUsage(Data(json.utf8))
        #expect(limits.windows.count == 3)
        #expect(limits.window(.session)?.usedPercent == 21)
        #expect(limits.window(.session)?.remainingPercent == 79)
        #expect(limits.window(.weekly)?.usedPercent == 52)
        #expect(limits.window(.fable)?.usedPercent == 39)   // only display_name == Fable counts
        #expect(limits.window(.session)?.resetsAt != nil)
    }

    @Test func selectsChatCapableOrganization() throws {
        let json = """
        [{"uuid":"api-org","capabilities":["api"]},
         {"uuid":"chat-org","capabilities":["chat","api"]}]
        """
        let id = try ClaudeWebProbe.selectOrganization(from: Data(json.utf8))
        #expect(id == "chat-org")
    }

    @Test func fallsBackToFirstOrganization() throws {
        let json = """
        {"organizations":[{"uuid":"only-org","capabilities":["api"]}]}
        """
        let id = try ClaudeWebProbe.selectOrganization(from: Data(json.utf8))
        #expect(id == "only-org")
    }

    @Test func extractsRenewedSessionKeyFromMergedHeader() throws {
        // Multiple set-cookie headers joined by commas (as URLSession delivers them)
        let response = HTTPURLResponse(
            url: URL(string: "https://claude.ai/api/x")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "cf_x=1; Path=/, sessionKey=sk-ant-renewed-42; Path=/; HttpOnly; Secure"]
        )!
        #expect(ClaudeWebProbe.renewedSessionKey(from: response) == "sk-ant-renewed-42")
    }

    @Test func ignoresNonSkAntSessionValues() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://claude.ai/api/x")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "sessionKey=deleted; Path=/"]
        )!
        #expect(ClaudeWebProbe.renewedSessionKey(from: response) == nil)
    }
}
