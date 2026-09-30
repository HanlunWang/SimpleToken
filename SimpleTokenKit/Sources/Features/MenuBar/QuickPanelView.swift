import SwiftUI
import Charts
import Core
import DesignSystem

/// Drop-down panel: the same language as the main window, a dark ground with small glass cards.
/// Sections, order, width and limit style are set in Settings → Panel; the content scrolls when taller than the screen.
public struct QuickPanelView: View {
    let state: AppState
    /// Maximum panel height (usable screen height minus margins; anything beyond scrolls)
    var maxHeight: CGFloat
    /// Called when the panel size changes (the controller resizes the window and keeps its top edge at the menu bar)
    var onSize: ((CGSize) -> Void)?
    @Bindable private var settings = SettingsStore.shared
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

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
            } else {
                sections
            }
        }
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

/// Section title: title on the left, note on the right (hover readouts show here too)
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

private struct PanelLimits: View {
    let provider: LimitProvider
    let snapshot: ProviderLimits?
    let status: LimitsStore.Status
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let color = colors.toolColor(provider.rawValue)
        PanelCard {
            HStack(spacing: 7) {
                BrandBadge(logo: BrandLogos.provider(provider.rawValue), color: color, size: 18)
                Text(provider.displayName).font(.app(Typo.body + 1, .semibold))
                if let label = snapshot?.accountLabel, !label.isEmpty {
                    Text(label).font(.system(size: Typo.small, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(statusText).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let snapshot {
                let windows = snapshot.windows.filter { $0.kind != .model }.prefix(3)
                if settings.panelLimitStyle == "bars" {
                    VStack(spacing: 6) {
                        ForEach(Array(windows)) { w in bar(w, color) }
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(windows)) { w in ring(w, color) }
                    }
                }
            } else {
                Text(placeholder).font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    private func ring(_ w: LimitWindow, _ color: Color) -> some View {
        VStack(spacing: 3) {
            LimitRing(window: w, color: color, size: 54, lineWidth: 5, showUsed: settings.limitShowUsed)
            Text(LimitsCard.label(w)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
            if settings.panelShowResets {
                Text(w.resetsAt.map(LimitsCard.resetFormatter) ?? " ")
                    .font(.app(Typo.axis)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(_ w: LimitWindow, _ color: Color) -> some View {
        let shown = settings.limitShowUsed ? w.usedPercent : w.remainingPercent
        return HStack(spacing: 8) {
            Text(LimitsCard.label(w)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            LimitBar(window: w, color: color, showUsed: settings.limitShowUsed, showPace: settings.limitShowPace)
            Text("\(Int(shown.rounded()))%").font(.app(Typo.body, .semibold)).monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            if settings.panelShowResets {
                Text(w.resetsAt.map(LimitsCard.resetFormatter) ?? "")
                    .font(.app(Typo.axis)).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
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

private struct PanelToday: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared
    @State private var hovered: Int?

    var body: some View {
        let period = state.period(\.today)
        let total = Double(period?.totalTokens ?? 0)
        let cal = Calendar.current
        let now = Date()
        let nowSlot = cal.component(.hour, from: now) * 2 + (cal.component(.minute, from: now) >= 30 ? 1 : 0)
        let today = state.todayHalfHours
        let buckets = Array(today.prefix(nowSlot + 1))
        let raw = Double(buckets.reduce(0, +))
        // Intraday data is Claude Code only: scale it to today’s total so the shape is right and the end matches the total
        let scale = raw > 0 ? total / raw : 0
        let yesterday = state.halfHours(Fmt.dayKey(now.addingTimeInterval(-86400)))
        let ySoFar = Double(yesterday.prefix(nowSlot + 1).reduce(0, +))

        PanelCard {
            PanelTitle(title: L("Today")) {
                if let hovered {
                    Text(hoverText(hovered, buckets: buckets, scale: scale))
                } else if ySoFar > 0, raw > 0 {
                    let delta = raw / ySoFar - 1
                    HStack(spacing: 3) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.app(Typo.axis, .bold))
                        let change = "\(delta >= 0 ? "+" : "")\(Int((delta * 100).rounded()))%"
                        Text("\(change) vs. this time yesterday")
                    }
                    .foregroundStyle(delta >= 0 ? Palette.up : Palette.down)
                }
            }
            ViewThatFits(in: .horizontal) {
                figures(period, total: total, showMessages: true)
                figures(period, total: total, showMessages: false)
            }
            chart(buckets: buckets, scale: scale, nowSlot: nowSlot)
            HStack {
                Text("0h"); Spacer(); Text(verbatim: "6"); Spacer(); Text(verbatim: "12"); Spacer(); Text(verbatim: "18"); Spacer(); Text("24h")
            }
            .font(.app(Typo.axis)).foregroundStyle(.tertiary)
        }
    }

    private func figures(_ period: UsagePeriod?, total: Double, showMessages: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Fmt.tokens(total, exact: settings.exactNumbers))
                .font(.app(Typo.value + 3, .semibold)).monospacedDigit()
                .contentTransition(.numericText(value: total))
                .lineLimit(1).fixedSize()
            Text(Fmt.money(period?.costUsd ?? 0))
                .font(.app(Typo.body + 1, .medium)).foregroundStyle(Palette.usage).monospacedDigit().fixedSize()
            if showMessages {
                Text(Fmt.metric(Double(period?.messages ?? 0), .messages, exact: true))
                    .font(.app(Typo.body)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chart(buckets: [Int], scale: Double, nowSlot: Int) -> some View {
        Group {
            if settings.panelTodayStyle == "bars" {
                let hours = (0..<24).map { h in
                    Double((h * 2..<h * 2 + 2).reduce(0) { $0 + (buckets.indices.contains($1) ? buckets[$1] : 0) }) * scale
                }
                Chart {
                    ForEach(hours.indices, id: \.self) { h in
                        // BarMark draws nothing on a numeric x axis; use RectangleMark
                        RectangleMark(xStart: .value("Hour", Double(h) - 0.35), xEnd: .value("Hour", Double(h) + 0.35),
                                      yStart: .value("Usage", 0), yEnd: .value("Usage", hours[h]))
                            .foregroundStyle(h * 2 <= nowSlot
                                             ? Palette.usage.opacity(hovered == nil || hovered.map { $0 / 2 } == h ? 1 : 0.5)
                                             : Color.white.opacity(0.08))
                            .cornerRadius(1.5)
                    }
                }
                .chartXScale(domain: -0.5...23.5)
            } else {
                let points = cumulative(buckets, scale)
                Chart {
                    ForEach(points, id: \.0) { i, v in
                        AreaMark(x: .value("Hour", i), y: .value("Cumulative", v))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Palette.usage.opacity(0.28), Palette.usage.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Hour", i), y: .value("Cumulative", v))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Palette.usage)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    }
                    if let hovered, let point = points.first(where: { $0.0 == hovered }) {
                        RuleMark(x: .value("Hour", hovered)).foregroundStyle(Color.white.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Hour", point.0), y: .value("Cumulative", point.1)).foregroundStyle(Color.white).symbolSize(22)
                    }
                }
                .chartXScale(domain: 0...47)
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(height: 50)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let anchor = proxy.plotFrame else { return }
                            let plot = geo[anchor]
                            let slot = Int(((p.x - plot.minX) / plot.width * 48).rounded(.down))
                            let clamped = min(max(0, slot), nowSlot)
                            hovered = settings.panelTodayStyle == "bars" ? clamped / 2 * 2 : clamped
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func cumulative(_ buckets: [Int], _ scale: Double) -> [(Int, Double)] {
        var acc = 0.0
        return buckets.enumerated().map { i, v in
            acc += Double(v) * scale
            return (i, acc)
        }
    }

    private func hoverText(_ slot: Int, buckets: [Int], scale: Double) -> String {
        let exact = settings.exactNumbers
        if settings.panelTodayStyle == "bars" {
            let h = slot / 2
            let v = Double((h * 2..<h * 2 + 2).reduce(0) { $0 + (buckets.indices.contains($1) ? buckets[$1] : 0) }) * scale
            return String(format: "%02d:00–%02d:00 · ", h, h + 1) + Fmt.tokens(v, exact: exact)
        }
        let upTo = Double(buckets.prefix(slot + 1).reduce(0, +)) * scale
        let end = (slot + 1) * 30
        let time = String(format: "%02d:%02d", end / 60, end % 60)
        return L("By \(time)") + " · " + Fmt.tokens(upTo, exact: exact)
    }
}

// MARK: - Models / tools

private struct PanelModels: View {
    let period: UsagePeriod?
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let byModel = (period?.byModel ?? [:]).filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens }
        let total = Double(max(1, byModel.reduce(0) { $0 + $1.value.tokens }))
        PanelCard {
            PanelTitle(title: L("Today’s models")) { Text(byModel.isEmpty ? "" : L("\(byModel.count) models")) }
            if byModel.isEmpty {
                Text("No usage yet today").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                ProportionBar(parts: byModel.map { (colors.color($0.key), Double($0.value.tokens)) }, height: 6)
                VStack(spacing: 5) {
                    ForEach(byModel.prefix(settings.panelListCount), id: \.key) { m, slice in
                        PanelRow(logo: BrandLogos.model(m), color: colors.color(m), name: colors.name(m), monospaced: true,
                                 value: Fmt.tokens(Double(slice.tokens), exact: false),
                                 share: Double(slice.tokens) / total)
                    }
                }
            }
        }
    }
}

private struct PanelTools: View {
    let period: UsagePeriod?
    let colors: ModelColors
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let byClient = (period?.byClient ?? [:]).filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens }
        let total = Double(max(1, byClient.reduce(0) { $0 + $1.value.tokens }))
        PanelCard {
            PanelTitle(title: L("Today’s tools")) { Text(byClient.isEmpty ? "" : Fmt.money(byClient.reduce(0) { $0 + $1.value.costUsd })) }
            if byClient.isEmpty {
                Text("No usage yet today").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(byClient.prefix(settings.panelListCount), id: \.key) { c, slice in
                        PanelRow(logo: BrandLogos.tool(c), color: colors.toolColor(c), name: ModelPalette.toolLabel(c), monospaced: false,
                                 value: Fmt.tokens(Double(slice.tokens), exact: false),
                                 share: Double(slice.tokens) / total, detail: Fmt.money(slice.costUsd))
                    }
                }
            }
        }
    }
}

/// List row: swatch + name + share bar + value + percentage
private struct PanelRow: View {
    let logo: String?
    let color: Color
    let name: String
    let monospaced: Bool
    let value: String
    let share: Double
    var detail: String?

    var body: some View {
        HStack(spacing: 7) {
            EntityMark(logo: logo, color: color, size: 13)
            Text(name)
                .font(monospaced ? .system(size: Typo.body, design: .monospaced) : .app(Typo.body))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if let detail {
                Text(detail).font(.app(Typo.small)).foregroundStyle(.tertiary).fixedSize()
            }
            Text(value).font(.app(Typo.small, .medium)).foregroundStyle(.secondary).fixedSize()
            Text("\(Int((share * 100).rounded()))%")
                .font(.app(Typo.small)).foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

// MARK: - Last 7 days

private struct PanelWeek: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared
    @State private var hovered: Int?

    var body: some View {
        let days = (0..<7).reversed().map { offset -> DailyHistoryArchive.DaySummary in
            state.daySummary(Fmt.dayKey(Date().addingTimeInterval(-Double(offset) * 86400)))
        }
        let total = Double(days.reduce(0) { $0 + $1.tokens })
        let exact = settings.exactNumbers
        PanelCard {
            PanelTitle(title: L("Last 7 days")) {
                if let hovered, days.indices.contains(hovered) {
                    Text("\(Fmt.shortDate(days[hovered].date)) · \(Fmt.tokens(Double(days[hovered].tokens), exact: exact)) · \(Fmt.money(days[hovered].cost))")
                } else {
                    Text("Total \(Fmt.tokens(total, exact: false)) · \(Fmt.tokens(total / 7, exact: false))/day")
                }
            }
            Chart {
                ForEach(days.indices, id: \.self) { i in
                    RectangleMark(xStart: .value("Day", Double(i) - 0.31), xEnd: .value("Day", Double(i) + 0.31),
                                  yStart: .value("Usage", 0), yEnd: .value("Usage", days[i].tokens))
                        .foregroundStyle(Palette.usage.opacity(hovered == nil ? (i == 6 ? 1 : 0.72) : (hovered == i ? 1 : 0.4)))
                        .cornerRadius(3)
                }
            }
            .chartXScale(domain: -0.5...6.5)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 46)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                guard let anchor = proxy.plotFrame else { return }
                                let plot = geo[anchor]
                                hovered = min(6, max(0, Int((p.x - plot.minX) / plot.width * 7)))
                            case .ended: hovered = nil
                            }
                        }
                }
            }
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { i in
                    Text(i == 6 ? L("Today") : Fmt.weekday(RangeAnalytics.date(days[i].date)))
                        .font(.app(Typo.axis)).foregroundStyle(i == 6 ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Month cost

private struct PanelMonth: View {
    let month: RangeAnalytics.MonthCost

    var body: some View {
        let spent = month.days.last?.cumulative ?? 0
        let lastDay = month.days.count
        PanelCard {
            PanelTitle(title: L("This month’s cost")) {
                if month.lastMonthTotal > 0 { Text("Last month \(Fmt.money(month.lastMonthTotal))") }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.money(spent)).font(.app(Typo.value + 3, .semibold)).monospacedDigit().foregroundStyle(Palette.usage)
                if month.projected > spent {
                    Text("Projected \(Fmt.money(month.projected))").font(.app(Typo.small)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Chart {
                ForEach(month.days.indices, id: \.self) { i in
                    AreaMark(x: .value("Day", i + 1), y: .value("Cumulative", month.days[i].cumulative))
                        .foregroundStyle(LinearGradient(colors: [Palette.usage.opacity(0.25), Palette.usage.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", i + 1), y: .value("Cumulative", month.days[i].cumulative))
                        .foregroundStyle(Palette.usage)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                if month.projected > spent, lastDay > 0 {
                    LineMark(x: .value("Day", lastDay), y: .value("Projected", spent), series: .value("s", "p"))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    LineMark(x: .value("Day", month.daysInMonth), y: .value("Projected", month.projected), series: .value("s", "p"))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
            }
            .chartXScale(domain: 1...max(2, month.daysInMonth))
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 40)
        }
    }
}
