import Foundation

/// tokscale --json output (shape observed on 4.9.0; decoding is lenient: unknown fields ignored, missing ones zero).
public struct TokscaleReport: Decodable, Sendable {
    public var entries: [Entry]?
    public var totalInput: Int?
    public var totalOutput: Int?
    public var totalCacheRead: Int?
    public var totalCacheWrite: Int?
    public var totalMessages: Int?
    public var totalCost: Double?

    public struct Entry: Decodable, Sendable {
        public var client: String?
        public var sessionId: String?
        public var model: String?
        public var provider: String?
        public var input: Int?
        public var output: Int?
        public var cacheRead: Int?
        public var cacheWrite: Int?
        public var reasoning: Int?
        public var messageCount: Int?
        public var cost: Double?

        /// Row token total = input+output+cacheRead+cacheWrite.
        /// Never add reasoning — tokscale already folds it into output, so adding it double-counts.
        public var totalTokens: Int {
            (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
        }
    }

    /// Aggregates into a period snapshot. With entries, row by row (giving the model / tool split);
    /// empty output falls back to the top-level totals (no split).
    public func aggregate() -> UsagePeriod {
        var p = UsagePeriod()
        guard let entries, !entries.isEmpty else {
            p.inputTokens = totalInput ?? 0
            p.outputTokens = totalOutput ?? 0
            p.cacheReadTokens = totalCacheRead ?? 0
            p.cacheWriteTokens = totalCacheWrite ?? 0
            p.totalTokens = p.inputTokens + p.outputTokens + p.cacheReadTokens + p.cacheWriteTokens
            p.messages = totalMessages ?? 0
            p.costUsd = totalCost ?? 0
            return p
        }
        for e in entries {
            let tokens = e.totalTokens
            let cost = e.cost ?? 0
            p.totalTokens += tokens
            p.costUsd += cost
            p.messages += e.messageCount ?? 0
            p.inputTokens += e.input ?? 0
            p.outputTokens += e.output ?? 0
            p.cacheReadTokens += e.cacheRead ?? 0
            p.cacheWriteTokens += e.cacheWrite ?? 0
            let client = Self.normalizeClient(e.client)
            let slice = UsagePeriod.Slice(tokens: tokens, costUsd: cost, messages: e.messageCount ?? 0,
                                          input: e.input ?? 0, output: e.output ?? 0,
                                          cacheRead: e.cacheRead ?? 0, cacheWrite: e.cacheWrite ?? 0)
            p.byClient[client, default: .init()].add(slice)
            let model = (e.model?.isEmpty == false) ? e.model! : "unknown"
            if e.model?.isEmpty == false {
                p.byModel[model, default: .init()].add(slice)
            }
            p.byPair[UsagePeriod.pairKey(client: client, model: model), default: .init()].add(slice)
        }
        return p
    }

    /// Client name folding (port of normalizeClientName's claude branch: anything containing "claude" is claude)
    public static func normalizeClient(_ raw: String?) -> String {
        let name = (raw ?? "").lowercased()
        if name.isEmpty { return "unknown" }
        if name.contains("claude") { return "claude" }
        return name
    }

    public static func decode(_ data: Data) throws -> TokscaleReport {
        try JSONDecoder().decode(TokscaleReport.self, from: data)
    }
}

/// tokscale graph output (source for history / heat maps)
public struct TokscaleGraph: Decodable, Sendable {
    public var contributions: [Day]?

    public struct Day: Decodable, Sendable {
        public var date: String?
        public var totals: Totals?
        public var activeTimeMs: Double?
        public var clients: [ClientEntry]?
    }
    public struct Totals: Decodable, Sendable {
        public var tokens: Int?
        public var cost: Double?
        public var messages: Int?
    }
    public struct ClientEntry: Decodable, Sendable {
        public var client: String?
        public var modelId: String?
        public var providerId: String?
        public var tokens: TokenBreakdown?
        public var cost: Double?
        public var messages: Int?

        /// Folded total (matches the old sumTokens): input+output+cacheRead+cacheWrite, without reasoning
        public var collapsedTokens: Int {
            guard let t = tokens else { return 0 }
            return (t.input ?? 0) + (t.output ?? 0) + (t.cacheRead ?? 0) + (t.cacheWrite ?? 0)
        }
        public var reasoningTokens: Int { tokens?.reasoning ?? 0 }
    }

    public struct TokenBreakdown: Decodable, Sendable {
        public var input: Int?
        public var output: Int?
        public var cacheRead: Int?
        public var cacheWrite: Int?
        public var reasoning: Int?
    }

    public static func decode(_ data: Data) throws -> TokscaleGraph {
        try JSONDecoder().decode(TokscaleGraph.self, from: data)
    }
}
