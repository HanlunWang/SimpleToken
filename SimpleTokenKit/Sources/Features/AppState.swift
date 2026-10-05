import Foundation
import SwiftUI
import Core
import Observation

/// App-level state: assembles the stores and owns their lifecycle, plus derived data shared by the UI.
/// All derived data is filtered by the usage filter in settings (excluded models / tools).
@Observable
@MainActor
public final class AppState {
    public let usage: UsageStore
    public let history: HistoryStore
    public let limits: LimitsStore
    public let intraday: IntradayStore
    private let notifier: LimitNotifier

    /// Called after window settings change (injected by AppDelegate: re-applies float on top etc.)
    public var applyWindowSettings: (() -> Void)?
    /// Opens the main window (used by the quick panel's button)
    public var openMainWindow: (() -> Void)?
    /// Whether the main window shows the settings page (settings replace the main window content instead of opening a new window)
    public var showingSettings = false
    /// Current settings tab (general / menubar / panel / models / cards / limits / data)
    public var settingsTabKey = "general"
    /// Whether the main window / quick panel is visible (maintained by the window controllers); live collection pauses when neither is
    public var mainWindowVisible = false
    public var panelVisible = false

    @ObservationIgnored private var reportCache: [String: RangeReport] = [:]
    @ObservationIgnored private var colorsCache: (key: String, colors: ModelColors)?

    public init() {
        guard let binary = TokscaleRunner.locateBinary() else {
            fatalError("tokscale binary not found — bundle Resources/tokscale missing")
        }
        // Pure-JSONL tools are collected along the way (free when there is no data) and feed the tools card
        let runner = TokscaleRunner(binary: binary, clients: "claude,codex,copilot,opencode,gemini")
        usage = UsageStore(runner: runner)
        history = HistoryStore(runner: runner)
        limits = LimitsStore()
        intraday = IntradayStore()
        notifier = LimitNotifier(limits: limits)
    }

    public func start() {
        if DemoData.isEnabled {
            // Screenshots / demos: synthetic data, no collectors, no network, nothing written
            let archive = DemoData.archive()
            history.loadDemo(archive)
            usage.loadDemo(DemoData.snapshot(from: archive))
            let demoLimits = DemoData.limits()
            limits.loadDemo(claude: demoLimits.claude, codex: demoLimits.codex)
            intraday.loadDemo(DemoData.intraday(from: archive))
        } else {
            usage.start()
            history.start()
            limits.start()
            intraday.start()
            notifier.start()
        }
        // Usage filter, refresh intervals, visibility → stores
        observeContinuously { [weak self] in
            guard let self else { return }
            let settings = SettingsStore.shared
            let filter = settings.usageFilter
            if self.history.filter != filter { self.history.filter = filter }
            self.usage.minWatchInterval = TimeInterval(settings.liveRefreshSeconds)
            self.usage.fullInterval = TimeInterval(settings.fullRefreshMinutes * 60)
            let visible = self.mainWindowVisible || self.panelVisible
            let menuBarNeedsToday = settings.menuBarEntries.contains { $0.needsLiveUsage }
            let live = visible || menuBarNeedsToday
            if self.usage.liveUpdatesEnabled != live { self.usage.liveUpdatesEnabled = live }
            // The intraday scan runs while something shows it: a window, or the menu bar's hourly chart
            let intradayLive = visible || settings.menuBarEntries.contains(.todayHours)
            if self.intraday.paused == intradayLive { self.intraday.paused = !intradayLive }
        }
    }

    /// Manual refresh: full usage rescan + history + intraday + limits
    public func refreshAll() {
        guard !isRefreshing, !DemoData.isEnabled else { return }
        isRefreshing = true
        usage.requestFullTick()
        limits.refreshNow()
        Task {
            await history.refresh()
            await intraday.refresh()
            // Wait for the usage scan and limit probes to settle (up to 60 seconds)
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                let probing = limits.claudeStatus == .probing || limits.codexStatus == .probing
                if !usage.isCollecting && !probing { break }
            }
            isRefreshing = false
        }
    }

    /// A manual refresh is in progress (spins the top-bar refresh icon). Background ticks and limit retries don't count —
    /// otherwise the icon would spin every few dozen seconds and the UI would keep redrawing.
    public private(set) var isRefreshing = false

    public func stop() {
        usage.stop()
        history.stop()
        limits.stop()
        intraday.stop()
    }

    /// Opens settings: switches the main window to the settings page (optionally on a given tab)
    public func openSettings(tab: String? = nil) {
        if let tab { settingsTabKey = tab }
        withAnimation(.smooth(duration: 0.35)) { showingSettings = true }
        openMainWindow?()
    }

    // MARK: - Derived data

    private var filter: UsageFilter { SettingsStore.shared.usageFilter }

    /// Live period after the usage filter
    public func period(_ which: KeyPath<UsageSnapshot, UsagePeriod>) -> UsagePeriod? {
        usage.snapshot.map { filter.apply($0[keyPath: which]) }
    }

    /// Live today (fresher than the 15-minute archive)
    public var liveToday: DailyHistoryArchive.DaySummary? {
        guard let snap = usage.snapshot else { return nil }
        return RangeAnalytics.liveDay(from: filter.apply(snap.today), dayKey: snap.dayKey)
    }

    /// Reports are cached by (range, metric, history version, live snapshot time, filter): redraws don't recompute
    public func report(range: TimeRange, metric: UsageMetric) -> RangeReport {
        let key = "\(range.rawValue)|\(metric.rawValue)|\(dataKey)"
        if let cached = reportCache[key] { return cached }
        let report = RangeAnalytics.report(range: range, metric: metric, history: history.daily, liveToday: liveToday)
        if reportCache.count > 24 { reportCache.removeAll() }
        reportCache[key] = report
        return report
    }

    /// Version key for derived data (reading it registers observation, so views update when data changes)
    private var dataKey: String {
        let settings = SettingsStore.shared
        return "\(history.version)|\(usage.snapshot?.collectedAt.timeIntervalSince1970 ?? 0)|\(settings.excludedModels.sorted())|\(settings.excludedClients.sorted())|\(Fmt.dayKey())"
    }

    public var monthCost: RangeAnalytics.MonthCost {
        RangeAnalytics.monthCost(history: history.daily, liveToday: liveToday)
    }

    /// Daily summary for a day (live for today)
    public func daySummary(_ key: String) -> DailyHistoryArchive.DaySummary {
        if key == Fmt.dayKey(), let liveToday { return liveToday }
        return history.daily.last { $0.date == key } ?? .init(date: key)
    }

    /// Tokens per (tool, model) pair over a report's days: today from the live snapshot, earlier days from the
    /// archive's observations. Feeds the flow and map widgets. Memoized with the reports.
    public func pairs(for report: RangeReport) -> [(client: String, model: String, tokens: Int)] {
        let key = "pairs|\(report.range.rawValue)|\(dataKey)"
        if let cached = pairsCache[key] { return cached }
        let filter = self.filter
        let todayKey = Fmt.dayKey()
        var sums: [String: [String: Int]] = [:]
        for day in report.days {
            if day.date == todayKey, let today = usage.snapshot?.today {
                for (pair, slice) in filter.apply(today).byPair where slice.tokens > 0 {
                    let (client, model) = UsagePeriod.splitPair(pair)
                    sums[client, default: [:]][model, default: 0] += slice.tokens
                }
                continue
            }
            guard let archived = history.archive.days[day.date] else { continue }
            for o in archived.observations.values where o.tokens > 0 {
                guard !filter.excludedClients.contains(o.client), !filter.excludedModels.contains(o.modelId),
                      !o.modelId.lowercased().contains("synthetic") else { continue }
                sums[o.client, default: [:]][o.modelId, default: 0] += o.tokens
            }
        }
        let out = sums.flatMap { client, models in models.map { (client: client, model: $0.key, tokens: $0.value) } }
            .sorted { $0.tokens > $1.tokens }
        if pairsCache.count > 12 { pairsCache.removeAll() }
        pairsCache[key] = out
        return out
    }
    @ObservationIgnored private var pairsCache: [String: [(client: String, model: String, tokens: Int)]] = [:]

    /// Model colours: ranked by trailing-30-day usage (independent of the selected range; current main models always get a colour)
    public var modelColors: ModelColors {
        let settings = SettingsStore.shared
        let key = "\(dataKey)|\(settings.modelColorMode)|\(settings.modelColorOverrides)|\(settings.modelAliases)|\(settings.toolColorOverrides)|\(settings.separateModels)|\(history.catalog.models.count)"
        if let cached = colorsCache, cached.key == key { return cached.colors }
        let report = self.report(range: .month, metric: .tokens)
        var ranked = report.models.map(\.key)
        // Models unused in the last 30 days follow (by all-time history), so manual colours and vendor shades stay stable
        for entry in history.catalog.models where !ranked.contains(entry.key) { ranked.append(entry.key) }
        let colors = ModelColors(rankedModels: ranked, mode: settings.modelColorMode, overrides: settings.modelColorOverrides,
                                 aliases: settings.modelAliases, toolOverrides: settings.toolColorOverrides,
                                 separate: settings.separateModels)
        colorsCache = (key, colors)
        return colors
    }

    /// Intraday data comes only from Claude Code session logs: empty when Claude Code is excluded
    public var intradayExcludedModels: Set<String>? {
        let settings = SettingsStore.shared
        return settings.excludedClients.contains("claude") ? nil : settings.excludedModels
    }

    /// Half-hour buckets for a day (per model)
    public func halfHourModels(_ dayKey: String) -> [String: [Int]] {
        guard let excluded = intradayExcludedModels else { return [:] }
        return intraday.snapshot.modelBuckets(for: dayKey, excluding: excluded)
    }

    /// Today's half-hour buckets (total)
    public var todayHalfHours: [Int] { halfHours(Fmt.dayKey()) }

    /// Half-hour buckets for a day (total)
    public func halfHours(_ dayKey: String) -> [Int] {
        guard let excluded = intradayExcludedModels else { return Array(repeating: 0, count: 48) }
        return intraday.snapshot.buckets(for: dayKey, excluding: excluded)
    }

    public func punchcard(days: Int) -> IntradayScanner.Punchcard {
        guard let excluded = intradayExcludedModels else { return .init() }
        return intraday.snapshot.punchcard(days: days, todayKey: Fmt.dayKey(), excluding: excluded)
    }
}

/// Continuous observation helper for @Observable (used by AppKit consumers such as the status item)
@MainActor
public func observeContinuously(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeContinuously(apply) }
    }
}
