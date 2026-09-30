import Foundation

/// Daily history archive — **same schema (version 1)** as the old app's daily-history-archive.json,
/// so its 40 days of existing data import directly. Observation key = JSON.stringify([client, modelId]).
public struct DailyHistoryArchive: Codable, Equatable, Sendable {
    public var version: Int
    public var days: [String: Day]

    public struct Day: Codable, Equatable, Sendable {
        public var date: String
        public var activeTimeMs: Double?
        public var observations: [String: Observation]
    }

    public struct Observation: Codable, Equatable, Sendable {
        public var client: String
        public var modelId: String
        public var providerId: String?
        public var tokens: Int
        public var cost: Double
        public var messages: Int
        public var reasoningTokens: Int?
    }

    public init() {
        version = 1
        days = [:]
    }

    /// Key format identical to the old code: JSON.stringify(["claude","claude-opus-5"])
    public static func observationKey(client: String, modelId: String) -> String {
        let data = try! JSONEncoder().encode([client, modelId])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Merging (semantics ported from the old code)
    //
    // Duplicate rows for the same (client, model, day) within one graph are **summed** (shards of one source);
    // against existing archive observations they **replace whole**: more tokens wins, ties compare messages,
    // and a full tie still replaces — equal usage may bring corrected pricing or fuller metadata, and
    // whole replacement keeps tokens and cost from the same collection. Future days are dropped.

    public mutating func merge(graph: TokscaleGraph, todayKey: String) {
        for day in graph.contributions ?? [] {
            guard let date = day.date, !date.isEmpty, date <= todayKey else { continue }

            // 1) Aggregate within the graph (duplicate observations are summed)
            var incoming: [String: Observation] = [:]
            for client in day.clients ?? [] {
                guard let name = client.client, let model = client.modelId else { continue }
                let tokens = client.collapsedTokens
                let cost = max(0, client.cost ?? 0)
                let messages = max(0, client.messages ?? 0)
                if tokens == 0 && cost == 0 && messages == 0 { continue }
                let key = Self.observationKey(client: name, modelId: model)
                if var existing = incoming[key] {
                    existing.tokens += tokens
                    existing.cost += cost
                    existing.messages += messages
                    existing.reasoningTokens = (existing.reasoningTokens ?? 0) + client.reasoningTokens
                    if existing.providerId == nil { existing.providerId = client.providerId }
                    incoming[key] = existing
                } else {
                    incoming[key] = Observation(
                        client: name, modelId: model, providerId: client.providerId,
                        tokens: tokens, cost: cost, messages: messages,
                        reasoningTokens: client.reasoningTokens > 0 ? client.reasoningTokens : nil
                    )
                }
            }

            // 2) Replace whole in the archive (larger wins)
            var entry = days[date] ?? Day(date: date, activeTimeMs: nil, observations: [:])
            if let active = day.activeTimeMs {
                entry.activeTimeMs = max(entry.activeTimeMs ?? 0, active)
            }
            for (key, observation) in incoming {
                if Self.shouldReplace(previous: entry.observations[key], incoming: observation) {
                    var next = observation
                    if next.providerId == nil { next.providerId = entry.observations[key]?.providerId }
                    entry.observations[key] = next
                }
            }
            days[date] = entry
        }
        days = days.filter { $0.key <= todayKey }
    }

    /// Absorbs another archive (same schema, e.g. the old Token Monitor's): larger wins per observation,
    /// the same semantics as a graph merge, so absorbing again is idempotent. Returns whether anything changed.
    @discardableResult
    public mutating func absorb(_ other: DailyHistoryArchive, todayKey: String) -> Bool {
        var changed = false
        for (date, day) in other.days where date <= todayKey {
            var entry = days[date] ?? Day(date: date, activeTimeMs: nil, observations: [:])
            if let active = day.activeTimeMs, active > (entry.activeTimeMs ?? 0) {
                entry.activeTimeMs = active
                changed = true
            }
            for (key, observation) in day.observations {
                let previous = entry.observations[key]
                guard previous != observation,
                      previous == nil || observation.tokens > previous!.tokens
                        || (observation.tokens == previous!.tokens && observation.messages > previous!.messages)
                else { continue }
                entry.observations[key] = observation
                changed = true
            }
            days[date] = entry
        }
        return changed
    }

    static func shouldReplace(previous: Observation?, incoming: Observation) -> Bool {
        guard let previous else { return true }
        if incoming.tokens != previous.tokens { return incoming.tokens > previous.tokens }
        if incoming.messages != previous.messages { return incoming.messages > previous.messages }
        return true
    }

    // MARK: - Reading (for trends / heat maps)

    public struct DaySummary: Equatable, Sendable {
        public var date: String
        public var tokens: Int
        public var cost: Double
        public var messages: Int
        public var activeTimeMs: Double
        public var byModel: [String: Int]
        public var costByModel: [String: Double]
        public var byClient: [String: Int]

        public init(date: String, tokens: Int = 0, cost: Double = 0, messages: Int = 0,
                    activeTimeMs: Double = 0, byModel: [String: Int] = [:],
                    costByModel: [String: Double] = [:], byClient: [String: Int] = [:]) {
            self.date = date
            self.tokens = tokens
            self.cost = cost
            self.messages = messages
            self.activeTimeMs = activeTimeMs
            self.byModel = byModel
            self.costByModel = costByModel
            self.byClient = byClient
        }
    }

    /// Uncapped by default: all history (the ALL range needs it); callers may pass capDays to limit it.
    /// Models / tools excluded by `filter` count toward no field.
    public func dailySummaries(capDays: Int = .max, todayKey: String, filter: UsageFilter = .init()) -> [DaySummary] {
        days.values
            .filter { $0.date <= todayKey }
            .sorted { $0.date < $1.date }
            .suffix(capDays)
            .map { day in
                var summary = DaySummary(date: day.date, activeTimeMs: day.activeTimeMs ?? 0)
                for obs in day.observations.values {
                    let client = TokscaleReport.normalizeClient(obs.client)
                    guard filter.includes(client: client, model: obs.modelId) else { continue }
                    summary.tokens += obs.tokens
                    summary.cost += obs.cost
                    summary.messages += obs.messages
                    summary.byModel[obs.modelId, default: 0] += obs.tokens
                    summary.costByModel[obs.modelId, default: 0] += obs.cost
                    summary.byClient[client, default: 0] += obs.tokens
                }
                return summary
            }
    }

    /// Every model / tool ever seen (regardless of the filter; settings lists them with a switch each)
    public struct CatalogEntry: Sendable, Identifiable, Equatable {
        public var id: String { key }
        public let key: String
        public let clients: Set<String>
        public let tokens: Int
        public let cost: Double
        public let lastSeen: String
    }

    public func catalog() -> (models: [CatalogEntry], clients: [CatalogEntry]) {
        var models: [String: (Set<String>, Int, Double, String)] = [:]
        var clients: [String: (Int, Double, String)] = [:]
        for day in days.values {
            for obs in day.observations.values {
                let client = TokscaleReport.normalizeClient(obs.client)
                var m = models[obs.modelId] ?? ([], 0, 0, "")
                m.0.insert(client); m.1 += obs.tokens; m.2 += obs.cost; m.3 = max(m.3, day.date)
                models[obs.modelId] = m
                var c = clients[client] ?? (0, 0, "")
                c.0 += obs.tokens; c.1 += obs.cost; c.2 = max(c.2, day.date)
                clients[client] = c
            }
        }
        return (
            models.map { CatalogEntry(key: $0.key, clients: $0.value.0, tokens: $0.value.1, cost: $0.value.2, lastSeen: $0.value.3) }
                .sorted { $0.tokens > $1.tokens },
            clients.map { CatalogEntry(key: $0.key, clients: [$0.key], tokens: $0.value.0, cost: $0.value.1, lastSeen: $0.value.2) }
                .sorted { $0.tokens > $1.tokens }
        )
    }

    // MARK: - Persistence

    public static func load(from url: URL) -> DailyHistoryArchive? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(DailyHistoryArchive.self, from: data),
              archive.version == 1
        else { return nil }
        return archive
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
