import Foundation

/// Limit provider. The UI picks colour and mark by it; they never follow the ranking.
public enum LimitProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Limit window (normalised). Claude: 5h session / weekly / Fable; Codex: weekly (and possibly session),
/// plus per-model extra limits (kind = .model, title = model name).
public struct LimitWindow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case session, weekly, fable, model
    }

    public var kind: Kind
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Window length (minutes), used for elapsed window time and pace projection. Inferred from kind if absent.
    public var windowMinutes: Int?
    /// Name of an extra limit (e.g. GPT-5.3-Codex-Spark); nil for regular windows
    public var title: String?

    public var id: String { kind.rawValue + "|" + (title ?? "") }
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?, windowMinutes: Int? = nil, title: String? = nil) {
        self.kind = kind
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.title = title
    }

    /// Window length (seconds): the explicit value, otherwise the kind's standard length
    public var spanSeconds: TimeInterval {
        if let windowMinutes, windowMinutes > 0 { return TimeInterval(windowMinutes) * 60 }
        return kind == .session ? 5 * 3600 : 7 * 86400
    }

    /// Fraction of the window elapsed (0…1); nil without a reset time
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / spanSeconds))
    }

    /// Projected usage at reset at the current pace (%). nil early in the window (<10%), where extrapolation is unreliable.
    public func projectedPercent(now: Date = Date()) -> Double? {
        guard usedPercent > 0, let elapsed = elapsedFraction(now: now), elapsed >= 0.1 else { return nil }
        return usedPercent / elapsed
    }
}

/// Limit snapshot of one provider
public struct ProviderLimits: Codable, Equatable, Sendable {
    public var provider: LimitProvider
    public var windows: [LimitWindow]
    /// Plan label (Max 20x / Pro 5x …)
    public var accountLabel: String
    public var updatedAt: Date

    public init(provider: LimitProvider = .claude, windows: [LimitWindow], accountLabel: String, updatedAt: Date) {
        self.provider = provider
        self.windows = windows
        self.accountLabel = accountLabel
        self.updatedAt = updatedAt
    }

    public func window(_ kind: LimitWindow.Kind) -> LimitWindow? {
        windows.first { $0.kind == kind }
    }

    /// Main window for the UI: session first, then weekly, then the first one
    public var primaryWindow: LimitWindow? {
        window(.session) ?? window(.weekly) ?? windows.first
    }
}

/// Compatibility alias: the Claude Web probe produces a provider snapshot
public typealias ClaudeLimits = ProviderLimits

public enum LimitsError: Error, Equatable {
    case notConfigured          // no credentials / no CLI
    case invalidCookie          // not sk-ant-
    case unauthorized           // 401/403 — cookie expired
    case sourceRateLimited      // 429
    case challenge              // blocked by Cloudflare
    case unavailable(String)    // anything else
}
