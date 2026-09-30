import Foundation

/// Usage filter: models / tools switched off in settings enter no statistic (totals, charts and distributions all exclude them).
public struct UsageFilter: Equatable, Sendable {
    public var excludedModels: Set<String>
    public var excludedClients: Set<String>

    public init(excludedModels: Set<String> = [], excludedClients: Set<String> = []) {
        self.excludedModels = excludedModels
        self.excludedClients = excludedClients
    }

    public var isEmpty: Bool { excludedModels.isEmpty && excludedClients.isEmpty }

    public func includes(client: String, model: String) -> Bool {
        !excludedClients.contains(client) && !excludedModels.contains(model)
    }

    /// Recomputes a period snapshot under the filter. Exact when the tool × model detail exists; old anchors
    /// without it (the seconds before the first full scan after launch) fall back to subtracting per tool and per model.
    public func apply(_ period: UsagePeriod) -> UsagePeriod {
        guard !isEmpty else { return period }
        guard !period.byPair.isEmpty else { return approximate(period) }
        var out = UsagePeriod()
        for (key, slice) in period.byPair {
            let (client, model) = UsagePeriod.splitPair(key)
            guard includes(client: client, model: model) else { continue }
            out.byPair[key] = slice
            out.byClient[client, default: .init()].add(slice)
            if model != "unknown" { out.byModel[model, default: .init()].add(slice) }
            out.totalTokens += slice.tokens
            out.costUsd += slice.costUsd
            out.messages += slice.messages
            out.inputTokens += slice.input
            out.outputTokens += slice.output
            out.cacheReadTokens += slice.cacheRead
            out.cacheWriteTokens += slice.cacheWrite
        }
        return out
    }

    private func approximate(_ period: UsagePeriod) -> UsagePeriod {
        var out = period
        var removed = UsagePeriod.Slice()
        for client in excludedClients {
            if let s = out.byClient.removeValue(forKey: client) { removed.add(s) }
        }
        for model in excludedModels {
            if let s = out.byModel.removeValue(forKey: model) { removed.add(s) }
        }
        out.totalTokens = max(0, out.totalTokens - removed.tokens)
        out.costUsd = max(0, out.costUsd - removed.costUsd)
        out.messages = max(0, out.messages - removed.messages)
        out.inputTokens = max(0, out.inputTokens - removed.input)
        out.outputTokens = max(0, out.outputTokens - removed.output)
        out.cacheReadTokens = max(0, out.cacheReadTokens - removed.cacheRead)
        out.cacheWriteTokens = max(0, out.cacheWriteTokens - removed.cacheWrite)
        return out
    }
}
