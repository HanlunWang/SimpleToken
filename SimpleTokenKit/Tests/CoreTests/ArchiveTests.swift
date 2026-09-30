import Testing
import Foundation
@testable import Core

@Suite struct ArchiveTests {
    private func graphDay(date: String, activeMs: Double?, entries: [(tokens: Int, cost: Double, messages: Int)]) -> TokscaleGraph {
        let json = """
        {"contributions":[{"date":"\(date)",
          \(activeMs.map { "\"activeTimeMs\": \($0)," } ?? "")
          "clients":[\(entries.map { e in
            """
            {"client":"claude","modelId":"m","providerId":"anthropic",
             "tokens":{"input":\(e.tokens),"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
             "cost":\(e.cost),"messages":\(e.messages)}
            """
          }.joined(separator: ","))]}]}
        """
        return try! TokscaleGraph.decode(Data(json.utf8))
    }

    private var key: String { DailyHistoryArchive.observationKey(client: "claude", modelId: "m") }

    @Test func observationKeyMatchesLegacyFormat() {
        // Must match the old JSON.stringify([client, modelId]) byte for byte, or merges diverge
        #expect(DailyHistoryArchive.observationKey(client: "claude", modelId: "claude-opus-5")
                == "[\"claude\",\"claude-opus-5\"]")
    }

    @Test func decodesLegacyArchiveShape() throws {
        let json = """
        {"version":1,"days":{"2026-08-21":{"date":"2026-08-21","activeTimeMs":33757056,
        "observations":{"[\\"claude\\",\\"claude-opus-5\\"]":
        {"client":"claude","modelId":"claude-opus-5","providerId":"anthropic",
        "tokens":17753838,"cost":15.9580485,"messages":31}}}}}
        """
        let archive = try #require(try? JSONDecoder().decode(DailyHistoryArchive.self, from: Data(json.utf8)))
        let daily = archive.dailySummaries(todayKey: "2026-08-21")
        #expect(daily.count == 1)
        #expect(daily[0].tokens == 17753838)
    }

    @Test func collapsedTokensExcludeReasoning() throws {
        let json = """
        {"contributions":[{"date":"2026-08-20","clients":[
          {"client":"claude","modelId":"m",
           "tokens":{"input":10,"output":5,"cacheRead":100,"cacheWrite":0,"reasoning":7},
           "cost":1,"messages":1}]}]}
        """
        let graph = try TokscaleGraph.decode(Data(json.utf8))
        let entry = graph.contributions![0].clients![0]
        #expect(entry.collapsedTokens == 115)
        #expect(entry.reasoningTokens == 7)
    }

    @Test func duplicatesWithinOneGraphAreSummed() {
        var archive = DailyHistoryArchive()
        let graph = graphDay(date: "2026-08-20", activeMs: nil,
                             entries: [(300, 1.0, 3), (200, 0.5, 2)])
        archive.merge(graph: graph, todayKey: "2026-08-21")
        let obs = archive.days["2026-08-20"]!.observations[key]!
        #expect(obs.tokens == 500)
        #expect(obs.messages == 5)
        #expect(abs(obs.cost - 1.5) < 0.0001)
    }

    @Test func crossMergeReplacesLargerNeverSums() {
        var archive = DailyHistoryArchive()
        archive.merge(graph: graphDay(date: "2026-08-20", activeMs: 100, entries: [(500, 1.0, 5)]),
                      todayKey: "2026-08-21")
        // A smaller observation neither rolls back nor adds up
        archive.merge(graph: graphDay(date: "2026-08-20", activeMs: 50, entries: [(300, 0.5, 3)]),
                      todayKey: "2026-08-21")
        let obs = archive.days["2026-08-20"]!.observations[key]!
        #expect(obs.tokens == 500)
        #expect(abs(obs.cost - 1.0) < 0.0001)
        #expect(archive.days["2026-08-20"]?.activeTimeMs == 100)
        // Same tokens/messages: replace whole to pick up corrected pricing
        archive.merge(graph: graphDay(date: "2026-08-20", activeMs: nil, entries: [(500, 2.0, 5)]),
                      todayKey: "2026-08-21")
        #expect(abs(archive.days["2026-08-20"]!.observations[key]!.cost - 2.0) < 0.0001)
    }

    @Test func futureDaysArePruned() {
        var archive = DailyHistoryArchive()
        archive.merge(graph: graphDay(date: "2026-08-20", activeMs: nil, entries: [(1, 0, 0)]),
                      todayKey: "2026-08-21")
        archive.merge(graph: graphDay(date: "2026-09-01", activeMs: nil, entries: [(1, 0, 0)]),
                      todayKey: "2026-08-21")
        #expect(archive.days["2026-08-20"] != nil)
        #expect(archive.days["2026-09-01"] == nil)
    }
}
