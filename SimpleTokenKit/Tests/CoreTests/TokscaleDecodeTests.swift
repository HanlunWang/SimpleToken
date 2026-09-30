import Testing
import Foundation
@testable import Core

@Suite struct TokscaleDecodeTests {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    @Test func decodesRealTodayOutput() throws {
        let report = try TokscaleReport.decode(fixture("tokscale-today"))
        let entries = try #require(report.entries)
        #expect(!entries.isEmpty)
        let period = report.aggregate()
        // totalTokens = input+output+cacheRead+cacheWrite (without reasoning)
        let manual = entries.reduce(0) {
            $0 + ($1.input ?? 0) + ($1.output ?? 0) + ($1.cacheRead ?? 0) + ($1.cacheWrite ?? 0)
        }
        #expect(period.totalTokens == manual)
        // Client folding: every claude* row becomes claude
        #expect(period.byClient.keys.contains("claude"))
        // Cost comes from tokscale itself, not our own estimate
        #expect(period.costUsd > 0)
        #expect(!period.byModel.isEmpty)
    }

    @Test func reasoningIsExcludedFromTotals() throws {
        let json = """
        {"entries":[{"client":"claude","model":"m","input":10,"output":5,"cacheRead":100,"cacheWrite":0,"reasoning":2,"messageCount":1,"cost":0.5}]}
        """
        let period = try TokscaleReport.decode(Data(json.utf8)).aggregate()
        #expect(period.totalTokens == 115)   // 10+5+100, reasoning's 2 not added
    }

    @Test func emptyEntriesFallsBackToTopLevelTotals() throws {
        let json = """
        {"entries":[],"totalInput":7,"totalOutput":3,"totalCacheRead":90,"totalCacheWrite":0,"totalMessages":2,"totalCost":1.25}
        """
        let period = try TokscaleReport.decode(Data(json.utf8)).aggregate()
        #expect(period.totalTokens == 100)
        #expect(period.messages == 2)
        #expect(period.byModel.isEmpty)
    }

    @Test func decodesRealGraphOutput() throws {
        let graph = try TokscaleGraph.decode(fixture("tokscale-graph"))
        let days = try #require(graph.contributions)
        #expect(!days.isEmpty)
        let last = try #require(days.last)
        #expect(last.date?.count == 10)
        #expect(last.totals?.tokens ?? 0 > 0)
        // clients[].tokens is a breakdown dictionary; the folded value must be positive
        let entry = try #require(last.clients?.first)
        #expect(entry.collapsedTokens > 0)
    }

    @Test func extractJSONSkipsGarbagePrefix() throws {
        let data = Data("warning: blah\n{\"totalCost\": 1}".utf8)
        let report = try TokscaleReport.decode(TokscaleRunner.extractJSON(data))
        #expect(report.totalCost == 1)
    }
}
