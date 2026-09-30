import Foundation
import Observation

/// Usage collection: full ticks (three scans + re-anchoring) and watch ticks (--today only + arithmetic).
/// Single-flight: at most one tick runs at a time; requests arriving meanwhile coalesce into one replay.
///
/// Cost: each tokscale scan takes ~1.2 CPU-s and a child process peaking at ~570 MB, so watch ticks are
/// throttled (`minWatchInterval`, default 30 s, no matter how often logs are written) and paused while
/// no UI is visible (`liveUpdatesEnabled = false` only marks dirty; one catch-up runs on resume).
@Observable
@MainActor
public final class UsageStore {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: String?
    public private(set) var isCollecting = false
    public private(set) var timeline: TodayTimeline
    public private(set) var hourly: HourlyHistory

    private let runner: TokscaleRunner
    private let fingerprint: String
    private var anchor: CollectorAnchor?
    private var watcher: UsageWatcher?
    private var debounceTask: Task<Void, Never>?
    private var fullTickTimer: Task<Void, Never>?
    private var tickInFlight = false
    private var pendingFull = false
    private var pendingWatch = false
    private var lastTickAt = Date.distantPast
    /// Logs changed but not yet collected
    private var dirty = false

    /// Minimum interval between watch ticks (seconds)
    public var minWatchInterval: TimeInterval = 30
    /// Full rescan interval (seconds)
    public var fullInterval: TimeInterval = 900
    /// Live collection switch: AppState turns it off when no UI is visible and the menu bar shows no today numbers
    public var liveUpdatesEnabled = true {
        didSet {
            if liveUpdatesEnabled, !oldValue, dirty { scheduleWatchTick() }
        }
    }

    /// Demo mode: show a synthetic snapshot instead of collecting
    public func loadDemo(_ demo: UsageSnapshot) {
        snapshot = demo
    }

    public init(runner: TokscaleRunner) {
        self.runner = runner
        self.fingerprint = AnchorStore.fingerprint(clients: runner.clients, allTimeSince: runner.allTimeSince)
        self.timeline = TodayTimeline.load() ?? TodayTimeline(dayKey: Fmt.dayKey())
        self.hourly = HourlyHistory.load() ?? HourlyHistory()
        // Warm start: the on-disk anchor is the first snapshot (numbers show at once), then a full scan corrects it
        if let saved = AnchorStore.load(fingerprint: fingerprint), saved.dayKey == Fmt.dayKey() {
            anchor = saved
            snapshot = UsageSnapshot(today: saved.today, month: saved.month, allTime: saved.allTime,
                                     collectedAt: saved.collectedAt, dayKey: saved.dayKey)
        }
    }

    public func start() {
        // Full scan at launch + periodic re-anchoring (interval re-read each round, so setting changes apply next round)
        requestFullTick()
        fullTickTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.fullInterval ?? 900))
                self?.requestFullTick()
            }
        }
        // File watching → throttle → watch tick
        let watcher = UsageWatcher(paths: UsageWatcher.claudeWatchPaths()) { [weak self] in
            Task { @MainActor in self?.scheduleWatchTick() }
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        fullTickTimer?.cancel()
        debounceTask?.cancel()
    }

    /// Manual refresh (settings / menu action) = full
    public func requestFullTick() {
        pendingFull = true
        Task { await drainTicks() }
    }

    /// Throttle (not debounce): a scheduled tick is never cancelled, so constant log writes cannot starve it;
    /// waits out the rest of minWatchInterval since the last collection, and at least 2 s so a burst of writes lands.
    private func scheduleWatchTick() {
        dirty = true
        guard liveUpdatesEnabled, debounceTask == nil else { return }
        let wait = max(2, minWatchInterval - Date().timeIntervalSince(lastTickAt))
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            self.pendingWatch = true
            await self.drainTicks()
        }
    }

    private func drainTicks() async {
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        while pendingFull || pendingWatch {
            // Full wins: a coalesced watch request is covered by the full scan (which includes the latest today)
            let full = pendingFull
            pendingFull = false
            pendingWatch = false
            dirty = false
            lastTickAt = Date()
            do {
                if full { try await runFullTick() } else { try await runWatchTick() }
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    private func runFullTick() async throws {
        isCollecting = true
        defer { isCollecting = false }
        let clock = Date()                      // single clock, captured before scanning
        let dayKey = Fmt.dayKey(clock)
        // Serial scans (concurrent ones triple CPU/IO)
        let today = try await runner.scan(.today).aggregate()
        let month = try await runner.scan(.month).aggregate()
        let allTime = try await runner.scan(.allTime(since: runner.allTimeSince)).aggregate()

        let anchor = CollectorAnchor(dayKey: dayKey, fingerprint: fingerprint,
                                     today: today, month: month, allTime: allTime,
                                     collectedAt: clock)
        self.anchor = anchor
        AnchorStore.save(anchor)
        snapshot = UsageSnapshot(today: today, month: month, allTime: allTime,
                                 collectedAt: clock, dayKey: dayKey)
        recordTimeline(tokens: today.totalTokens, at: clock)
    }

    private func runWatchTick() async throws {
        let clock = Date()
        let dayKey = Fmt.dayKey(clock)
        // Stale anchor (new day / none) → upgrade to a full tick
        guard let anchor, anchor.dayKey == dayKey else {
            try await runFullTick()
            return
        }
        isCollecting = true
        defer { isCollecting = false }
        let freshToday = try await runner.scan(.today).aggregate()
        let month = UsagePeriod.delta(base: anchor.month, fresh: freshToday, anchor: anchor.today)
        let allTime = UsagePeriod.delta(base: anchor.allTime, fresh: freshToday, anchor: anchor.today)
        // Leave the anchor alone — it belongs to the last full tick; watch ticks only produce snapshots
        snapshot = UsageSnapshot(today: freshToday, month: month, allTime: allTime,
                                 collectedAt: clock, dayKey: dayKey)
        recordTimeline(tokens: freshToday.totalTokens, at: clock)
    }

    private func recordTimeline(tokens: Int, at date: Date) {
        timeline.record(tokens: tokens, at: date)
        timeline.save()
        let dayKey = Fmt.dayKey(date)
        hourly.set(dayKey: dayKey, halfHourBuckets: timeline.halfHourBuckets(now: date), todayKey: dayKey)
        hourly.save()
    }
}
