import SwiftUI
import Charts
import Core
import DesignSystem

// MARK: - Limit ring (shared by the main window and the quick panel)

struct LimitRing: View {
    let window: LimitWindow
    let color: Color
    var size: CGFloat = 64
    var lineWidth: CGFloat = 6
    var showUsed: Bool = true
    @State private var appeared = false

    var body: some View {
        let used = window.usedPercent / 100
        let fill = showUsed ? used : 1 - used
        let elapsed = window.elapsedFraction() ?? 0
        let inset = lineWidth / 2 + 3
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth).padding(inset)
            Circle()
                .trim(from: 0, to: appeared ? max(fill, fill > 0 ? 0.012 : 0) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(inset)
            // Thin outer ring: time elapsed in the reset window
            Circle()
                .trim(from: 0, to: appeared ? elapsed : 0)
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fill * 100).rounded()))%")
                .font(.app(size * 0.2, .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.8), value: fill)
        .onAppear { withAnimation(.smooth(duration: 1.1)) { appeared = true } }
    }
}

// MARK: - Limits card

struct LimitsCard: View {
    let limits: LimitsStore
    let colors: ModelColors
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @Environment(\.cardSize) private var cardSize

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("Limits · Settings"), onHide: { settings.setVisible(.limits, false) }, done: { flipped = false }) {
                OptionRow(L("Numbers show")) {
                    GlassSegmented([(true, L("Used")), (false, L("Left"))], selection: $settings.limitShowUsed)
                }
                OptionRow(L("Show \(LimitProvider.claude.displayName)")) { MiniToggle(isOn: providerBinding("claude")) }
                OptionRow(L("Show \(LimitProvider.codex.displayName)")) { MiniToggle(isOn: providerBinding("codex")) }
                OptionRow(L("Per-model extra limits")) { MiniToggle(isOn: $settings.limitShowModelBuckets) }
                OptionRow(L("Even-pace line")) { MiniToggle(isOn: $settings.limitShowPace) }
                OptionRow(L("Data")) {
                    Button("Refresh Now") { limits.refreshNow() }.controlSize(.small)
                }
            }
        }
    }

    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !settings.hiddenLimitProviders.contains(id) },
                set: { if $0 { settings.hiddenLimitProviders.remove(id) } else { settings.hiddenLimitProviders.insert(id) } })
    }

    private typealias Item = (provider: LimitProvider, snapshot: ProviderLimits?, status: LimitsStore.Status)

    private var shown: [Item] {
        [(LimitProvider.claude, limits.claude, limits.claudeStatus), (.codex, limits.codex, limits.codexStatus)]
            .filter { !settings.hiddenLimitProviders.contains($0.0.rawValue) }
    }

    /// Every limit window to show (laid out flat at small / medium size; per-model extra limits are left out)
    private var flatWindows: [(provider: LimitProvider, window: LimitWindow)] {
        shown.flatMap { item in (item.snapshot?.windows ?? []).filter { $0.kind != .model }.map { (item.provider, $0) } }
    }

    @ViewBuilder private var front: some View {
        switch cardSize {
        case .small: smallFront
        case .medium: mediumFront
        default: largeFront
        }
    }

    /// 1×1: concentric rings (outside in = top to bottom on the right) show at a glance how much of each window is used
    private var smallFront: some View {
        let items = Array(flatWindows.prefix(3))
        let tones: [Double] = [1, 0.72, 0.48]
        var seen: [LimitProvider: Int] = [:]
        let styled = items.map { item -> (LimitProvider, LimitWindow, Color) in
            let n = seen[item.provider, default: 0]
            seen[item.provider] = n + 1
            return (item.provider, item.window, colors.toolColor(item.provider.rawValue).opacity(tones[min(n, 2)]))
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true })
            if styled.isEmpty {
                Text(shown.isEmpty ? L("All providers hidden") : L("Loading")).font(.app(Typo.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    ConcentricRings(rings: styled.map { (fraction(for: $0.1) / 100, $0.2) }, lineWidth: 7, spacing: 2)
                        .frame(maxWidth: 84, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(styled.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(fraction(for: item.1).rounded()))%")
                                    .font(.app(Typo.title + 3, .semibold)).monospacedDigit()
                                HStack(spacing: 3) {
                                    Circle().fill(item.2).frame(width: 5, height: 5)
                                    Text(Self.label(item.1)).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                            .dashboardHover { p in hoverWindow(item.1, item.0, colors.toolColor(item.0.rawValue), p) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    private func fraction(for w: LimitWindow) -> Double {
        settings.limitShowUsed ? w.usedPercent : w.remainingPercent
    }

    /// 2×1: one ring per window
    private var mediumFront: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true }) {
                Text(shown.compactMap { $0.snapshot?.accountLabel }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: Typo.small, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if flatWindows.isEmpty {
                Text(shown.isEmpty ? L("All providers hidden") : L("Loading limits")).font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(flatWindows.prefix(5).enumerated()), id: \.offset) { _, item in
                    let color = colors.toolColor(item.provider.rawValue)
                    VStack(spacing: 3) {
                        LimitRing(window: item.window, color: color, size: 58, lineWidth: 5.5, showUsed: settings.limitShowUsed)
                        HStack(spacing: 3) {
                            BrandLogo(BrandLogos.provider(item.provider.rawValue) ?? "claude", size: 9).foregroundStyle(color)
                            Text(Self.label(item.window)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(item.window.resetsAt.map(Self.resetFormatter) ?? " ")
                            .font(.app(Typo.axis)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .dashboardHover { p in hoverWindow(item.window, item.provider, color, p) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    private func hoverWindow(_ w: LimitWindow, _ provider: LimitProvider, _ color: Color, _ p: CGPoint?) {
        let tipID = "limit.\(provider.rawValue).\(w.id)"
        guard let p else { tip?.hide(tipID); return }
        tip?.show(tipID, at: p) { LimitTip(window: w, provider: provider, color: color) }
    }

    /// 2×2: a main ring per provider + a bar and projection for each window
    private var largeFront: some View {
        let shown = shown
        return VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true }) {
                if settings.limitShowPace {
                    ViewThatFits(in: .horizontal) {
                        Text("Tick = where even use until the reset would be").fixedSize()
                        Text("Tick = even pace").fixedSize()
                        EmptyView()
                    }
                    .font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 10)
            if shown.isEmpty {
                Text("Both providers are hidden; turn them on in this card's settings (top right)").font(.app(Typo.body)).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider().overlay(Palette.hairline).padding(.vertical, 10) }
                provider(item.0, item.1, item.2)
            }
            Spacer(minLength: 0)
        }
        .glassCard()
    }

    @ViewBuilder
    private func provider(_ id: LimitProvider, _ snapshot: ProviderLimits?, _ status: LimitsStore.Status) -> some View {
        let color = colors.toolColor(id.rawValue)
        let windows = snapshot?.windows.filter { settings.limitShowModelBuckets || $0.kind != .model } ?? []
        HStack(alignment: .top, spacing: 12) {
            if let main = snapshot?.primaryWindow {
                LimitRing(window: main, color: color, showUsed: settings.limitShowUsed)
            } else {
                Circle().stroke(Palette.track, lineWidth: 6).padding(6).frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    BrandBadge(logo: BrandLogos.provider(id.rawValue), color: color, size: 17)
                    Text(id.displayName).font(.app(Typo.title, .medium))
                    if let label = snapshot?.accountLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: Typo.small, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.14)))
                    }
                    Spacer()
                    Text(statusText(status, snapshot)).font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
                if snapshot != nil {
                    ForEach(windows) { w in windowRow(w, provider: id, color: color) }
                } else {
                    Text(placeholder(status)).font(.app(Typo.body)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func windowRow(_ w: LimitWindow, provider: LimitProvider, color: Color) -> some View {
        let value = settings.limitShowUsed ? w.usedPercent : w.remainingPercent
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(Self.label(w)).font(.app(Typo.body)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: w.kind == .model ? nil : Self.labelWidth, alignment: .leading)
                    .frame(maxWidth: w.kind == .model ? 150 : nil, alignment: .leading)
                LimitBar(window: w, color: color, showUsed: settings.limitShowUsed, showPace: settings.limitShowPace)
                Text("\(Int(value.rounded()))%")
                    .font(.app(Typo.body, .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 34, alignment: .trailing)
            }
            ViewThatFits(in: .horizontal) {
                Text(note(w)).fixedSize()
                Text(shortNote(w)).fixedSize()
                Text(shortNote(w)).lineLimit(1).truncationMode(.tail)
            }
            .font(.app(Typo.small)).foregroundStyle(.tertiary)
            .padding(.leading, w.kind == .model ? 0 : Self.labelWidth + 8)
        }
        .contentShape(Rectangle())
        .dashboardHover { p in hoverWindow(w, provider, color, p) }
    }

    /// Width of the window label column in the large layout (English labels are wider)
    private static let labelWidth: CGFloat = Fmt.usesCJKUnits ? 34 : 50

    static func label(_ w: LimitWindow) -> String {
        switch w.kind {
        case .session: L("Session")
        case .weekly: L("Weekly")
        case .fable: "Fable"
        case .model: w.title ?? L("Model")
        }
    }

    private func note(_ w: LimitWindow) -> String {
        let reset = w.resetsAt.map { L("Resets \(Self.resetFormatter($0))") } ?? ""
        if w.usedPercent <= 0 { return reset }
        guard let projected = w.projectedPercent() else { return L("Window just started · \(reset)") }
        let pct = "\(Int(projected.rounded()))%"
        return L("At this pace, ~\(pct) by reset · \(reset)")
    }

    /// Note when narrow: "Est. 32% · Resets Sun 10:59"
    private func shortNote(_ w: LimitWindow) -> String {
        let reset = w.resetsAt.map { L("Resets \(Self.resetFormatter($0))") } ?? ""
        guard w.usedPercent > 0, let projected = w.projectedPercent() else { return reset }
        let pct = "\(Int(projected.rounded()))%"
        return L("Est. \(pct) · \(reset)")
    }

    static func resetFormatter(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return DateFormatter.resetToday.string(from: date) }
        if let days = cal.dateComponents([.day], from: Date(), to: date).day, days < 6 { return DateFormatter.resetWeek.string(from: date) }
        return DateFormatter.resetLater.string(from: date)
    }

    private func statusText(_ status: LimitsStore.Status, _ snapshot: ProviderLimits?) -> String {
        switch status {
        case .probing: return L("Updating")
        case .failed: return snapshot == nil ? "" : L("Unreachable")
        case .ok: return snapshot.map { Self.ago($0.updatedAt) } ?? ""
        default: return ""
        }
    }

    private func placeholder(_ status: LimitsStore.Status) -> String {
        switch status {
        case .notConfigured: L("Not configured")
        case .failed(let reason): L("Unreachable · \(reason)")
        default: L("Loading limits")
        }
    }

    static func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 90 { return L("Just updated") }
        if s < 3600 { return L("\(s / 60) min ago") }
        return L("\(s / 3600) h ago")
    }
}

/// Hover details for a limit window: used / left / window progress / projection at the current pace / reset countdown
struct LimitTip: View {
    let window: LimitWindow
    let provider: LimitProvider
    let color: Color

    var body: some View {
        TipCard(title: "\(provider.displayName) · \(LimitsCard.label(window))",
                subtitle: Self.span(Int(window.spanSeconds / 60))) {
            TipRow(color: color, label: L("Used"), value: String(format: "%.0f%%", window.usedPercent))
            TipRow(label: L("Left"), value: String(format: "%.0f%%", window.remainingPercent))
            if let elapsed = window.elapsedFraction() {
                TipRow(label: L("Window elapsed"), value: String(format: "%.0f%%", elapsed * 100))
            }
            if let projected = window.projectedPercent() {
                TipRow(label: L("At this pace, by reset"), value: String(format: "≈ %.0f%%", projected))
            }
            if let reset = window.resetsAt {
                Divider().overlay(Palette.hairline)
                TipRow(label: L("Resets"), value: LimitsCard.resetFormatter(reset), secondary: Self.countdown(reset))
            }
        }
    }

    static func span(_ minutes: Int) -> String {
        minutes >= 1440 ? L("\(minutes / 1440)-day window") : minutes >= 60 ? L("\(minutes / 60)-hour window") : L("\(minutes)-minute window")
    }

    static func countdown(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        if s >= 86400 { return L("\(s / 86400) d \(s % 86400 / 3600) h left") }
        if s >= 3600 { return L("\(s / 3600) h \(s % 3600 / 60) min left") }
        return L("\(s / 60) min left")
    }
}

/// Limit bar: light track in the same colour + solid fill + even-pace tick
struct LimitBar: View {
    let window: LimitWindow
    let color: Color
    let showUsed: Bool
    var showPace = true
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let used = window.usedPercent / 100
            let fill = showUsed ? used : 1 - used
            let fillWidth = fill > 0 ? max(4, w * fill) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule().fill(color)
                    .frame(width: appeared ? fillWidth : 0)
                    .offset(x: showUsed ? 0 : w - fillWidth)
                if showPace, let elapsed = window.elapsedFraction() {
                    let x = showUsed ? elapsed : 1 - elapsed
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 2, height: 12)
                        .offset(x: appeared ? w * x - 1 : 0)
                }
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .animation(.smooth(duration: 0.6), value: showUsed)
        }
        .frame(height: 14)
        .onAppear { withAnimation(.smooth(duration: 1.0)) { appeared = true } }
    }
}

// MARK: - Models card: donut + a sparkline per model

struct ModelsCard: View {
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hoveredKey: String?
    @State private var listNarrow = false
    @Environment(\.cardSize) private var cardSize

    private struct Group: Identifiable {
        var id: String { key }
        let key: String
        let tokens: Double
        let cost: Double
        let members: [RangeReport.Share]
    }

    private var byCost: Bool { settings.modelsMetric == .cost }

    private var groups: [Group] {
        var members: [String: [RangeReport.Share]] = [:]
        for share in report.models { members[colors.group(share.key), default: []].append(share) }
        return colors.stackOrder.compactMap { key in
            guard let list = members[key] else { return nil }
            let g = Group(key: key, tokens: Double(list.reduce(0) { $0 + $1.tokens }), cost: list.reduce(0) { $0 + $1.cost }, members: list)
            return value(g) > 0 ? g : nil
        }
    }

    private func value(_ g: Group) -> Double { byCost ? g.cost : g.tokens }

    private func dailySeries(_ key: String) -> [Double] {
        report.days.map { d in
            let source: [String: Double] = byCost ? d.costByModel : d.byModel.mapValues(Double.init)
            return source.reduce(0.0) { acc, pair in colors.group(pair.key) == key ? acc + pair.value : acc }
        }
    }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("Models · Settings"), onHide: { settings.setVisible(.models, false) }, done: { flipped = false }) {
                OptionRow(L("Share by")) {
                    GlassSegmented([(UsageMetric.tokens, "Tokens"), (.cost, L("Cost"))], selection: $settings.modelsMetric)
                }
                OptionRow(L("Sparklines")) { MiniToggle(isOn: $settings.modelsShowSparklines) }
                OptionRow(L("Color scheme")) {
                    GlassSegmented([("vendor", L("By vendor")), ("ranked", L("Color-blind safe"))], selection: $settings.modelColorMode)
                }
                OptionRow(L("Models shown separately")) {
                    Stepper("\(settings.separateModels)", value: $settings.separateModels, in: 2...8)
                        .font(.app(Typo.body)).controlSize(.small)
                        .disabled(settings.modelColorMode == "ranked")
                }
                Text("Change a model's color, alias and whether it counts in Settings → Models.")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var front: some View {
        if cardSize == .small { smallFront } else { donutFront }
    }

    /// Bottom facts at large size: top model, cost per million tokens, number of vendors
    private var modelFacts: [(String, String)] {
        let tokens = Double(report.models.reduce(0) { $0 + $1.tokens })
        let cost = report.models.reduce(0) { $0 + $1.cost }
        let vendors = Set(report.models.map { ModelPalette.vendor($0.key) }).count
        var out: [(String, String)] = []
        if let top = report.models.first { out.append((L("Top model"), colors.name(top.key))) }
        out.append((L("Per million tokens"), tokens > 0 ? Fmt.money(cost / (tokens / 1e6)) : "—"))
        out.append((L("Vendors"), String(vendors)))
        return out
    }

    private func donutParts(_ groups: [Group]) -> [(key: String, value: Double, color: Color)] {
        groups.map { (key: $0.key, value: value($0), color: colors.groupColor($0.key)) }
    }

    /// 1×1: small donut + the share of the top models
    private var smallFront: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + value($1) }
        let sorted = groups.sorted { value($0) > value($1) }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Models"), icon: SettingsStore.Card.models.icon, onSettings: { flipped = true })
            HStack(alignment: .center, spacing: 12) {
                DonutChart(parts: donutParts(groups), inner: 0.62, hovered: hoveredKey,
                           onHover: { key, p in hover(groups.first { $0.key == key }, total: total, at: p) }) {
                    EmptyView()
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sorted.prefix(4)) { g in
                        HStack(spacing: 5) {
                            Circle().fill(colors.groupColor(g.key)).frame(width: 6, height: 6)
                            Text(colors.name(g.key)).font(.system(size: Typo.small, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(percent(value(g) / max(1e-9, total))).font(.app(Typo.small, .semibold)).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .dashboardHover { p in hover(p == nil ? nil : g, total: total, at: p) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    private var donutFront: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + value($1) }
        let shown = groups.first { $0.key == hoveredKey }
        let medium = cardSize == .medium
        let listed = groups.sorted { value($0) > value($1) }.prefix(medium ? 4 : 7)
        let totalText = byCost ? Fmt.money(total) : Fmt.tokens(total, exact: exact)
        return VStack(alignment: .leading, spacing: medium ? 8 : 10) {
            WidgetHeader(L("Models"), icon: SettingsStore.Card.models.icon, onSettings: { flipped = true }) {
                Text(medium ? L("\(report.models.count) models · \(totalText)")
                     : byCost ? L("\(report.models.count) models · by cost") : L("\(report.models.count) models · by tokens"))
            }
            if !medium {
                // Large size: the total goes on top
                VStack(alignment: .leading, spacing: 2) {
                    BigNumber(totalText, size: WidgetStyle.number(.large), value: total)
                    Text("\(report.range.localizedLabel) · Colored by last 30 days' usage").font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: medium ? .center : .top, spacing: medium ? 14 : 18) {
                DonutChart(parts: donutParts(groups), inner: 0.7, hovered: hoveredKey,
                           onHover: { key, p in hover(groups.first { $0.key == key }, total: total, at: p) }) {
                    VStack(spacing: 0) {
                        let v = shown.map(value) ?? (groups.max { value($0) < value($1) }.map(value) ?? 0)
                        Text(percent(v / max(1e-9, total)))
                            .font(.app(medium ? Typo.title + 2 : Typo.value + 3, .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(shown.map { colors.name($0.key) } ?? L("Top"))
                            .font(.app(Typo.axis)).foregroundStyle(.tertiary).lineLimit(1).padding(.horizontal, 8)
                    }
                    .animation(.snappy, value: hoveredKey)
                }
                .frame(width: medium ? 92 : 132, height: medium ? 92 : 132)
                VStack(spacing: medium ? 0 : 2) {
                    ForEach(Array(listed)) { g in
                        row(g, total: total, sparkline: !medium)
                    }
                }
                .onGeometryChange(for: Bool.self, of: { $0.size.width < 230 }) { listNarrow = $0 }
                .animation(.smooth(duration: 0.4), value: groups.map(\.key))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !medium { FactsRow(modelFacts) }
        }
        .glassCard(padding: WidgetStyle.padding + (medium ? 0 : 2))
    }

    private func row(_ g: Group, total: Double, sparkline: Bool) -> some View {
        HStack(spacing: 8) {
            EntityMark(logo: g.key == ModelPalette.otherKey ? nil : BrandLogos.model(g.key), color: colors.groupColor(g.key), size: 13)
            Text(colors.name(g.key))
                .font(.system(size: Typo.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if sparkline, settings.modelsShowSparklines, !listNarrow, report.days.count >= 3 {
                Sparkline(values: dailySeries(g.key), color: colors.groupColor(g.key), height: 16)
                    .frame(width: 52)
                    .allowsHitTesting(false)
            }
            if !sparkline {
                Text(byCost ? Fmt.money(value(g)) : Fmt.tokens(value(g), exact: false))
                    .font(.app(Typo.small)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(percent(value(g) / max(1e-9, total)))
                .font(.app(Typo.body, .medium)).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: sparkline ? 23 : 21)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hoveredKey == g.key ? 0.06 : 0)))
        .contentShape(Rectangle())
        .dashboardHover { p in hover(g, total: total, at: p) }
    }

    /// Donut hover: finds the sector from the pointer's angle around the centre (ignored outside the ring)
    private func donutHover(groups: [Group], total: Double) -> some View {
        GeometryReader { geo in
            Color.clear.contentShape(Circle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase else { hover(nil, total: total, at: nil); return }
                    let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let dx = p.x - c.x, dy = p.y - c.y
                    let r = hypot(dx, dy), outer = min(geo.size.width, geo.size.height) / 2
                    guard r > outer * 0.62, r < outer * 1.02 else { hover(nil, total: total, at: nil); return }
                    // Clockwise from 12 o'clock
                    var angle = atan2(dx, -dy)
                    if angle < 0 { angle += 2 * .pi }
                    var acc = 0.0
                    let target = angle / (2 * .pi) * total
                    let hit = groups.first { acc += value($0); return target <= acc }
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    hover(hit, total: total, at: CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                }
        }
    }

    private func hover(_ g: Group?, total: Double, at p: CGPoint?) {
        let tipID = "models"
        guard let g, let p else {
            if hoveredKey != nil { hoveredKey = nil }
            tip?.hide(tipID)
            return
        }
        if hoveredKey != g.key { hoveredKey = g.key }
        let activeDays = dailySeries(g.key).filter { $0 > 0 }.count
        tip?.show(tipID, at: p) {
            TipCard(title: colors.name(g.key),
                    subtitle: g.key == ModelPalette.otherKey ? L("\(g.members.count) models combined") : ModelPalette.vendor(g.key).localizedName) {
                TipRow(color: colors.groupColor(g.key), label: byCost ? L("Cost") : "Tokens",
                       value: byCost ? Fmt.money(g.cost) : Fmt.tokens(g.tokens, exact: exact),
                       secondary: percent(value(g) / max(1e-9, total)))
                TipRow(label: byCost ? "Tokens" : L("Cost"), value: byCost ? Fmt.tokens(g.tokens, exact: false) : Fmt.money(g.cost))
                if g.tokens > 0 {
                    TipRow(label: L("Per million tokens"), value: Fmt.money(g.cost / (g.tokens / 1e6)))
                }
                TipRow(label: L("Days with usage"), value: "\(activeDays) / \(report.days.count)")
                if g.key == ModelPalette.otherKey {
                    Divider().overlay(Palette.hairline)
                    ForEach(g.members.prefix(6), id: \.key) { m in
                        TipRow(color: colors.color(m.key), label: colors.name(m.key),
                               value: byCost ? Fmt.money(m.cost) : Fmt.tokens(Double(m.tokens), exact: false))
                    }
                }
            }
        }
    }
}
