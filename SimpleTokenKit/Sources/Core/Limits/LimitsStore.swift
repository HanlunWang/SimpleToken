import Foundation
import Observation

/// Limit state (Claude + Codex): each refreshes every 5 minutes, again 30 s after a window reset, with
/// exponential backoff (5 s → 5 min, half jitter). A rotated Claude cookie is written back at once (or it dies).
@Observable
@MainActor
public final class LimitsStore {
    public enum Status: Equatable, Sendable {
        case idle, probing, ok
        case failed(String)
        case notConfigured
    }

    public private(set) var claude: ProviderLimits?
    public private(set) var codex: ProviderLimits?
    public private(set) var claudeStatus: Status = .idle
    public private(set) var codexStatus: Status = .idle

    /// For older callers: the Claude snapshot
    public var limits: ProviderLimits? { claude }

    private var organizationIdCache: String?
    private var claudePlanLabel = ""
    private var tasks: [Task<Void, Never>] = []
    private var failures: [LimitProvider: Int] = [:]

    public init() {}

    /// Demo mode: synthetic limits, no probing
    public func loadDemo(claude: ProviderLimits, codex: ProviderLimits) {
        self.claude = claude
        self.codex = codex
        claudeStatus = .ok
        codexStatus = .ok
    }

    public func start() {
        Task { [weak self] in await self?.loadClaudePlanLabel() }
        tasks = [
            Task { [weak self] in
                while !Task.isCancelled {
                    let delay = await self?.refreshClaude() ?? 300
                    try? await Task.sleep(for: .seconds(delay))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    let delay = await self?.refreshCodex() ?? 300
                    try? await Task.sleep(for: .seconds(delay))
                }
            },
        ]
    }

    public func stop() { tasks.forEach { $0.cancel() } }

    public func refreshNow() {
        Task { _ = await refreshClaude() }
        Task { _ = await refreshCodex() }
    }

    // MARK: - Claude

    /// The keychain item has no token, but the subscriptionType / rateLimitTier metadata is still there — read only those
    private func loadClaudePlanLabel() async {
        guard let out = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 5
        ), out.exitCode == 0 else { return }
        guard let root = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else { return }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        claudePlanLabel = Self.planLabel(
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
        if var current = claude, current.accountLabel.isEmpty {
            current.accountLabel = claudePlanLabel
            claude = current
        }
    }

    /// Ported from claudePlanLabelFromParts: max + *_20x → "Max 20x"; otherwise the capitalised subscription name
    static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String {
        let sub = (subscriptionType ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let tierWords = (rateLimitTier ?? "")
            .split(whereSeparator: { "_- ".contains($0) })
            .map(String.init)
            .filter { !["default", "claude", "ai", "raven"].contains($0.lowercased()) }
        let tierLabel = tierWords.map { $0.count <= 3 ? $0.lowercased() : $0.capitalized }.joined(separator: " ")
        let subLabel = sub.isEmpty ? "" : (sub == "max" ? "Max" : sub.capitalized)
        if subLabel == "Max", let x = tierWords.last(where: { $0.lowercased().hasSuffix("x") }) {
            return "Max \(x.lowercased())"
        }
        return subLabel.isEmpty ? tierLabel : subLabel
    }

    /// Returns the seconds until the next refresh
    private func refreshClaude() async -> Double {
        var creds = CredentialStore.load()
        if creds.claudeWebCookie?.isEmpty ?? true, CredentialStore.importFromTokenMonitorIfMissing() {
            creds = CredentialStore.load()   // first-launch migration (approved by the user)
        }
        guard let cookie = creds.claudeWebCookie, !cookie.isEmpty else {
            claudeStatus = .notConfigured
            return 300
        }
        claudeStatus = .probing
        do {
            let probe = try ClaudeWebProbe(cookie: cookie)
            let (result, orgId) = try await probe.probe(cachedOrganizationId: organizationIdCache)
            organizationIdCache = orgId
            if let renewed = result.renewedSessionKey {
                var file = CredentialStore.load()
                file.claudeWebCookie = renewed
                CredentialStore.save(file)
            }
            var limits = result.limits
            limits.accountLabel = claudePlanLabel
            claude = limits
            claudeStatus = .ok
            failures[.claude] = 0
            return nextRegularDelay(limits)
        } catch {
            organizationIdCache = nil   // a stale org cache can cause a 401 — redo the full flow next time
            claudeStatus = .failed(String(describing: error))
            return backoffDelay(.claude)
        }
    }

    // MARK: - Codex

    private func refreshCodex() async -> Double {
        guard let executable = CodexProbe.locate() else {
            codexStatus = .notConfigured
            return 900
        }
        codexStatus = .probing
        do {
            let limits = try await CodexProbe(executable: executable).probe()
            codex = limits
            codexStatus = .ok
            failures[.codex] = 0
            return nextRegularDelay(limits)
        } catch LimitsError.notConfigured {
            codexStatus = .notConfigured
            return 900
        } catch {
            codexStatus = .failed(String(describing: error))
            return backoffDelay(.codex)
        }
    }

    // MARK: - Scheduling

    /// Every 5 minutes; if a window resets sooner, refresh 30 s after the reset
    private func nextRegularDelay(_ limits: ProviderLimits) -> Double {
        let regular = 300.0
        let now = Date()
        if let nearest = limits.windows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
            let untilAfterReset = nearest.timeIntervalSince(now) + 30
            if untilAfterReset < regular { return max(30, untilAfterReset) }
        }
        return regular
    }

    /// Exponential backoff: base 5 s, cap 5 min, half jitter
    private func backoffDelay(_ provider: LimitProvider) -> Double {
        let n = (failures[provider] ?? 0) + 1
        failures[provider] = n
        let base = min(300.0, 5.0 * pow(2, Double(n - 1)))
        return base / 2 + Double.random(in: 0...(base / 2))
    }
}
