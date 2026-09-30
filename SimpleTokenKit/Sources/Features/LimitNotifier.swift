import Foundation
import UserNotifications
import Core

/// Limit alerts: posts a system notification when a window's usage (session / weekly / Fable…) crosses an alert threshold.
/// Each threshold fires once per window period (recorded in UserDefaults, so relaunches don't repeat it);
/// when several thresholds are crossed at once, only the highest is posted.
@MainActor
public final class LimitNotifier {
    private let limits: LimitsStore
    private let defaults = UserDefaults.standard
    private static let key = "limitNotified"

    public init(limits: LimitsStore) {
        self.limits = limits
    }

    /// The notification center is unavailable without a bundle id (package run from the command line)
    public static var available: Bool { Bundle.main.bundleIdentifier != nil }

    public func start() {
        guard Self.available else { return }
        observeContinuously { [weak self] in self?.check() }
    }

    public static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func check() {
        let settings = SettingsStore.shared
        let thresholds = settings.alertThresholds.sorted()
        let snapshots = [limits.claude, limits.codex]      // read first so observation is registered even while alerts are off
        guard settings.limitNotifications, !thresholds.isEmpty else { return }
        var notified = Set(defaults.stringArray(forKey: Self.key) ?? [])
        var changed = false
        for snapshot in snapshots.compactMap(\.self) where !settings.hiddenLimitProviders.contains(snapshot.provider.rawValue) {
            for window in snapshot.windows where window.kind != .model {
                let crossed = thresholds.filter { window.usedPercent >= $0 }
                guard let top = crossed.last else { continue }
                // Period = reset time rounded to the hour (second-level jitter in probes is not a new period)
                let period = window.resetsAt.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0
                func id(_ t: Double) -> String { "\(snapshot.provider.rawValue)|\(window.id)|\(period)|\(Int(t))" }
                let fresh = crossed.filter { !notified.contains(id($0)) }
                guard !fresh.isEmpty else { continue }
                for t in fresh { notified.insert(id(t)) }
                changed = true
                if fresh.contains(top) { post(snapshot.provider, window, threshold: top) }
            }
        }
        if changed {
            // Keep only the latest batch; records from old periods are useless
            defaults.set(Array(notified.sorted().suffix(200)), forKey: Self.key)
        }
    }

    private func post(_ provider: LimitProvider, _ window: LimitWindow, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = L("\(provider.displayName) · \(LimitsCard.label(window)): \(Int(window.usedPercent.rounded()))% used")
        var parts: [String] = [L("Crossed the \(Int(threshold))% alert threshold")]
        if let projected = window.projectedPercent() { parts.append(L("On pace for about \(Int(projected.rounded()))% by reset")) }
        if let reset = window.resetsAt { parts.append(L("Resets \(LimitsCard.resetFormatter(reset))")) }
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
