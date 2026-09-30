import Foundation
import Observation

/// History / trend data: tokscale graph output is merged into the archive every 15 minutes.
/// At launch the old Token Monitor archive is absorbed (larger wins, idempotent) — it holds the history from before SimpleToken.
@Observable
@MainActor
public final class HistoryStore {
    public private(set) var archive: DailyHistoryArchive
    public private(set) var daily: [DailyHistoryArchive.DaySummary] = []
    /// Incremented on every daily-summary recompute (cache key for derived data)
    public private(set) var version = 0
    /// New data was absorbed from the old app during this launch
    public private(set) var importedFromLegacy = false
    /// Every model / tool ever seen (regardless of the filter)
    public private(set) var catalog: (models: [DailyHistoryArchive.CatalogEntry], clients: [DailyHistoryArchive.CatalogEntry]) = ([], [])
    /// Usage filter: changing it recomputes the daily summaries
    public var filter = UsageFilter() {
        didSet { if filter != oldValue { recomputeDaily() } }
    }

    private let runner: TokscaleRunner
    private var refreshTimer: Task<Void, Never>?

    public init(runner: TokscaleRunner) {
        self.runner = runner
        var archive = DailyHistoryArchive.load(from: AppPaths.dailyHistoryArchive) ?? DailyHistoryArchive()
        // The old app is read-only: copy its observations, never write its files
        if let legacy = DailyHistoryArchive.load(from: AppPaths.legacyHistoryArchive),
           archive.absorb(legacy, todayKey: Fmt.dayKey()) {
            archive.save(to: AppPaths.dailyHistoryArchive)
            importedFromLegacy = true
        }
        self.archive = archive
        recomputeDaily()
    }

    public func start() {
        refreshTimer = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                await self?.refresh()
            }
        }
    }

    public func stop() {
        refreshTimer?.cancel()
    }

    public func refresh() async {
        guard let graph = try? await runner.graph() else { return }
        archive.merge(graph: graph, todayKey: Fmt.dayKey())
        archive.save(to: AppPaths.dailyHistoryArchive)
        recomputeDaily()
    }

    /// Demo mode: replace the archive with synthetic data (nothing is saved)
    public func loadDemo(_ demo: DailyHistoryArchive) {
        archive = demo
        importedFromLegacy = false
        recomputeDaily()
    }

    private func recomputeDaily() {
        daily = archive.dailySummaries(todayKey: Fmt.dayKey(), filter: filter)
        version += 1
        catalog = archive.catalog()
    }
}
