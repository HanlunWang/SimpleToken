import Foundation
import Observation

/// Settings store: backed by UserDefaults, @Observable for SwiftUI.
/// Key names never change once shipped (old keys stay compatible; new options get defaults).
@Observable
@MainActor
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: - Window

    public var floatingWindow: Bool {
        didSet { defaults.set(floatingWindow, forKey: "floatingWindow") }
    }
    /// Menu bar click: true = quick panel, false = main window
    public var clickOpensPanel: Bool {
        didSet { defaults.set(clickOpensPanel, forKey: "clickOpensPanel") }
    }

    // MARK: - Refresh

    /// Minimum interval between live (today) collections, in seconds: 15 / 30 / 60 / 120
    public var liveRefreshSeconds: Int {
        didSet { defaults.set(liveRefreshSeconds, forKey: "liveRefreshSeconds") }
    }
    /// Interval between full rescans (today / month / all time), in minutes: 10 / 15 / 30
    public var fullRefreshMinutes: Int {
        didSet { defaults.set(fullRefreshMinutes, forKey: "fullRefreshMinutes") }
    }

    // MARK: - Limits

    /// Limit numbers: true = % used (default), false = % remaining
    public var limitShowUsed: Bool {
        didSet { defaults.set(limitShowUsed, forKey: "limitShowUsed") }
    }
    /// Alert thresholds (% used): the menu bar turns red at the highest one; notifications fire once per threshold
    public var alertThresholds: [Double] {
        didSet { defaults.set(alertThresholds, forKey: "alertThresholds") }
    }
    /// Post a system notification when a limit reaches an alert threshold
    public var limitNotifications: Bool {
        didSet { defaults.set(limitNotifications, forKey: "limitNotifications") }
    }
    /// Providers hidden from the limits card / quick panel (claude / codex)
    public var hiddenLimitProviders: Set<String> {
        didSet { defaults.set(Array(hiddenLimitProviders), forKey: "hiddenLimitProviders") }
    }
    /// Even-pace reference line on limit bars
    public var limitShowPace: Bool {
        didSet { defaults.set(limitShowPace, forKey: "limitShowPace") }
    }

    // MARK: - Menu bar

    /// Data the menu bar can show (multi-select, in selection order)
    public enum MenuBarItem: String, CaseIterable, Sendable, Identifiable {
        case claudeSession = "claude.session", claudeWeekly = "claude.weekly", claudeFable = "claude.fable"
        case codexSession = "codex.session", codexWeekly = "codex.weekly"
        case todayTokens = "today.tokens", todayCost = "today.cost", monthCost = "month.cost"
        case sessionReset = "claude.reset"
        public var id: String { rawValue }

        public var localizedName: String {
            switch self {
            case .claudeSession: L("Claude session limit")
            case .claudeWeekly: L("Claude weekly limit")
            case .claudeFable: L("Claude Fable limit")
            case .codexSession: L("Codex 5-hour limit")
            case .codexWeekly: L("Codex weekly limit")
            case .todayTokens: L("Today's tokens")
            case .todayCost: L("Today's cost")
            case .monthCost: L("This month's cost")
            case .sessionReset: L("Session reset countdown")
            }
        }
        /// Small label shown in the menu bar
        public var shortLabel: String {
            switch self {
            case .claudeSession, .codexSession: "5h"
            case .claudeWeekly, .codexWeekly: L("wk")
            case .claudeFable: "Fable"
            case .todayTokens, .todayCost: L("today")
            case .monthCost: L("month")
            case .sessionReset: L("reset")
            }
        }
        /// Provider of a limit item (claude / codex); nil for the rest
        public var provider: String? {
            switch self {
            case .claudeSession, .claudeWeekly, .claudeFable, .sessionReset: "claude"
            case .codexSession, .codexWeekly: "codex"
            default: nil
            }
        }
        /// Needs live usage (today / this month)
        public var needsLiveUsage: Bool {
            switch self {
            case .todayTokens, .todayCost, .monthCost: true
            default: false
            }
        }
    }

    /// What the menu bar shows (empty = icon only)
    public var menuBarItems: [String] {
        didSet { defaults.set(menuBarItems, forKey: "menuBarItems") }
    }
    /// Menu bar style: text (one line) / stacked (two lines, label on top) / ring (limits as small rings) / bar (a progress bar under each limit)
    public var menuBarStyle: String {
        didSet { defaults.set(menuBarStyle, forKey: "menuBarStyle") }
    }
    /// Show small labels (5h, wk, today…) in the text / ring / bar styles
    public var menuBarShowLabels: Bool {
        didSet { defaults.set(menuBarShowLabels, forKey: "menuBarShowLabels") }
    }
    /// Numbers turn red when a limit reaches the highest alert threshold
    public var menuBarAlertColor: Bool {
        didSet { defaults.set(menuBarAlertColor, forKey: "menuBarAlertColor") }
    }
    public var menuBarShowIcon: Bool {
        didSet { defaults.set(menuBarShowIcon, forKey: "menuBarShowIcon") }
    }
    public var menuBarEntries: [MenuBarItem] { menuBarItems.compactMap(MenuBarItem.init(rawValue:)) }

    // MARK: - Quick panel (menu bar drop-down)

    public enum PanelSection: String, CaseIterable, Sendable, Identifiable {
        case claude, codex, today, models, tools, week, month
        public var id: String { rawValue }
        public var localizedName: String {
            switch self {
            case .claude: L("Claude limits")
            case .codex: L("Codex limits")
            case .today: L("Today: usage and trend")
            case .models: L("Today's models")
            case .tools: L("Today's tools")
            case .week: L("Last 7 days")
            case .month: L("This month's cost")
            }
        }
        public var icon: String {
            switch self {
            case .claude, .codex: "gauge.with.dots.needle.50percent"
            case .today: "chart.line.uptrend.xyaxis"
            case .models: "cpu"
            case .tools: "hammer"
            case .week: "chart.bar.xaxis"
            case .month: "dollarsign.circle"
            }
        }
    }
    /// Panel sections (list order is display order; unlisted sections are hidden)
    public var panelSections: [String] {
        didSet { defaults.set(panelSections, forKey: "panelSections") }
    }
    /// Today's trend in the panel: cumulative curve / hourly bars
    public var panelTodayStyle: String {
        didSet { defaults.set(panelTodayStyle, forKey: "panelTodayStyle") }
    }
    public var panelShowResets: Bool {
        didSet { defaults.set(panelShowResets, forKey: "panelShowResets") }
    }
    /// Panel width (pt): 320 / 360 / 400
    public var panelWidth: Int {
        didSet { defaults.set(panelWidth, forKey: "panelWidth") }
    }
    /// Limits in the panel: rings / bars
    public var panelLimitStyle: String {
        didSet { defaults.set(panelLimitStyle, forKey: "panelLimitStyle") }
    }
    /// Maximum rows in the panel's model / tool lists
    public var panelListCount: Int {
        didSet { defaults.set(panelListCount, forKey: "panelListCount") }
    }

    // MARK: - Dashboard

    public var range: TimeRange {
        didSet { defaults.set(range.rawValue, forKey: "dashboardRange") }
    }
    public var metric: UsageMetric {
        didSet { defaults.set(metric.rawValue, forKey: "dashboardMetric") }
    }
    /// Token display: false = short (4.96 B), true = exact (4,959,084,551)
    public var exactNumbers: Bool {
        didSet { defaults.set(exactNumbers, forKey: "statsExactNumber") }
    }
    /// Show the previous-period comparison line on the hero chart
    public var heroShowPrevious: Bool {
        didSet { defaults.set(heroShowPrevious, forKey: "heroShowPrevious") }
    }

    // MARK: - Models and tools

    /// Model colours: "vendor" (by vendor: Claude terracotta, OpenAI teal…) / "ranked" (three colour-blind-safe colours by usage rank)
    public var modelColorMode: String {
        didSet { defaults.set(modelColorMode, forKey: "modelColorMode") }
    }
    /// Manual model colours (model id → "#rrggbb")
    public var modelColorOverrides: [String: String] {
        didSet { defaults.set(modelColorOverrides, forKey: "modelColorOverrides") }
    }
    /// Manual tool colours (tool id → "#rrggbb")
    public var toolColorOverrides: [String: String] {
        didSet { defaults.set(toolColorOverrides, forKey: "toolColorOverrides") }
    }
    /// Model display names (model id → alias)
    public var modelAliases: [String: String] {
        didSet { defaults.set(modelAliases, forKey: "modelAliases") }
    }
    /// Models / tools excluded from all statistics
    public var excludedModels: Set<String> {
        didSet { defaults.set(Array(excludedModels), forKey: "excludedModels") }
    }
    public var excludedClients: Set<String> {
        didSet { defaults.set(Array(excludedClients), forKey: "excludedClients") }
    }
    /// Number of models with their own colour in charts (the rest merge into "Other")
    public var separateModels: Int {
        didSet { defaults.set(separateModels, forKey: "separateModels") }
    }

    public var usageFilter: UsageFilter {
        UsageFilter(excludedModels: excludedModels, excludedClients: excludedClients)
    }

    // MARK: - Cards

    /// Dashboard widgets (case order is the default layout). Every stat is a widget of its own.
    public enum Card: String, CaseIterable, Sendable, Identifiable {
        case hero
        case statAverage = "stat.average", statPeak = "stat.peak", statActive = "stat.active", statPerMillion = "stat.perMillion"
        case statTotalCost = "stat.totalCost", statMessages = "stat.messages", statTopModel = "stat.topModel", statWeekday = "stat.weekday"
        case limits, models, usage, calendar, punchcard, tools, composition, cost
        public var id: String { rawValue }

        /// Stat id of a stat widget (average / peak …); nil for other widgets
        public var statKey: String? {
            rawValue.hasPrefix("stat.") ? String(rawValue.dropFirst(5)) : nil
        }
        public var isStat: Bool { statKey != nil }
        public static var stats: [Card] { allCases.filter(\.isStat) }
        /// Stat widgets shown by default
        public static let defaultStats: [Card] = [.statAverage, .statPeak, .statActive, .statPerMillion]

        public var localizedName: String {
            switch self {
            case .hero: L("Main chart")
            case .statAverage: L("Daily average")
            case .statPeak: L("Peak day")
            case .statActive: L("Active days")
            case .statPerMillion: L("Per million tokens")
            case .statTotalCost: L("Total cost")
            case .statMessages: L("Message count")
            case .statTopModel: L("Top model")
            case .statWeekday: L("Busiest weekday")
            case .limits: L("Limits")
            case .models: L("Models")
            case .usage: L("Usage chart")
            case .calendar: L("Calendar")
            case .punchcard: L("Time of day")
            case .tools: L("Tools")
            case .composition: L("Token breakdown")
            case .cost: L("This month's cost")
            }
        }
        public var icon: String {
            switch self {
            case .hero: "chart.line.uptrend.xyaxis"
            case .statAverage: "chart.bar.xaxis"
            case .statPeak: "arrow.up.to.line"
            case .statActive: "calendar"
            case .statPerMillion: "dollarsign.circle"
            case .statTotalCost: "creditcard"
            case .statMessages: "bubble.left.and.bubble.right"
            case .statTopModel: "cpu"
            case .statWeekday: "calendar.day.timeline.left"
            case .limits: "gauge.with.dots.needle.50percent"
            case .models: "chart.pie"
            case .usage: "chart.bar.fill"
            case .calendar: "square.grid.3x3.square"
            case .punchcard: "circle.grid.3x3"
            case .tools: "hammer"
            case .composition: "square.stack.3d.up"
            case .cost: "dollarsign.arrow.circlepath"
            }
        }
        /// Sizes this widget supports (each size has its own layout)
        public var sizes: [CardSize] {
            switch self {
            case .hero, .usage: [.medium, .large, .wide]
            case .calendar: [.medium, .large, .wide]
            case .punchcard: [.medium, .large, .wide]
            case .cost: [.small, .medium, .large, .wide]
            case .limits, .models, .tools, .composition: [.small, .medium, .large]
            default: [.small, .medium]      // stats
            }
        }
        public var defaultSize: CardSize {
            switch self {
            case .hero, .usage, .cost: .wide
            case .limits, .models, .calendar, .punchcard: .large
            case .tools, .composition: .medium
            default: .small
            }
        }
    }

    /// Widget sizes in grid cells: small 1×1, medium 2×1, large 2×2, wide 4×2.
    /// The column count follows the window width while cells stay roughly the same size;
    /// wide widgets narrow when there are too few columns (see WidgetGrid).
    public enum CardSize: String, CaseIterable, Sendable, Identifiable, Comparable {
        case small, medium, large, wide
        public var id: String { rawValue }
        public var localizedName: String {
            switch self {
            case .small: L("Small")
            case .medium: L("Medium")
            case .large: L("Large")
            case .wide: L("Wide")
            }
        }
        /// Columns and rows occupied
        public var span: (columns: Int, rows: Int) {
            switch self {
            case .small: (1, 1)
            case .medium: (2, 1)
            case .large: (2, 2)
            case .wide: (4, 2)
            }
        }
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: CardSize, b: CardSize) -> Bool { a.rank < b.rank }
    }

    /// Manual widget sizes (id → small / medium / large / wide); the default size if absent
    public var cardSizes: [String: String] {
        didSet { defaults.set(cardSizes, forKey: "widgetSizes") }
    }
    public func size(_ card: Card) -> CardSize {
        guard let stored = cardSizes[card.rawValue].flatMap(CardSize.init(rawValue:)), card.sizes.contains(stored) else {
            return card.defaultSize
        }
        return stored
    }
    public func setSize(_ card: Card, _ size: CardSize) {
        cardSizes[card.rawValue] = size == card.defaultSize ? nil : size.rawValue
    }
    /// Widgets hidden by default: the stats not shown by default
    public static var defaultHidden: Set<String> {
        Set(Card.stats.filter { !Card.defaultStats.contains($0) }.map(\.rawValue))
    }
    /// Restores default order, sizes and visibility (card options are left alone)
    public func resetLayout() {
        cardOrder = Card.allCases.map(\.rawValue)
        cardSizes = [:]
        hiddenCards = Self.defaultHidden
    }

    public var hiddenCards: Set<String> {
        didSet { defaults.set(Array(hiddenCards), forKey: "hiddenCards") }
    }
    public func isVisible(_ card: Card) -> Bool { !hiddenCards.contains(card.rawValue) }
    public func setVisible(_ card: Card, _ visible: Bool) {
        if visible { hiddenCards.remove(card.rawValue) } else { hiddenCards.insert(card.rawValue) }
    }
    /// Card order (missing cards are appended)
    public var cardOrder: [String] {
        didSet { defaults.set(cardOrder, forKey: "cardOrder") }
    }
    public var orderedCards: [Card] {
        let list = cardOrder.compactMap(Card.init(rawValue:))
        return list + Card.allCases.filter { !list.contains($0) }
    }
    /// Swaps with the adjacent visible card (hidden cards are skipped)
    public func moveCard(_ card: Card, by offset: Int) {
        let visible = orderedCards.filter { isVisible($0) || $0 == card }
        guard let i = visible.firstIndex(of: card), visible.indices.contains(i + offset) else { return }
        moveCard(card, to: visible[i + offset])
    }
    /// Moves a card to another card's position (drag reordering)
    public func moveCard(_ card: Card, to target: Card) {
        var list = orderedCards
        guard let from = list.firstIndex(of: card), let to = list.firstIndex(of: target), from != to else { return }
        list.remove(at: from)
        list.insert(card, at: to)
        cardOrder = list.map(\.rawValue)
    }

    /// Accent colour per card (and stat tile): a preset name or "#rrggbb"; the card's default if absent
    public var cardAccents: [String: String] {
        didSet { defaults.set(cardAccents, forKey: "cardAccents") }
    }


    /// 1D bar chart granularity (minutes): 30 or 60
    public var intradayMinutes: Int {
        didSet { defaults.set(intradayMinutes, forKey: "intradayMinutes") }
    }
    /// Usage chart stacking: "model" / "tool" / "none"
    public var usageStack: String {
        didSet { defaults.set(usageStack, forKey: "usageStack") }
    }
    /// Compatibility with the old UI: stacked by tool
    public var usageByTool: Bool { usageStack == "tool" }
    /// Draw the range's daily-average line on the usage chart
    public var usageShowAverage: Bool {
        didSet { defaults.set(usageShowAverage, forKey: "usageShowAverage") }
    }
    /// Days covered by the time-of-day chart: 7 / 30 / 90
    public var punchcardDays: Int {
        didSet { defaults.set(punchcardDays, forKey: "punchcardDays") }
    }
    /// Metric the calendar is coloured by
    public var calendarMetric: UsageMetric {
        didSet { defaults.set(calendarMetric.rawValue, forKey: "calendarMetric") }
    }
    /// Calendar weeks: 0 = follow the time range (26–53 weeks)
    public var calendarWeeks: Int {
        didSet { defaults.set(calendarWeeks, forKey: "calendarWeeks") }
    }
    /// Token breakdown period: "auto" (follow the time range) / "today" / "month" / "all"
    public var compositionPeriod: String {
        didSet { defaults.set(compositionPeriod, forKey: "compositionPeriod") }
    }
    public var compositionShowHitRate: Bool {
        didSet { defaults.set(compositionShowHitRate, forKey: "compositionShowHitRate") }
    }
    public var costShowLastMonth: Bool {
        didSet { defaults.set(costShowLastMonth, forKey: "costShowLastMonth") }
    }
    public var costShowProjection: Bool {
        didSet { defaults.set(costShowProjection, forKey: "costShowProjection") }
    }
    public var costShowDailyBars: Bool {
        didSet { defaults.set(costShowDailyBars, forKey: "costShowDailyBars") }
    }
    /// Show per-model extra limits on the limits card (e.g. Codex's GPT-5.3-Codex-Spark)
    public var limitShowModelBuckets: Bool {
        didSet { defaults.set(limitShowModelBuckets, forKey: "limitShowModelBuckets") }
    }
    /// Show a mini trend for each model on the models card
    public var modelsShowSparklines: Bool {
        didSet { defaults.set(modelsShowSparklines, forKey: "modelsShowSparklines") }
    }
    /// What the models card's shares are based on: tokens / cost
    public var modelsMetric: UsageMetric {
        didSet { defaults.set(modelsMetric.rawValue, forKey: "modelsMetric") }
    }

    public func resetCardOptions() {
        resetLayout()
        cardAccents = [:]
        intradayMinutes = 60
        usageStack = "model"
        usageShowAverage = true
        punchcardDays = 30
        calendarMetric = .tokens
        calendarWeeks = 0
        compositionPeriod = "auto"
        compositionShowHitRate = true
        costShowLastMonth = true
        costShowProjection = true
        costShowDailyBars = true
        limitShowModelBuckets = true
        limitShowPace = true
        hiddenLimitProviders = []
        modelsShowSparklines = true
        modelsMetric = .tokens
        heroShowPrevious = true
    }

    private init() {
        let d = UserDefaults.standard   // self is off limits until initialisation finishes
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        func set(_ key: String) -> Set<String> { Set(d.stringArray(forKey: key) ?? []) }
        func dict(_ key: String) -> [String: String] { d.dictionary(forKey: key) as? [String: String] ?? [:] }

        liveRefreshSeconds = int("liveRefreshSeconds", 30)
        fullRefreshMinutes = int("fullRefreshMinutes", 15)
        cardAccents = dict("cardAccents")
        // Widget grid (layout version 2): sizes are redefined in grid cells; old full-row / half-row sizes are dropped
        cardSizes = dict("widgetSizes")
        if d.integer(forKey: "layoutVersion") >= 2 {
            hiddenCards = set("hiddenCards")
            cardOrder = d.stringArray(forKey: "cardOrder") ?? Card.allCases.map(\.rawValue)
        } else {
            // The old all-in-one stat tiles card → one widget per stat: the chosen ones keep their order and position, the rest are hidden
            let chosen = (d.stringArray(forKey: "statTiles") ?? ["average", "peak", "active", "perMillion"])
                .compactMap { Card(rawValue: "stat." + $0) }
            let stats = chosen + Card.stats.filter { !chosen.contains($0) }
            var hidden = set("hiddenCards")
            let tilesHidden = hidden.remove("tiles") != nil
            for stat in Card.stats where tilesHidden || !chosen.contains(stat) { hidden.insert(stat.rawValue) }
            var order = d.stringArray(forKey: "cardOrder") ?? Card.allCases.filter { !$0.isStat }.map(\.rawValue)
            if !order.contains("hero") { order.insert("hero", at: 0) }
            let at = order.firstIndex(of: "tiles") ?? min(1, order.count)
            order.removeAll { $0 == "tiles" }
            order.insert(contentsOf: stats.map(\.rawValue), at: at)
            hiddenCards = hidden
            cardOrder = order
            d.set(Array(hidden), forKey: "hiddenCards")
            d.set(order, forKey: "cardOrder")
            d.set(2, forKey: "layoutVersion")
        }
        intradayMinutes = int("intradayMinutes", 60)
        // Old key usageByTool → the new three-way stacking
        usageStack = d.string(forKey: "usageStack") ?? (d.bool(forKey: "usageByTool") ? "tool" : "model")
        usageShowAverage = bool("usageShowAverage", true)
        punchcardDays = int("punchcardDays", 30)
        calendarMetric = UsageMetric(rawValue: string("calendarMetric", "")) ?? .tokens
        calendarWeeks = int("calendarWeeks", 0)
        compositionPeriod = string("compositionPeriod", "auto")
        compositionShowHitRate = bool("compositionShowHitRate", true)
        costShowLastMonth = bool("costShowLastMonth", true)
        costShowProjection = bool("costShowProjection", true)
        costShowDailyBars = bool("costShowDailyBars", true)
        limitShowModelBuckets = bool("limitShowModelBuckets", true)
        limitShowPace = bool("limitShowPace", true)
        hiddenLimitProviders = set("hiddenLimitProviders")
        modelsShowSparklines = bool("modelsShowSparklines", true)
        modelsMetric = UsageMetric(rawValue: string("modelsMetric", "")) ?? .tokens
        heroShowPrevious = bool("heroShowPrevious", true)
        floatingWindow = d.bool(forKey: "floatingWindow")
        clickOpensPanel = bool("clickOpensPanel", true)
        limitShowUsed = bool("limitShowUsed", true)
        alertThresholds = d.object(forKey: "alertThresholds") as? [Double] ?? [50, 80]
        limitNotifications = bool("limitNotifications", false)
        // Old single-choice display mode → the new multi-select items
        if let items = d.stringArray(forKey: "menuBarItems") {
            menuBarItems = items
        } else {
            let provider = d.string(forKey: "menuBarProvider") ?? "claude"
            switch d.string(forKey: "menuBarMode") ?? "sessionPercent" {
            case "weeklyPercent": menuBarItems = ["\(provider).weekly"]
            case "todayTokens": menuBarItems = ["today.tokens"]
            case "todayCost": menuBarItems = ["today.cost"]
            case "both": menuBarItems = ["\(provider).session", "today.tokens"]
            case "iconOnly": menuBarItems = []
            default: menuBarItems = ["\(provider).session"]
            }
        }
        menuBarStyle = string("menuBarStyle", "text")
        menuBarShowLabels = bool("menuBarShowLabels", false)
        menuBarAlertColor = bool("menuBarAlertColor", true)
        menuBarShowIcon = bool("menuBarShowIcon", true)
        panelSections = d.stringArray(forKey: "panelSections") ?? ["claude", "codex", "today", "models"]
        panelWidth = int("panelWidth", 340)
        panelLimitStyle = string("panelLimitStyle", "rings")
        panelListCount = int("panelListCount", 4)
        panelTodayStyle = string("panelTodayStyle", "cumulative")
        panelShowResets = bool("panelShowResets", true)
        range = TimeRange(rawValue: string("dashboardRange", "")) ?? .month
        metric = UsageMetric(rawValue: string("dashboardMetric", "")) ?? .tokens
        exactNumbers = d.bool(forKey: "statsExactNumber")
        modelColorMode = string("modelColorMode", "vendor")
        modelColorOverrides = dict("modelColorOverrides")
        toolColorOverrides = dict("toolColorOverrides")
        modelAliases = dict("modelAliases")
        excludedModels = set("excludedModels")
        excludedClients = set("excludedClients")
        separateModels = int("separateModels", 4)
    }
}
