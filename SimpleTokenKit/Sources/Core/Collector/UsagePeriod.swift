import Foundation

/// Usage snapshot of one period (today / this month / all time).
public struct UsagePeriod: Codable, Equatable, Sendable {
    public var totalTokens: Int = 0
    public var costUsd: Double = 0
    public var messages: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    public var byModel: [String: Slice] = [:]
    public var byClient: [String: Slice] = [:]
    /// Tool × model (key = UsagePeriod.pairKey): for exact recomputation when models / tools are excluded
    public var byPair: [String: Slice] = [:]

    public struct Slice: Codable, Equatable, Sendable {
        public var tokens: Int = 0
        public var costUsd: Double = 0
        public var messages: Int = 0
        public var input: Int = 0
        public var output: Int = 0
        public var cacheRead: Int = 0
        public var cacheWrite: Int = 0

        public init(tokens: Int = 0, costUsd: Double = 0, messages: Int = 0,
                    input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
            self.tokens = tokens
            self.costUsd = costUsd
            self.messages = messages
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }

        mutating func add(tokens: Int, cost: Double) {
            self.tokens += tokens
            self.costUsd += cost
        }

        public mutating func add(_ o: Slice) {
            tokens += o.tokens; costUsd += o.costUsd; messages += o.messages
            input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
        }

        // Slices in old anchor files only have tokens / costUsd: missing fields count as zero
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
            messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
            input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
            output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
            cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
            cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        }
    }

    public init() {}

    public static func pairKey(client: String, model: String) -> String { client + "\u{1F}" + model }
    public static func splitPair(_ key: String) -> (client: String, model: String) {
        let parts = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        byModel = try c.decodeIfPresent([String: Slice].self, forKey: .byModel) ?? [:]
        byClient = try c.decodeIfPresent([String: Slice].self, forKey: .byClient) ?? [:]
        byPair = try c.decodeIfPresent([String: Slice].self, forKey: .byPair) ?? [:]
    }

    // MARK: - Anchor delta (port of applyPeriodDelta)
    //
    // A watch tick runs only the --today scan; month / allTime are derived arithmetically:
    //   result = max(0, base + fresh − anchor)
    // For append-only logs this is an identity (fresh − anchor is exactly the increase), not an estimate.
    // Clamped at zero: when logs are cleaned up fresh < anchor, and the wide windows undercount rather than go negative.

    public static func delta(base: UsagePeriod, fresh: UsagePeriod, anchor: UsagePeriod) -> UsagePeriod {
        var r = UsagePeriod()
        r.totalTokens = clampInt(base.totalTokens + fresh.totalTokens - anchor.totalTokens)
        r.costUsd = clampDouble(base.costUsd + fresh.costUsd - anchor.costUsd)
        r.messages = clampInt(base.messages + fresh.messages - anchor.messages)
        r.inputTokens = clampInt(base.inputTokens + fresh.inputTokens - anchor.inputTokens)
        r.outputTokens = clampInt(base.outputTokens + fresh.outputTokens - anchor.outputTokens)
        r.cacheReadTokens = clampInt(base.cacheReadTokens + fresh.cacheReadTokens - anchor.cacheReadTokens)
        r.cacheWriteTokens = clampInt(base.cacheWriteTokens + fresh.cacheWriteTokens - anchor.cacheWriteTokens)
        r.byModel = deltaSlices(base: base.byModel, fresh: fresh.byModel, anchor: anchor.byModel)
        r.byClient = deltaSlices(base: base.byClient, fresh: fresh.byClient, anchor: anchor.byClient)
        r.byPair = deltaSlices(base: base.byPair, fresh: fresh.byPair, anchor: anchor.byPair)
        return r
    }

    private static func deltaSlices(
        base: [String: Slice], fresh: [String: Slice], anchor: [String: Slice]
    ) -> [String: Slice] {
        var keys = Set(base.keys)
        keys.formUnion(fresh.keys)
        keys.formUnion(anchor.keys)
        var out: [String: Slice] = [:]
        for k in keys {
            let b = base[k] ?? Slice(), f = fresh[k] ?? Slice(), a = anchor[k] ?? Slice()
            let s = Slice(
                tokens: clampInt(b.tokens + f.tokens - a.tokens),
                costUsd: clampDouble(b.costUsd + f.costUsd - a.costUsd),
                messages: clampInt(b.messages + f.messages - a.messages),
                input: clampInt(b.input + f.input - a.input),
                output: clampInt(b.output + f.output - a.output),
                cacheRead: clampInt(b.cacheRead + f.cacheRead - a.cacheRead),
                cacheWrite: clampInt(b.cacheWrite + f.cacheWrite - a.cacheWrite)
            )
            if s.tokens > 0 || s.costUsd > 0 { out[k] = s }
        }
        return out
    }

    private static func clampInt(_ v: Int) -> Int { max(0, v) }
    private static func clampDouble(_ v: Double) -> Double { max(0, v) }
}

/// All three periods — the full snapshot of one collection (single clock: collectedAt is captured before scanning).
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var today: UsagePeriod
    public var month: UsagePeriod
    public var allTime: UsagePeriod
    public var collectedAt: Date
    public var dayKey: String

    public init(today: UsagePeriod, month: UsagePeriod, allTime: UsagePeriod, collectedAt: Date, dayKey: String) {
        self.today = today
        self.month = month
        self.allTime = allTime
        self.collectedAt = collectedAt
        self.dayKey = dayKey
    }
}
