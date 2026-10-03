import SwiftUI
import Core
import DesignSystem

/// Drop-down panel: the same language as the main window, a dark ground with small glass cards.
/// Sections, order, width and limit style are set in Settings → Panel; the content scrolls when taller than the screen.
/// Charts come from ChartKit; hover readouts are drawn by a `HoverTipLayer` over the whole panel, so a tip can
/// cross card edges the way it does on the dashboard.
public struct QuickPanelView: View {
    let state: AppState
    /// Maximum panel height (usable screen height minus margins; anything beyond scrolls)
    var maxHeight: CGFloat
    /// Called when the panel size changes (the controller resizes the window and keeps its top edge at the menu bar)
    var onSize: ((CGSize) -> Void)?
    @Bindable private var settings = SettingsStore.shared
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var tip = HoverTip()
    /// The tip layer reads the top of the visible area from here; the panel rarely scrolls, so it stays at zero
    @State private var scroll = ScrollTracker()

    public init(state: AppState, maxHeight: CGFloat = 900, onSize: ((CGSize) -> Void)? = nil) {
        self.state = state
        self.maxHeight = maxHeight
        self.onSize = onSize
    }

    public var body: some View {
        let limit = max(200, maxHeight - headerHeight)
        VStack(spacing: 0) {
            PanelHeader(state: state)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            if bodyHeight > limit {
                ScrollView(.vertical) { sections }
                    .scrollIndicators(.automatic)
                    .frame(height: limit)
                    // Hover is ignored mid-scroll, as on the dashboard
                    .onScrollPhaseChange { _, phase in
                        tip.scrolling = phase != .idle
                        if phase != .idle { tip.hideAll() }
                    }
            } else {
                sections
            }
        }
        .coordinateSpace(.named(HoverTip.space))
        .overlay(alignment: .topLeading) { HoverTipLayer(tip: tip, scroll: scroll) }
        .environment(tip)
        .frame(width: CGFloat(settings.panelWidth))
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1)
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { onSize?($0) }
        .preferredColorScheme(.dark)
        .environment(\.locale, Fmt.uiLocale)
    }

    private var sections: some View {
        let list = settings.panelSections.compactMap(SettingsStore.PanelSection.init(rawValue:))
        let colors = state.modelColors
        return GlassEffectContainer(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(list) { section in
                    switch section {
                    case .claude: PanelLimits(provider: .claude, snapshot: state.limits.claude, status: state.limits.claudeStatus, colors: colors)
                    case .codex: PanelLimits(provider: .codex, snapshot: state.limits.codex, status: state.limits.codexStatus, colors: colors)
                    case .today: PanelToday(state: state)
                    case .models: PanelModels(period: state.period(\.today), colors: colors)
                    case .tools: PanelTools(period: state.period(\.today), colors: colors)
                    case .week: PanelWeek(state: state)
                    case .month: PanelMonth(month: state.monthCost)
                    }
                }
                if list.isEmpty {
                    Text("Choose what to show in Settings → Panel")
                        .font(.app(Typo.body)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
    }
}

// MARK: - Frame

/// Panel ground: a translucent black deeper than the main window (a hint of desktop colour shows through) + a soft light at the top left
private struct PanelBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect)
            Palette.ground.opacity(0.86)
            RadialGradient(colors: [.white.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.12, y: -0.06), startRadius: 0, endRadius: 320)
        }
    }
}

/// Section card: the same glass as the dashboard cards
private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// Section title: title on the left, note on the right
private struct PanelTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.app(Typo.body, .semibold)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 6)
            trailing
                .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}

/// Font size of a section's main number (the panel is narrow: smaller than the dashboard's small widget)
private let panelNumber: CGFloat = 24

/// A tip with a title and a headline value and nothing under them (a point on a sparkline)
private struct PlainTip: View {
    let title: String
    var subtitle: String?
    let value: String

    var body: some View {
        TipCard(title: title, subtitle: subtitle, value: value) { EmptyView() }
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: 17, lit: state.usage.isCollecting)
            VStack(alignment: .leading, spacing: 0) {
                Text("SimpleToken").font(.app(Typo.title + 1, .semibold))
                Text(Self.dateLine()).font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
            .fixedSize()
            Spacer(minLength: 6)
            PanelRefresh(state: state)
            PanelIconButton(icon: "macwindow", help: L("Open Main Window")) { state.openMainWindow?() }
            PanelIconButton(icon: "gearshape", help: L("Settings")) { state.openSettings() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private static func dateLine() -> String {
        "\(Fmt.shortDate(Fmt.dayKey())) \(Fmt.weekday(Date()))"
    }
}

/// Refresh: last update (relative time) + click to refresh now
private struct PanelRefresh: View {
    let state: AppState

    var body: some View {
        let refreshing = state.isRefreshing
        Button { state.refreshAll() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.app(Typo.axis, .bold))
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: refreshing)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(label(now: context.date, refreshing: refreshing)).font(.app(Typo.small)).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(RefreshControl.frequencyHelp(SettingsStore.shared))
    }

    private func label(now: Date, refreshing: Bool) -> String {
        if refreshing { return L("Refreshing") }
        guard let at = state.usage.snapshot?.collectedAt else { return L("Not collected yet") }
        let s = Int(now.timeIntervalSince(at))
        if s < 60 { return L("Just now") }
        if s < 3600 { return L("\(s / 60) min ago") }
        return Fmt.clock(at)
    }
}

private struct PanelIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.app(Typo.body, .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Limits

/// One provider's limit windows: a row per window (bars) or a small dial per window (rings). The window's
/// colour is the provider's until it nears the limit: warning from 75 % used, critical from the alert threshold.
private struct PanelLimits: View {
    let provider: LimitProvider
    let snapshot: ProviderLimits?
    let status: LimitsStore.Status
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    /// Used share from which a window wears the warning colour
    private static let warningPercent: Double = 75

    var body: some View {
        let accent = colors.toolColor(provider.rawValue)
        PanelCard {
            HStack(spacing: 7) {
                BrandBadge(logo: BrandLogos.provider(provider.rawValue), color: accent, size: 18)
                Text(provider.displayName).font(.app(Typo.body + 1, .semibold))
                if let label = snapshot?.accountLabel, !label.isEmpty {
                    Text(label).font(.system(size: Typo.small, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(statusText).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let snapshot {
                let windows = Array(snapshot.windows.filter { $0.kind != .model }.prefix(3))
                if settings.panelLimitStyle == "bars" {
                    VStack(spacing: 7) {
                        ForEach(windows) { w in row(w, accent) }
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(windows) { w in dial(w, accent) }
                    }
                }
            } else {
                Text(placeholder).font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    /// What a window draws: the shown share (used or left), the even-pace tick, the projection and the colour
    private struct Reading {
        var fraction: Double
        var pace: Double?
        var projected: Double?
        var color: Color
        var percent: String { "\(Int((fraction * 100).rounded()))%" }
    }

    private func reading(_ w: LimitWindow, _ accent: Color) -> Reading {
        let used = w.usedPercent / 100
        let showUsed = settings.limitShowUsed
        let elapsed = w.elapsedFraction()
        // Where the window is heading by its reset at the current pace; not read into a window that has barely started
        var projected: Double?
        if showUsed, used > 0, let elapsed, elapsed > 0.05 {
            projected = min(1, used / max(elapsed, 0.02))
        }
        return Reading(fraction: showUsed ? used : 1 - used,
                     pace: settings.limitShowPace ? elapsed.map { showUsed ? $0 : 1 - $0 } : nil,
                     projected: projected,
                     color: tint(usedPercent: w.usedPercent, accent: accent))
    }

    /// The provider's colour, the warning colour from 75 % used, the critical colour from the highest alert threshold
    private func tint(usedPercent: Double, accent: Color) -> Color {
        let critical = max(Self.warningPercent, settings.alertThresholds.max() ?? 90)
        if usedPercent >= critical { return Palette.critical }
        if usedPercent >= Self.warningPercent { return Palette.warning }
        return accent
    }

    /// Bars: chip · name · pace bar · percent · reset countdown
    private func row(_ w: LimitWindow, _ accent: Color) -> some View {
        let g = reading(w, accent)
        return HStack(spacing: 8) {
            EntityMark(logo: BrandLogos.provider(provider.rawValue), color: g.color, size: 13)
            Text(LimitsCard.label(w)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: Fmt.usesCJKUnits ? 30 : 42, alignment: .leading)
            PaceBar(fraction: g.fraction, pace: g.pace, projected: g.projected, tint: g.color, height: 5)
                .frame(maxWidth: .infinity)
            Text(g.percent).font(.num(Typo.body + 1, .semibold))
                .foregroundStyle(w.usedPercent >= Self.warningPercent ? g.color : .primary)
                .monospacedDigit().contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 36, alignment: .trailing)
            if settings.panelShowResets {
                reset(w).frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// Rings: a three-quarter dial per window, the percent inside, name and countdown beneath
    private func dial(_ w: LimitWindow, _ accent: Color) -> some View {
        let g = reading(w, accent)
        return VStack(spacing: 3) {
            LimitGauge(fraction: g.fraction, projected: g.projected, elapsed: g.pace, accent: g.color, lineWidth: 5) {
                Text(g.percent).font(.num(12, .semibold))
                    .foregroundStyle(w.usedPercent >= Self.warningPercent ? g.color : .primary)
                    .monospacedDigit().contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 34)
            }
            .frame(width: 54, height: 54)
            Text(LimitsCard.label(w)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if settings.panelShowResets {
                reset(w)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Time to the reset ("2h13m"); the exact moment is in the help
    private func reset(_ w: LimitWindow) -> some View {
        Text(w.resetsAt.map { MenuBarContent.countdown(to: $0, now: Date()) } ?? " ")
            .font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .help(w.resetsAt.map { L("Resets \(LimitsCard.resetFormatter($0))") } ?? "")
    }

    private var statusText: String {
        switch status {
        case .probing: L("Refreshing")
        case .failed: snapshot == nil ? "" : L("Unreachable")
        default: snapshot.map { LimitsCard.ago($0.updatedAt) } ?? ""
        }
    }

    private var placeholder: String {
        switch status {
        case .notConfigured: L("Not set up")
        case .failed(let reason): L("Unreachable · \(reason)")
        default: L("Reading limits…")
        }
    }
}

// MARK: - Today

/// Today's total against the same time yesterday, with the day's trend so far (a cumulative line or half-hour bars)
private struct PanelToday: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let period = state.period(\.today)
        let total = Double(period?.totalTokens ?? 0)
        let cal = Calendar.current
        let now = Date()
        let nowSlot = cal.component(.hour, from: now) * 2 + (cal.component(.minute, from: now) >= 30 ? 1 : 0)
        let today = state.todayHalfHours
        let buckets = Array(today.prefix(nowSlot + 1))
        let raw = Double(buckets.reduce(0, +))
        // Intraday data is Claude Code only: scale it to today's total so the shape is right and the end matches the total
        let scale = raw > 0 ? total / raw : 0
        let yesterday = state.halfHours(Fmt.dayKey(now.addingTimeInterval(-86400)))
        let ySoFar = Double(yesterday.prefix(nowSlot + 1).reduce(0, +))
        let exact = settings.exactNumbers

        PanelCard {
            PanelTitle(title: L("Today")) {
                if ySoFar > 0, raw > 0 {
                    HStack(spacing: 5) {
                        DeltaChip(percent: (raw / ySoFar - 1) * 100)
                        Text("vs. this time yesterday")
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                figures(period, total: total, exact: exact, showMessages: true)
                figures(period, total: total, exact: exact, showMessages: false)
            }
            trend(buckets: buckets, scale: scale, nowSlot: nowSlot, exact: exact)
                .frame(height: 50)
            HStack {
                Text("0h"); Spacer(); Text(verbatim: "6"); Spacer(); Text(verbatim: "12"); Spacer(); Text(verbatim: "18"); Spacer(); Text("24h")
            }
            .font(.app(Typo.axis)).foregroundStyle(.tertiary)
        }
    }

    private func figures(_ period: UsagePeriod?, total: Double, exact: Bool, showMessages: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BigNumber(Fmt.tokens(total, exact: exact), size: panelNumber, value: total)
            MoneyNumber(period?.costUsd ?? 0, size: 15, color: .secondary)
            if showMessages {
                Text(Fmt.metric(Double(period?.messages ?? 0), .messages, exact: true))
                    .font(.num(Typo.body, .medium)).foregroundStyle(.tertiary).monospacedDigit().fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func trend(buckets: [Int], scale: Double, nowSlot: Int, exact: Bool) -> some View {
        if settings.panelTodayStyle == "bars" {
            // Every half hour of the day; the hours still to come are the faint ticks on the right
            let values = (0..<48).map { i in buckets.indices.contains(i) ? Double(buckets[i]) * scale : 0 }
            SparkBars(values: values, color: Palette.usage, tipID: "panel.today") { i in
                AnyView(PlainTip(title: Self.slotRange(i), value: Fmt.tokens(values[i], exact: exact)))
            }
        } else {
            // The total adding up through the day; the line ends where the day is now
            let points = Self.cumulative(buckets, scale)
            GeometryReader { geo in
                SparkLine(values: points, color: Palette.usage, tipID: "panel.today") { i in
                    AnyView(PlainTip(title: L("By \(Self.slotEnd(i))"), value: Fmt.tokens(points[i], exact: exact)))
                }
                .frame(width: max(12, geo.size.width * CGFloat(nowSlot + 1) / 48), height: geo.size.height)
            }
        }
    }

    private static func cumulative(_ buckets: [Int], _ scale: Double) -> [Double] {
        var acc = 0.0
        return buckets.map { acc += Double($0) * scale; return acc }
    }

    /// "09:30" for the end of half hour `i`
    private static func slotEnd(_ i: Int) -> String {
        let end = (i + 1) * 30
        return String(format: "%02d:%02d", end / 60 % 24, end % 60)
    }

    /// "09:00–09:30" for half hour `i`
    private static func slotRange(_ i: Int) -> String {
        let start = i * 30
        return String(format: "%02d:%02d–", start / 60, start % 60) + slotEnd(i)
    }
}

// MARK: - Models / tools

/// Today's models: share at a glance, then the top rows with a bar against the biggest
private struct PanelModels: View {
    let period: UsagePeriod?
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let byModel = (period?.byModel ?? [:]).filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens }
        let total = Double(max(1, byModel.reduce(0) { $0 + $1.value.tokens }))
        let top = Double(max(1, byModel.first?.value.tokens ?? 1))
        let exact = settings.exactNumbers
        PanelCard {
            PanelTitle(title: L("Today’s models")) { Text(byModel.isEmpty ? "" : L("\(byModel.count) models")) }
            if byModel.isEmpty {
                Text("No usage yet today").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                SegmentBar(parts: byModel.map { (key: $0.key, value: Double($0.value.tokens), color: colors.color($0.key)) },
                           height: 6, tipID: "panel.models") { key in
                    let slice = byModel.first { $0.key == key }?.value ?? .init()
                    return AnyView(SliceTip(name: colors.name(key), color: colors.color(key), slice: slice, share: Double(slice.tokens) / total, exact: exact))
                }
                VStack(spacing: 6) {
                    ForEach(byModel.prefix(settings.panelListCount), id: \.key) { m, slice in
                        PanelRow(logo: BrandLogos.model(m), color: colors.color(m), name: colors.name(m), monospaced: true,
                                 value: Fmt.tokens(Double(slice.tokens), exact: false),
                                 fraction: Double(slice.tokens) / top, share: Double(slice.tokens) / total)
                    }
                }
            }
        }
    }
}

/// Today's tools: the same anatomy, with each tool's cost when the row is wide enough
private struct PanelTools: View {
    let period: UsagePeriod?
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let byClient = (period?.byClient ?? [:]).filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens }
        let total = Double(max(1, byClient.reduce(0) { $0 + $1.value.tokens }))
        let top = Double(max(1, byClient.first?.value.tokens ?? 1))
        let exact = settings.exactNumbers
        PanelCard {
            PanelTitle(title: L("Today’s tools")) { Text(byClient.isEmpty ? "" : Fmt.money(byClient.reduce(0) { $0 + $1.value.costUsd })) }
            if byClient.isEmpty {
                Text("No usage yet today").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                SegmentBar(parts: byClient.map { (key: $0.key, value: Double($0.value.tokens), color: colors.toolColor($0.key)) },
                           height: 6, tipID: "panel.tools") { key in
                    let slice = byClient.first { $0.key == key }?.value ?? .init()
                    return AnyView(SliceTip(name: ModelPalette.toolLabel(key), color: colors.toolColor(key), slice: slice, share: Double(slice.tokens) / total, exact: exact))
                }
                VStack(spacing: 6) {
                    ForEach(byClient.prefix(settings.panelListCount), id: \.key) { c, slice in
                        PanelRow(logo: BrandLogos.tool(c), color: colors.toolColor(c), name: ModelPalette.toolLabel(c), monospaced: false,
                                 value: Fmt.tokens(Double(slice.tokens), exact: false),
                                 fraction: Double(slice.tokens) / top, share: Double(slice.tokens) / total, detail: Fmt.money(slice.costUsd))
                    }
                }
            }
        }
    }
}

/// Hover readout for one model / tool segment: tokens, cost, messages and its share of today
private struct SliceTip: View {
    let name: String
    let color: Color
    let slice: UsagePeriod.Slice
    let share: Double
    let exact: Bool

    var body: some View {
        TipCard(title: name, subtitle: L("\(percent(share)) of today"), value: Fmt.tokens(Double(slice.tokens), exact: exact)) {
            TipRow(color: color, label: L("Cost"), value: Fmt.money(slice.costUsd))
            TipRow(label: L("Messages"), value: Fmt.metric(Double(slice.messages), .messages, exact: true))
        }
    }
}

/// List row: mark + name + (cost) + bar against the biggest row + value + percentage of the whole.
/// The cost is dropped first when the row is too narrow for it.
private struct PanelRow: View {
    let logo: String?
    let color: Color
    let name: String
    let monospaced: Bool
    let value: String
    /// Against the biggest row (the bar)
    let fraction: Double
    /// Of the whole (the percentage)
    let share: Double
    var detail: String?

    var body: some View {
        if detail != nil {
            ViewThatFits(in: .horizontal) {
                row(detail)
                row(nil)
            }
        } else {
            row(nil)
        }
    }

    private func row(_ detail: String?) -> some View {
        HStack(spacing: 7) {
            EntityMark(logo: logo, color: color, size: 13)
            Text(name)
                .font(monospaced ? .system(size: Typo.body, design: .monospaced) : .app(Typo.body))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let detail {
                Text(detail).font(.num(Typo.small, .regular)).foregroundStyle(.tertiary).fixedSize()
            }
            DepthBar(fraction: fraction, tint: color, height: 4)
                .frame(width: 44)
            Text(value).font(.num(Typo.small, .medium)).foregroundStyle(.secondary).fixedSize()
            Text(percent(share)).font(.num(Typo.small, .regular)).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

// MARK: - Last 7 days

/// The week as small bars against its daily average; today is the strong one
private struct PanelWeek: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let days = (0..<7).reversed().map { offset -> DailyHistoryArchive.DaySummary in
            state.daySummary(Fmt.dayKey(Date().addingTimeInterval(-Double(offset) * 86400)))
        }
        let values = days.map { Double($0.tokens) }
        let total = values.reduce(0, +)
        let exact = settings.exactNumbers
        PanelCard {
            PanelTitle(title: L("Last 7 days")) {
                Text("Total \(Fmt.tokens(total, exact: false)) · \(Fmt.tokens(total / 7, exact: false))/day")
            }
            SparkBars(values: values, color: Palette.usage, emphasis: days.indices.map { $0 == 6 ? 1 : 0.7 },
                      rule: total / 7, tipID: "panel.week") { i in
                AnyView(DayTip(day: days[i], exact: exact))
            }
            .frame(height: 46)
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { i in
                    Text(Self.initial(days[i].date))
                        .font(.app(Typo.axis, i == 6 ? .semibold : .regular))
                        .foregroundStyle(i == 6 ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The weekday's initial for a day key
    private static func initial(_ dayKey: String) -> String {
        let weekday = Calendar.current.component(.weekday, from: RangeAnalytics.date(dayKey))
        return Fmt.weekdayInitialsFromMonday[(weekday + 5) % 7]
    }
}

/// Hover readout for one day: tokens, cost and messages
private struct DayTip: View {
    let day: DailyHistoryArchive.DaySummary
    let exact: Bool

    var body: some View {
        TipCard(title: DayDetailTip.dateTitle(day.date), value: Fmt.tokens(Double(day.tokens), exact: exact)) {
            if day.tokens == 0 {
                Text("No usage this day").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                TipRow(label: L("Cost"), value: Fmt.money(day.cost))
                TipRow(label: L("Messages"), value: Fmt.metric(Double(day.messages), .messages, exact: true))
            }
        }
    }
}

// MARK: - Month cost

/// Month to date with the projection beside it; one small bar per day of the month, days to come left empty
private struct PanelMonth: View {
    let month: RangeAnalytics.MonthCost

    var body: some View {
        let spent = month.days.last?.cumulative ?? 0
        let daily = month.days.map(\.cost)
        let slots = daily + Array(repeating: 0, count: max(0, month.daysInMonth - daily.count))
        PanelCard {
            PanelTitle(title: L("This month’s cost")) {
                if month.lastMonthTotal > 0 { Text("Last month \(Fmt.money(month.lastMonthTotal))") }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MoneyNumber(spent, size: panelNumber)
                if month.projected > spent {
                    Text("Projected \(Fmt.money(month.projected))").font(.app(Typo.small)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            SparkBars(values: slots, color: Palette.usage, rule: daily.isEmpty ? nil : spent / Double(daily.count), tipID: "panel.month") { i in
                guard i < daily.count else { return AnyView(EmptyView()) }
                return AnyView(TipCard(title: Fmt.longDate(month.days[i].date), value: Fmt.money(daily[i])) {
                    TipRow(label: L("This month"), value: Fmt.money(month.days[i].cumulative))
                })
            }
            .frame(height: 40)
        }
    }
}
