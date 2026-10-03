import SwiftUI
import Core
import DesignSystem

// MARK: - Limit colour and readout

/// Shares of a window at which its colour leaves the card accent for a warning, then a critical tone
private enum LimitLevel {
    static let warning = 0.75
    static let critical = 0.90

    static func tint(used: Double, accent: Color) -> Color {
        used >= critical ? Palette.critical : used >= warning ? Palette.warning : accent
    }
}

/// How one limit window is drawn: the fill, the even-pace marker, where it is heading and the number,
/// following the card's Used / Left and even-pace options. The colour follows how much is used either way.
private struct LimitReadout {
    /// Filled share of the bar or dial (used, or left)
    let fraction: Double
    /// Even-pace marker (elapsed share of the window), nil when hidden
    let pace: Double?
    /// Where the window is heading by its reset at the current pace; nil early in the window or in Left mode
    let projected: Double?
    let percentText: String
    let tint: Color

    init(_ w: LimitWindow, accent: Color, showUsed: Bool, showPace: Bool) {
        let used = w.usedPercent / 100
        let elapsed = w.elapsedFraction()
        tint = LimitLevel.tint(used: used, accent: accent)
        if showUsed {
            fraction = used
            pace = showPace ? elapsed : nil
            projected = elapsed.flatMap { $0 > 0.05 ? min(1, used / max($0, 0.02)) : nil }
            percentText = "\(Int((used * 100).rounded()))%"
        } else {
            fraction = 1 - used
            pace = showPace ? elapsed.map { 1 - $0 } : nil
            projected = nil
            percentText = "\(Int(w.remainingPercent.rounded()))%"
        }
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

    /// Each provider keeps its own colour (Claude terracotta, Codex teal), as in the menu bar panel
    private func accent(_ provider: LimitProvider) -> Color { colors.toolColor(provider.rawValue) }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("Limits · Settings"),
                     onHide: { settings.setVisible(.limits, false) }, done: { flipped = false }) {
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

    // MARK: Data

    private typealias Item = (provider: LimitProvider, snapshot: ProviderLimits?, status: LimitsStore.Status)

    private var shown: [Item] {
        [(LimitProvider.claude, limits.claude, limits.claudeStatus), (.codex, limits.codex, limits.codexStatus)]
            .filter { !settings.hiddenLimitProviders.contains($0.0.rawValue) }
    }

    /// A window to draw, or a provider with nothing to draw yet (not set up, unreachable, loading)
    private enum Entry: Identifiable {
        case window(LimitProvider, LimitWindow)
        case notice(LimitProvider, String)

        var id: String {
            switch self {
            case .window(let p, let w): "\(p.rawValue).\(w.id)"
            case .notice(let p, _): "\(p.rawValue).notice"
            }
        }
    }

    /// Every entry to show, provider by provider; per-model extra limits only when asked for
    private func entries(models: Bool) -> [Entry] {
        shown.flatMap { item -> [Entry] in
            guard let snapshot = item.snapshot else { return [.notice(item.provider, placeholder(item.status))] }
            return snapshot.windows.filter { models || $0.kind != .model }.map { .window(item.provider, $0) }
        }
    }

    /// The windows alone, in display order
    private func windows(models: Bool) -> [(provider: LimitProvider, window: LimitWindow)] {
        entries(models: models).compactMap { entry in
            if case .window(let p, let w) = entry { return (p, w) }
            return nil
        }
    }

    private func readout(_ w: LimitWindow, _ provider: LimitProvider, pace: Bool = true) -> LimitReadout {
        LimitReadout(w, accent: accent(provider), showUsed: settings.limitShowUsed, showPace: pace && settings.limitShowPace)
    }

    private var planText: String {
        shown.compactMap { $0.snapshot?.accountLabel }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What to say when there is no window to draw: every provider hidden, or the first provider's state
    /// (not configured, unreachable, loading)
    private var emptyText: String {
        guard let first = shown.first else { return L("All providers hidden") }
        return placeholder(first.status)
    }

    @ViewBuilder private var front: some View {
        switch cardSize {
        case .small: smallFront
        case .medium: mediumFront
        default: largeFront
        }
    }

    // MARK: 1×1

    /// Two rings for the two main windows, the first window's number beside them
    private var smallFront: some View {
        let windows = Array(windows(models: false).prefix(2))
        let readouts = windows.map { readout($0.window, $0.provider, pace: false) }
        let tones: [Double] = [1, 0.62]
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true })
            if windows.isEmpty {
                Text(emptyText).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(4)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .center, spacing: 9) {
                    ConcentricRings(rings: zip(readouts, tones).map { ($0.fraction, $0.tint.opacity($1)) }, lineWidth: 6, spacing: 2)
                        .frame(maxWidth: 62, maxHeight: 62)
                        .contentShape(Rectangle())
                        .dashboardHover { p in hoverWindow(windows[0].window, windows[0].provider, readouts[0].tint, p) }
                    VStack(alignment: .leading, spacing: 2) {
                        BigNumber(readouts[0].percentText, size: WidgetStyle.number(.small), value: readouts[0].fraction)
                        ForEach(Array(windows.enumerated()), id: \.offset) { i, item in
                            // One line per ring: dot, window length (5h / 7d) and the number
                            HStack(spacing: 4) {
                                Circle().fill(readouts[i].tint.opacity(tones[i])).frame(width: 5, height: 5)
                                Text(Self.shortLabel(item.window)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
                                if i > 0 {
                                    Text(readouts[i].percentText).font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
                                }
                            }
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .contentShape(Rectangle())
                            .dashboardHover { p in hoverWindow(item.window, item.provider, readouts[i].tint, p) }
                        }
                        if let reset = windows[0].window.resetsAt {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: Typo.axis - 1.5, weight: .semibold))
                                Text(Self.shortCountdown(reset)).font(.num(Typo.axis, .medium))
                            }
                            .foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    // MARK: 2×1

    /// One row per window: mark and name, a pace bar, the number and the time to the reset
    private var mediumFront: some View {
        let entries = entries(models: false)
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true }) {
                Text(planText).font(.system(size: Typo.small, design: .monospaced))
            }
            if entries.isEmpty {
                Text(emptyText).font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 2) {
                ForEach(entries.prefix(4)) { row($0) }
            }
            Spacer(minLength: 0)
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    /// Width of the mark + name column in the row layouts
    private static let nameWidth: CGFloat = Fmt.usesCJKUnits ? 58 : 74

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        switch entry {
        case .notice(let provider, let text):
            HStack(spacing: 6) {
                EntityMark(logo: BrandLogos.provider(provider.rawValue), color: colors.toolColor(provider.rawValue), size: 12)
                Text(provider.displayName).font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                Text(text).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: 21)
        case .window(let provider, let w):
            let r = readout(w, provider)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    EntityMark(logo: BrandLogos.provider(provider.rawValue), color: colors.toolColor(provider.rawValue), size: 12)
                    Text(Self.label(w)).font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(width: Self.nameWidth, alignment: .leading)
                PaceBar(fraction: r.fraction, pace: r.pace, projected: r.projected, tint: r.tint, height: 6)
                Text(r.percentText).font(.num(Typo.body + 1, .semibold)).contentTransition(.numericText())
                    .frame(width: 36, alignment: .trailing)
                Text(w.resetsAt.map(Self.shortCountdown) ?? "—").font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 46, alignment: .trailing)
            }
            .monospacedDigit()
            .frame(height: 21)
            .contentShape(Rectangle())
            .dashboardHover { p in hoverWindow(w, provider, r.tint, p) }
        }
    }

    // MARK: 2×2

    /// A grid of dials, two across; past four windows the first row stays dials and the rest are rows. Facts at the bottom.
    private var largeFront: some View {
        let entries = entries(models: settings.limitShowModelBuckets)
        let dialCount = entries.count <= 4 ? entries.count : 2
        let dials = Array(entries.prefix(dialCount))
        let rest = Array(entries.dropFirst(dialCount).prefix(4))
        let rows = (dials.count + 1) / 2
        let hasWindows = entries.contains { if case .window = $0 { true } else { false } }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Limits"), icon: SettingsStore.Card.limits.icon, onSettings: { flipped = true }) {
                if settings.limitShowPace, hasWindows {
                    Text("Marker = even pace")
                } else {
                    Text(planText).font(.system(size: Typo.small, design: .monospaced))
                }
            }
            if entries.isEmpty {
                Text("Both providers are hidden; turn them on in this card's settings (top right)")
                    .font(.app(Typo.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 6) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(dials[(r * 2)..<min(dials.count, r * 2 + 2)])) { entry in
                                dial(entry).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            if dials.count - r * 2 == 1 {
                                // A lone dial keeps to its column
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                if !rest.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(rest) { row($0) }
                    }
                }
                FactsRow(facts)
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    @ViewBuilder private func dial(_ entry: Entry) -> some View {
        switch entry {
        case .notice(let provider, let text):
            VStack(spacing: 5) {
                Spacer(minLength: 0)
                BrandBadge(logo: BrandLogos.provider(provider.rawValue), color: colors.toolColor(provider.rawValue), size: 22)
                Text(provider.displayName).font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                Text(text).font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        case .window(let provider, let w):
            let r = readout(w, provider)
            VStack(spacing: 2) {
                LimitDial(readout: r)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 4) {
                    EntityMark(logo: BrandLogos.provider(provider.rawValue), color: colors.toolColor(provider.rawValue), size: 11)
                    Text(Self.label(w)).font(.app(Typo.small, .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(w.resetsAt.map { L("Resets in \(Self.shortCountdown($0))") } ?? " ")
                    .font(.app(Typo.axis)).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
            .dashboardHover { p in hoverWindow(w, provider, r.tint, p) }
        }
    }

    /// Plan, the next reset and how the main window compares with even use
    private var facts: [(String, String)] {
        let windows = windows(models: false)
        let now = Date()
        var out: [(String, String)] = [(L("Plan"), planText.isEmpty ? "—" : planText)]
        let next = windows.compactMap(\.window.resetsAt).filter { $0 > now }.min()
        out.append((L("Next reset"), next.map(Self.resetFormatter) ?? "—"))
        if let main = windows.first?.window, let elapsed = main.elapsedFraction(now: now) {
            let points = Int(((main.usedPercent / 100 - elapsed) * 100).rounded())
            out.append((L("Even pace"), points > 0 ? L("\(points)% ahead") : points < 0 ? L("\(-points)% behind") : L("On pace")))
        }
        return out
    }

    // MARK: Hover

    private func hoverWindow(_ w: LimitWindow, _ provider: LimitProvider, _ color: Color, _ p: CGPoint?) {
        let tipID = "limit.\(provider.rawValue).\(w.id)"
        guard let p else { tip?.hide(tipID); return }
        let updated = shown.first { $0.provider == provider }?.snapshot?.updatedAt
        tip?.show(tipID, key: w.id, at: p) { LimitTip(window: w, provider: provider, color: color, updatedAt: updated) }
    }

    // MARK: Labels (shared with the quick panel and the notifier)

    /// Compact window name for the 1×1 size: the window length ("5h", "7d") instead of "Session" / "Weekly"
    static func shortLabel(_ w: LimitWindow) -> String {
        switch w.kind {
        case .session, .weekly:
            let minutes = Int(w.spanSeconds / 60)
            return minutes % 1440 == 0 ? L("\(minutes / 1440)d") : L("\(max(1, minutes / 60))h")
        default: return label(w)
        }
    }

    static func label(_ w: LimitWindow) -> String {
        switch w.kind {
        case .session: L("Session")
        case .weekly: L("Weekly")
        case .fable: "Fable"
        case .model: w.title ?? L("Model")
        }
    }

    /// Reset time: today → "14:30", this week → "Sun 14:30", later → "Oct 7 14:30"
    static func resetFormatter(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return DateFormatter.resetToday.string(from: date) }
        if let days = cal.dateComponents([.day], from: Date(), to: date).day, days < 6 { return DateFormatter.resetWeek.string(from: date) }
        return DateFormatter.resetLater.string(from: date)
    }

    /// Time to a reset, compact: "2d 4h", "2h 14m", "35m"
    static func shortCountdown(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        if s >= 86400 { return L("\(s / 86400)d \(s % 86400 / 3600)h") }
        if s >= 3600 { return L("\(s / 3600)h \(s % 3600 / 60)m") }
        return L("\(max(1, s / 60))m")
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

/// A limit window as a dial: the number sits in the dial, sized to it
private struct LimitDial: View {
    let readout: LimitReadout

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            LimitGauge(fraction: readout.fraction, projected: readout.projected, elapsed: readout.pace, accent: readout.tint) {
                BigNumber(readout.percentText, size: min(WidgetStyle.number(.small), side * 0.26), value: readout.fraction)
                    .padding(.horizontal, side * 0.18)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Hover details for a limit window: used / left / window progress / projection at the current pace / reset countdown
struct LimitTip: View {
    let window: LimitWindow
    let provider: LimitProvider
    let color: Color
    var updatedAt: Date?

    var body: some View {
        TipCard(title: "\(provider.displayName) · \(LimitsCard.label(window))",
                subtitle: Self.span(Int(window.spanSeconds / 60)),
                icon: SettingsStore.Card.limits.icon, tint: color,
                value: String(format: "%.0f%%", window.usedPercent),
                footnote: updatedAt.map(LimitsCard.ago)) {
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

// MARK: - Models card: donut + a row per model

struct ModelsCard: View {
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hoveredKey: String?
    /// The model in focus (clicked): the others step back in grey
    @State private var focus: String?
    /// Width of the row list; starts narrow so the first layout cannot overflow
    @State private var listWidth: CGFloat = 160
    @Environment(\.cardSize) private var cardSize

    private struct ModelGroup: Identifiable {
        var id: String { key }
        let key: String
        let tokens: Double
        let cost: Double
        let members: [RangeReport.Share]
    }

    private var byCost: Bool { settings.modelsMetric == .cost }

    /// Every colour slot in the fixed ranking order, zeros included, so the ring keeps its places and morphs
    private var groups: [ModelGroup] {
        var members: [String: [RangeReport.Share]] = [:]
        for share in report.models { members[colors.group(share.key), default: []].append(share) }
        return colors.stackOrder.map { key in
            let list = members[key] ?? []
            return ModelGroup(key: key, tokens: Double(list.reduce(0) { $0 + $1.tokens }), cost: list.reduce(0) { $0 + $1.cost }, members: list)
        }
    }

    private func value(_ g: ModelGroup) -> Double { byCost ? g.cost : g.tokens }

    private func valueText(_ v: Double, exact: Bool) -> String {
        byCost ? Fmt.money(v) : Fmt.tokens(v, exact: exact)
    }

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

    private func toggleFocus(_ key: String) {
        withAnimation(Motion.data) { focus = focus == key ? nil : key }
    }

    /// The focused model, while it has usage in this range (a range or filter change can leave it with none)
    private func activeFocus(_ groups: [ModelGroup]) -> String? {
        guard let focus, groups.contains(where: { $0.key == focus && value($0) > 0 }) else { return nil }
        return focus
    }

    /// Bottom facts at large size: models used, the top model's share, cost per million tokens
    private func facts(_ listed: [ModelGroup], total: Double) -> [(String, String)] {
        let tokens = Double(report.models.reduce(0) { $0 + $1.tokens })
        let cost = report.models.reduce(0) { $0 + $1.cost }
        return [
            (L("Models"), String(report.models.count)),
            (L("Top share"), listed.first.map { percent(value($0) / max(1e-9, total)) } ?? "—"),
            (L("Per 1M tokens"), tokens > 0 ? Fmt.money(cost / (tokens / 1e6)) : "—"),
        ]
    }

    // MARK: 1×1

    /// The top model and its share, everyone's share as a bar
    private var smallFront: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + value($1) }
        let sorted = groups.filter { value($0) > 0 }.sorted { value($0) > value($1) }
        let focus = activeFocus(groups)
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(L("Models"), icon: SettingsStore.Card.models.icon, onSettings: { flipped = true })
            if let top = sorted.first {
                HStack(spacing: 6) {
                    EntityMark(logo: top.key == ModelPalette.otherKey ? nil : BrandLogos.model(top.key), color: colors.groupColor(top.key), size: 14)
                    Text(colors.name(top.key)).font(.system(size: Typo.body, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                BigNumber(percent(value(top) / max(1e-9, total)), size: WidgetStyle.number(.small), value: value(top))
                Spacer(minLength: 0)
                SegmentBar(parts: sorted.map { (key: $0.key, value: value($0), color: colors.groupColor($0.key)) }, height: 6,
                           tipID: "models.small", focus: focus) { key in
                    AnyView(tipFor(key, groups: groups, total: total))
                }
                Text(L("\(report.models.count) models")).font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                Text(L("No usage in this range")).font(.app(Typo.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    // MARK: 2×1 and 2×2

    private var donutFront: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + value($1) }
        let medium = cardSize == .medium
        let focus = activeFocus(groups)
        let listed = Array(groups.filter { value($0) > 0 }.sorted { value($0) > value($1) }.prefix(medium ? 4 : 6))
        let shown = groups.first { $0.key == (hoveredKey ?? focus) } ?? listed.first
        let totalText = valueText(total, exact: exact)
        let donutSide: CGFloat = medium ? 92 : 124
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
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            HStack(alignment: medium ? .center : .top, spacing: medium ? 14 : 16) {
                DonutChart(slots: groups.map { (key: $0.key, value: value($0), color: colors.groupColor($0.key)) }, inner: 0.7,
                           hovered: hoveredKey, focus: focus,
                           onHover: { key, p in hover(key.flatMap { k in groups.first { $0.key == k } }, total: total, at: p) },
                           onTap: { key in toggleFocus(key) }) {
                    VStack(spacing: 0) {
                        Text(percent((shown.map(value) ?? 0) / max(1e-9, total)))
                            .font(.num(medium ? Typo.title + 2 : Typo.value + 3, .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(shown.map { colors.name($0.key) } ?? L("Top"))
                            .font(.app(Typo.axis)).foregroundStyle(.tertiary).lineLimit(1).padding(.horizontal, 10)
                    }
                    .animation(Motion.hover, value: hoveredKey)
                    .animation(Motion.data, value: focus)
                }
                .frame(width: donutSide, height: donutSide)
                // The longest name sets the width of the name column, so the bars line up
                let longest = listed.map { colors.name($0.key) }.max { $0.count < $1.count } ?? ""
                VStack(spacing: medium ? 0 : 1) {
                    ForEach(listed) { g in
                        row(g, total: total, top: listed.first.map(value) ?? 0, longest: longest, focus: focus, large: !medium)
                    }
                    if listed.isEmpty {
                        Text(L("No usage in this range")).font(.app(Typo.small)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The width the list is given (not the width its rows would like): rows drop the amount when it is narrow
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { listWidth = $0 }
                .animation(Motion.data, value: listed.map(\.key))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !medium { FactsRow(facts(listed, total: total)) }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    /// One model: mark, name, its share as a bar, the amount (when there is room) and the percentage
    private func row(_ g: ModelGroup, total: Double, top: Double, longest: String, focus: String?, large: Bool) -> some View {
        let color = colors.groupColor(g.key)
        let active = focus == nil || focus == g.key
        let roomy = listWidth >= 230
        // Exact token counts need a wider column; they are shown where the list has it, short ones elsewhere
        let exactFits = exact && !byCost && listWidth >= 340
        let amountWidth: CGFloat = exactFits ? 88 : 48
        let sparkline = large && settings.modelsShowSparklines && listWidth >= (exactFits ? 400 : 300) && report.days.count >= 3
        // The name takes what the mark, the shortest bar, the numbers and the gaps leave
        let nameCap = max(40, listWidth - 101 - (roomy ? amountWidth + 6 : 0) - (sparkline ? 58 : 0))
        return HStack(spacing: 6) {
            EntityMark(logo: g.key == ModelPalette.otherKey ? nil : BrandLogos.model(g.key), color: color, size: 13)
            ZStack(alignment: .leading) {
                Text(longest).hidden()
                Text(colors.name(g.key))
            }
            .font(.system(size: Typo.body, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: nameCap, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            if sparkline {
                SparkLine(values: dailySeries(g.key), color: active ? color : Palette.muted)
                    .frame(width: 52, height: 16)
                    .allowsHitTesting(false)
            }
            DepthBar(fraction: value(g) / max(1e-9, top), tint: active ? color : Palette.muted, height: 5)
                .frame(minWidth: 28, maxWidth: .infinity)
            if roomy {
                Text(valueText(value(g), exact: exactFits)).font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .frame(width: amountWidth, alignment: .trailing)
            }
            Text(percent(value(g) / max(1e-9, total)))
                .font(.num(Typo.body, .medium)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 34, alignment: .trailing)
        }
        .monospacedDigit()
        .frame(height: large ? 23 : 21)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hoveredKey == g.key ? 0.06 : focus == g.key ? 0.035 : 0)))
        .opacity(active ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { toggleFocus(g.key) }
        .dashboardHover { p in hover(p == nil ? nil : g, total: total, at: p) }
    }

    // MARK: Hover

    private func hover(_ g: ModelGroup?, total: Double, at p: CGPoint?) {
        let tipID = "models"
        guard let g, let p else {
            if hoveredKey != nil { hoveredKey = nil }
            tip?.hide(tipID)
            return
        }
        if hoveredKey != g.key { hoveredKey = g.key }
        tip?.show(tipID, key: g.key, at: p) { tipContent(g, total: total) }
    }

    @ViewBuilder private func tipFor(_ key: String, groups: [ModelGroup], total: Double) -> some View {
        if let g = groups.first(where: { $0.key == key }) { tipContent(g, total: total) }
    }

    /// Model, tokens, share, cost and cost per million; the members of "Other"
    private func tipContent(_ g: ModelGroup, total: Double) -> some View {
        let activeDays = dailySeries(g.key).filter { $0 > 0 }.count
        let share = percent(value(g) / max(1e-9, total))
        let color = colors.groupColor(g.key)
        return TipCard(title: colors.name(g.key),
                       subtitle: g.key == ModelPalette.otherKey ? L("\(g.members.count) models combined") : ModelPalette.vendor(g.key).localizedName,
                       icon: SettingsStore.Card.models.icon, tint: color, value: share) {
            TipRow(color: color, label: "Tokens", value: Fmt.tokens(g.tokens, exact: exact), secondary: byCost ? nil : share)
            TipRow(label: L("Cost"), value: Fmt.money(g.cost), secondary: byCost ? share : nil)
            if g.tokens > 0 {
                TipRow(label: L("Per million tokens"), value: Fmt.money(g.cost / (g.tokens / 1e6)))
            }
            TipRow(label: L("Days with usage"), value: "\(activeDays) / \(report.days.count)")
            if g.key == ModelPalette.otherKey, !g.members.isEmpty {
                Divider().overlay(Palette.hairline)
                ForEach(g.members.prefix(6), id: \.key) { m in
                    TipRow(color: colors.color(m.key), label: colors.name(m.key),
                           value: byCost ? Fmt.money(m.cost) : Fmt.tokens(Double(m.tokens), exact: false))
                }
            }
        }
    }
}
