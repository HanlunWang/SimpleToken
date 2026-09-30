import Foundation

/// Anchor of the last full tick; watch ticks derive from it arithmetically. Persisting it means a restart
/// does not pay for three scans first (a stale date or config forces a full re-anchor).
public struct CollectorAnchor: Codable, Equatable, Sendable {
    public var dayKey: String
    public var fingerprint: String
    public var today: UsagePeriod
    public var month: UsagePeriod
    public var allTime: UsagePeriod
    public var collectedAt: Date

    public init(dayKey: String, fingerprint: String,
                today: UsagePeriod, month: UsagePeriod, allTime: UsagePeriod,
                collectedAt: Date) {
        self.dayKey = dayKey
        self.fingerprint = fingerprint
        self.today = today
        self.month = month
        self.allTime = allTime
        self.collectedAt = collectedAt
    }
}

public enum AnchorStore {
    /// Config fingerprint: a changed client list or allTimeSince invalidates the old anchor
    public static func fingerprint(clients: String, allTimeSince: String) -> String {
        "\(clients)|\(allTimeSince)"
    }

    public static func load(from url: URL = AppPaths.collectorAnchor,
                            fingerprint: String) -> CollectorAnchor? {
        guard let data = try? Data(contentsOf: url),
              let anchor = try? JSONDecoder.iso.decode(CollectorAnchor.self, from: data),
              anchor.fingerprint == fingerprint
        else { return nil }
        return anchor
    }

    public static func save(_ anchor: CollectorAnchor, to url: URL = AppPaths.collectorAnchor) {
        guard let data = try? JSONEncoder.iso.encode(anchor) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
public extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
