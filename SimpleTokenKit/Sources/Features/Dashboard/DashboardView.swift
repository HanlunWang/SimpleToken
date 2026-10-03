import SwiftUI
import Core
import DesignSystem

/// Main window: one global time range drives every card. The report is computed once here and shared,
/// so numbers agree everywhere. Adapts to width: two columns when wide, one column with 2×2 stat tiles
/// when narrow. The top bar is pinned with a gradient frosted scrim below it; settings open as a page in
/// this window rather than a separate one.
public struct DashboardView: View {
    private let state: AppState
    @Bindable private var settings = SettingsStore.shared
    @State private var width: CGFloat = 960
    @State private var tip = HoverTip()
    /// Scroll position lives in its own observable: only the top-bar scrim and the hover-tip layer read it,
    /// so scrolling does not recompute the whole page (every card) each frame
    @State private var scroll = ScrollTracker()
    @State private var barHeight: CGFloat = 46
    @State private var drag = CardDrag()
    @State private var position = ScrollPosition()
    @State private var scrolling = false
    @State private var dragging = false
    @State private var showingCards = false

    public init(state: AppState) {
        self.state = state
    }

    private var wide: Bool { width >= 760 }
    private var compact: Bool { width < 520 }
    private var gutter: CGFloat { compact ? 12 : 20 }

    public var body: some View {
        ZStack(alignment: .top) {
            Group {
                if state.showingSettings {
                    SettingsPage(state: state, compact: compact, scroll: scroll)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .trailing).combined(with: .opacity)))
                } else {
                    dashboard
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            // Content starts below the top bar but can scroll underneath it
            .safeAreaPadding(.top, barHeight)
            // Gradient frost behind the top bar: solid at the top, clear at the bottom, no hard edge; hidden until
            // scrolled so it does not darken the tops of the cards.
            // Not safeAreaBar: on macOS it draws its own hard-edged bar background that cannot be turned off.
            TopBarScrim(scroll: scroll, settings: state.showingSettings)
                .frame(height: barHeight + 40)
                .ignoresSafeArea(edges: .top)
            topBar
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barHeight = $0 }
        }
        .background(AmbientBackground())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .preferredColorScheme(.dark)
        .environment(\.locale, Fmt.uiLocale)
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        let report = state.report(range: settings.range, metric: settings.metric)
        let colors = state.modelColors
        let columns = WidgetMetrics.columns(width: width - gutter * 2)
        let cards = settings.orderedCards.filter { settings.isVisible($0) }
        return ScrollView(.vertical) {
            VStack(spacing: 14) {
                WidgetGrid(columns: columns) {
                    ForEach(cards) { card in
                        let size = WidgetMetrics.effective(settings.size(card), columns: columns)
                        self.card(card, size: size, report: report, colors: colors)
                            .gridSpan(WidgetMetrics.span(size, columns: columns))
                    }
                }
                footer
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 18)
            .coordinateSpace(.named(HoverTip.space))
            .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(CardDrag.viewport)).origin }) { drag.contentOrigin = $0 }
            .overlay(alignment: .topLeading) { HoverTipLayer(tip: tip, scroll: scroll) }
            .animation(.smooth(duration: 0.4), value: settings.hiddenCards)
            .animation(.smooth(duration: 0.4), value: settings.cardOrder)
            .animation(.smooth(duration: 0.4), value: settings.cardSizes)
            .animation(.smooth(duration: 0.4), value: columns)
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .coordinateSpace(.named(CardDrag.viewport))
        // A dragged widget floats above the scroll view and follows the pointer
        .overlay(alignment: .topLeading) {
            FloatingCard(drag: drag) { card in
                let size = WidgetMetrics.effective(settings.size(card), columns: columns)
                cardContent(card, size: size, report: report, colors: colors)
                    .environment(\.cardSize, size)
            }
        }
        .onScrollGeometryChange(for: [CGFloat].self, of: {
            [$0.contentOffset.y, $0.contentInsets.top, $0.contentSize.height - $0.containerSize.height + $0.contentInsets.bottom, $0.containerSize.height]
        }) { _, v in
            scroll.dashboardTop = v[0] + v[1]
            drag.scrollY = v[0]
            drag.topInset = v[1]
            drag.maxScrollY = max(-v[1], v[2])
            drag.viewportHeight = v[3]
        }
        // No hover readouts while scrolling or dragging: content moving under the pointer would keep triggering hovers and redraws
        .onScrollPhaseChange { _, phase in
            scrolling = phase != .idle
            updateHoverSuspension()
        }
        .onAppear {
            drag.scrollTo = { y in position.scrollTo(y: y) }
            drag.onActiveChange = { active in
                dragging = active
                updateHoverSuspension()
            }
        }
        // Dismiss hover tips when the range / metric changes (their content no longer applies)
        .onChange(of: settings.range) { tip.hideAll() }
        .onChange(of: settings.metric) { tip.hideAll() }
        .environment(tip)
    }

    private func updateHoverSuspension() {
        tip.scrolling = scrolling || dragging
        if tip.scrolling { tip.hideAll() }
    }

    private func card(_ card: SettingsStore.Card, size: SettingsStore.CardSize, report: RangeReport, colors: ModelColors) -> some View {
        DraggableCard(card: card, drag: drag) {
            cardContent(card, size: size, report: report, colors: colors)
        }
        .environment(\.dashboardCard, card)
        .environment(\.cardSize, size)
        .modifier(CardContextMenu(card: card))
    }

    @ViewBuilder
    private func cardContent(_ card: SettingsStore.Card, size: SettingsStore.CardSize, report: RangeReport, colors: ModelColors) -> some View {
        let exact = settings.exactNumbers
        switch card {
        case .hero:
            HeroCard(report: report, todayHalfHours: state.todayHalfHours, compact: size != .wide, settings: settings, colors: colors)
        case .limits:
            LimitsCard(limits: state.limits, colors: colors, settings: settings)
        case .models:
            ModelsCard(report: report, colors: colors, exact: exact, settings: settings)
        case .map:
            MapCard(state: state, report: report, colors: colors, exact: exact, settings: settings)
        case .flow:
            FlowCard(state: state, report: report, colors: colors, exact: exact, settings: settings)
        case .usage:
            UsageBarsCard(state: state, report: report, colors: colors, exact: exact, settings: settings)
        case .calendar:
            CalendarCard(history: state.history.daily, liveToday: state.liveToday, rangeDays: report.days.count,
                         colors: colors, exact: exact, settings: settings)
        case .punchcard:
            PunchcardCard(card: state.punchcard(days: settings.punchcardDays), colors: colors, exact: exact, settings: settings)
        case .tools:
            ToolsCard(report: report, catalog: state.history.catalog.clients, colors: colors, exact: exact, settings: settings)
        case .composition:
            CompositionCard(state: state, range: settings.range, colors: colors, exact: exact, settings: settings)
        case .cost:
            CostCard(month: state.monthCost, colors: colors, summary: state.daySummary, settings: settings)
        default:
            if let kind = card.statKey.flatMap(StatKind.init(rawValue:)) {
                // Stat tiles say little at 1D (a single day), so they show the last week instead
                StatTile(kind: kind, report: settings.range == .day ? state.report(range: .week, metric: settings.metric) : report,
                         colors: colors, exact: exact, settings: settings)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        Group {
            if state.showingSettings {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { state.showingSettings = false }
                    } label: {
                        Label("Usage", systemImage: "chevron.left").font(.app(Typo.body, .medium))
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    // Tabs: a segmented control when it fits, otherwise a menu
                    ViewThatFits(in: .horizontal) {
                        GlassSegmented(SettingsTab.allCases.map { ($0.rawValue, $0.localizedName) }, selection: settingsTab, fontSize: Typo.body)
                        Picker("", selection: settingsTab) {
                            ForEach(SettingsTab.allCases) { Text($0.localizedName).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        BrandTitle(state: state)
                        Spacer(minLength: 12)
                        RefreshControl(state: state)
                        rangePicker
                        layoutButton
                        settingsButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            BrandTitle(state: state)
                            Spacer(minLength: 8)
                            RefreshControl(state: state)
                            layoutButton
                            settingsButton
                        }
                        rangePicker
                    }
                }
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var settingsTab: Binding<String> {
        Binding(get: { state.settingsTabKey }, set: { state.settingsTabKey = $0 })
    }

    private var rangePicker: some View {
        GlassSegmented(TimeRange.allCases.map { ($0, $0.rawValue) }, selection: $settings.range, fontSize: Typo.body)
    }

    private var layoutButton: some View {
        Button { showingCards.toggle() } label: {
            Image(systemName: "square.grid.2x2")
                .font(.app(Typo.body + 1, .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .help("Widgets: show / hide and size. Drag to reposition")
        .popover(isPresented: $showingCards, arrowEdge: .bottom) { CardsPopover() }
    }

    private var settingsButton: some View {
        Button {
            state.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.app(Typo.body + 1, .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .help("Settings (⌘,)")
    }

    private var footer: some View {
        HStack {
            Text(footerText).font(.app(Typo.small)).foregroundStyle(.tertiary)
            Spacer()
            let hidden = SettingsStore.Card.allCases.filter { !settings.isVisible($0) }.count
            if hidden > 0 {
                Button("Add widgets (\(hidden) hidden)") { showingCards = true }
                    .buttonStyle(.plain)
                    .font(.app(Typo.small))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var footerText: String {
        var text = L("Data from this Mac · Drag a widget to move it, right-click to resize")
        if !settings.usageFilter.isEmpty { text += " · " + L("\(settings.excludedModels.count + settings.excludedClients.count) excluded") }
        if state.history.importedFromLegacy { text += " · " + L("Token Monitor history merged") }
        return text
    }
}

/// Brand title: the only view observing "collecting", so collection starting / stopping does not recompute the page
struct BrandTitle: View {
    let state: AppState
    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: 17, lit: state.usage.isCollecting)
            Text("Usage").font(.app(Typo.title + 1, .semibold)).fixedSize()
        }
    }
}

/// Refresh: time of the last update (relative, ticks every 30 s) + manual refresh (⌘R). Hover shows each source's refresh interval.
struct RefreshControl: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let refreshing = state.isRefreshing
        Button {
            state.refreshAll()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.app(Typo.small, .semibold))
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: refreshing)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(label(now: context.date, refreshing: refreshing))
                        .font(.app(Typo.small)).monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .keyboardShortcut("r", modifiers: .command)
        .help(Self.frequencyHelp(settings))
        .animation(.smooth(duration: 0.3), value: refreshing)
    }

    private func label(now: Date, refreshing: Bool) -> String {
        if refreshing { return L("Refreshing") }
        guard let at = state.usage.snapshot?.collectedAt else { return L("Not collected yet") }
        let s = Int(now.timeIntervalSince(at))
        if s < 60 { return L("Just updated") }
        if s < 3600 { return L("Updated \(s / 60) min ago") }
        return L("Updated \(Fmt.clock(at))")
    }

    static func frequencyHelp(_ settings: SettingsStore) -> String {
        [
            L("Click to refresh all data now (⌘R)"),
            L("Today's usage: refreshed when logs change, at most every \(Fmt.seconds(settings.liveRefreshSeconds))"),
            L("Full rescan (this month / all time): every \(settings.fullRefreshMinutes) min"),
            L("Daily history: every 15 min"),
            L("Limits: every 5 min (plus once 30 s after a window resets)"),
            L("Intraday data: every minute"),
            L("Live refresh pauses while the window and panel are closed and catches up when opened"),
        ].joined(separator: "\n")
    }
}

/// Scroll position (top of the visible area in content coordinates)
@Observable
@MainActor
final class ScrollTracker {
    var dashboardTop: CGFloat = 0
    var settingsTop: CGFloat = 0
}

/// Scrim behind the top bar: a material masked by a linear gradient (solid at the top, clear below) plus a
/// matching ground-colour gradient, so content scrolling up gradually blurs and darkens with no hard edge.
struct TopBarScrim: View {
    let scroll: ScrollTracker
    let settings: Bool

    var body: some View {
        let top = settings ? scroll.settingsTop : scroll.dashboardTop
        scrim.opacity(min(1, max(0, top / 18)))
    }

    private var scrim: some View {
        // Height = title bar + top bar + a 40 pt fade; the top-bar area is nearly opaque and fades out only in the bottom 40 pt
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.6),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            LinearGradient(stops: [
                .init(color: Palette.ground.opacity(0.94), location: 0),
                .init(color: Palette.ground.opacity(0.86), location: 0.6),
                .init(color: Palette.ground.opacity(0.4), location: 0.82),
                .init(color: Palette.ground.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
