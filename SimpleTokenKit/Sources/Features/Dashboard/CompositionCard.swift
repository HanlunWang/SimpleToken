import SwiftUI
import Core
import DesignSystem

// MARK: - Token breakdown (cache = two blues, fresh = two warms)

/// How the period's tokens split between cache reads, cache writes, fresh input and output: a donut in a
/// fixed order with the cache hit rate (or the total) in its hole. Clicking a row or a sector puts that
/// part in focus; the rest turn grey.
struct CompositionCard: View {
    let state: AppState
    let range: TimeRange
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hovered: String?
    @State private var focus: String?
    @State private var roomy = true
    @State private var hovering = false
    @Environment(\.cardSize) private var cardSize

    private struct Part: Identifiable {
        let id: String
        let name: String
        let value: Int
        let color: Color
        let explain: String
        let pick: (UsagePeriod.Slice) -> Int
    }

    private var resolvedPeriod: String {
        guard settings.compositionPeriod == "auto" else { return settings.compositionPeriod }
        switch range {
        case .day: return "today"
        case .all: return "all"
        default: return "month"
        }
    }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.composition.localizedName) · Settings"), onHide: { settings.setVisible(.composition, false) }, done: { flipped = false }) {
                OptionRow(L("Period")) {
                    GlassSegmented([("auto", L("Match range")), ("today", L("Today")), ("month", L("This month")), ("all", L("All time"))],
                                   selection: $settings.compositionPeriod)
                }
                OptionRow(L("Hit rate in center")) { MiniToggle(isOn: $settings.compositionShowHitRate) }
                Text("tokscale only breaks down today, this month and all time, so 1W–1Y use this month when matching the range.")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    private var front: some View {
        let key = resolvedPeriod
        let period: UsagePeriod? = state.period(key == "today" ? \.today : key == "all" ? \.allTime : \.month)
        let label = key == "today" ? L("Today") : key == "all" ? L("All time") : L("This month")
        let c = Palette.composition
        let parts = [
            Part(id: "cacheRead", name: L("Cache read"), value: period?.cacheReadTokens ?? 0, color: c[0],
                 explain: L("Cache hit, ~1/10 of the input price"), pick: \.cacheRead),
            Part(id: "cacheWrite", name: L("Cache write"), value: period?.cacheWriteTokens ?? 0, color: c[1],
                 explain: L("First write to cache, a bit above input"), pick: \.cacheWrite),
            Part(id: "input", name: L("Input"), value: period?.inputTokens ?? 0, color: c[2],
                 explain: L("New input that missed the cache"), pick: \.input),
            Part(id: "output", name: L("Output"), value: period?.outputTokens ?? 0, color: c[3],
                 explain: L("Model-generated, the priciest"), pick: \.output),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.value })
        let inputs = max(1, parts[0].value + parts[1].value + parts[2].value)
        let hit = Double(parts[0].value) / Double(inputs)
        let hitText = String(format: "%.1f%%", hit * 100)
        return VStack(alignment: .leading, spacing: 8) {
            // 1×1 has no room for the settings button beside the title: it appears while the pointer is over the card
            WidgetHeader(SettingsStore.Card.composition.localizedName, icon: SettingsStore.Card.composition.icon,
                         onSettings: cardSize != .small || hovering ? { flipped = true } : nil) {
                if cardSize != .small {
                    Text(settings.compositionPeriod == "auto" && range != .day && range != .all ? L("\(label) (calendar month)") : label)
                }
            }
            switch cardSize {
            case .small:
                // 1×1: the ring with the hit rate (or the total) in its hole
                donut(parts, period: period, total: total, hitText: hitText, centre: 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .medium:
                HStack(alignment: .center, spacing: 16) {
                    donut(parts, period: period, total: total, hitText: hitText, centre: 14).frame(width: 88, height: 88)
                    partRows(parts, period: period, total: total, bars: false, explain: false)
                }
                .frame(maxHeight: .infinity)
            default:
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(Fmt.tokens(Double(total), exact: exact), size: WidgetStyle.number(.large) - 2, value: Double(total))
                    Text("\(label) total · \(percent(Double(parts[0].value) / Double(total))) from cache").font(.app(Typo.small)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(alignment: .center, spacing: roomy ? 18 : 12) {
                    donut(parts, period: period, total: total, hitText: hitText, centre: 17).frame(width: roomy ? 118 : 100, height: roomy ? 118 : 100)
                    // The one-line explanations only fit when the widget is wide enough
                    partRows(parts, period: period, total: total, bars: true, explain: roomy)
                }
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: Bool.self, of: { $0.size.width >= 400 }) { roomy = $0 }
                FactsRow([(L("Hit rate"), hitText),
                          (L("From cache"), percent(Double(parts[0].value) / Double(total))),
                          (L("Output"), percent(Double(parts[3].value) / Double(total)))])
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large ? 2 : 0))
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }

    /// The ring: four sectors in a fixed order, the hit rate or the total in the hole
    private func donut(_ parts: [Part], period: UsagePeriod?, total: Int, hitText: String, centre: CGFloat) -> some View {
        DonutChart(slots: parts.map { (key: $0.id, value: Double($0.value), color: $0.color) }, inner: 0.7, hovered: hovered, focus: focus,
                   onHover: { key, p in hover(key.flatMap { k in parts.first { $0.id == k } }, period: period, total: total, at: p) },
                   onTap: { key in toggleFocus(key) }) {
            VStack(spacing: 0) {
                if settings.compositionShowHitRate {
                    Text(hitText).font(.num(centre, .semibold)).monospacedDigit().contentTransition(.numericText())
                    Text("Hit rate").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                } else {
                    BigNumber(Fmt.tokens(Double(total), exact: false), size: centre, value: Double(total))
                    Text(UsageMetric.tokens.localizedLabel).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
        }
    }

    /// One row per part: swatch, name (and what it means), tokens, share; a bar against the total at the large size
    private func partRows(_ parts: [Part], period: UsagePeriod?, total: Int, bars: Bool, explain: Bool) -> some View {
        VStack(spacing: bars ? 3 : 0) {
            ForEach(parts) { part in
                let lit = focus == nil || focus == part.id
                HStack(alignment: .top, spacing: 7) {
                    Swatch(lit ? part.color : Palette.muted, size: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(part.name).font(.app(Typo.body, focus == part.id ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Fmt.tokens(Double(part.value), exact: exact)).font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .contentTransition(.numericText())
                            Text(percent(Double(part.value) / Double(total))).font(.num(Typo.body, .semibold)).foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        if bars {
                            DepthBar(fraction: Double(part.value) / Double(total), tint: lit ? part.color : nil, height: 4)
                        }
                        if explain {
                            Text(part.explain).font(.app(Typo.axis)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }
                }
                .monospacedDigit()
                .opacity(lit ? 1 : 0.6)
                .frame(height: bars ? (explain ? 36 : 26) : 21, alignment: bars ? .top : .center)
                .padding(.horizontal, 4)
                .padding(.vertical, bars ? 2 : 0)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered == part.id ? 0.06 : 0)))
                .contentShape(Rectangle())
                .dashboardHover { p in hover(p == nil ? nil : part, period: period, total: total, at: p) }
                .onTapGesture { toggleFocus(part.id) }
                .help(focus == part.id ? L("Click to show every series again") : L("Click to focus on \(part.name)"))
            }
        }
        .animation(Motion.hover, value: hovered)
    }

    private func toggleFocus(_ key: String) {
        withAnimation(Motion.data) { focus = focus == key ? nil : key }
    }

    private func hover(_ part: Part?, period: UsagePeriod?, total: Int, at p: CGPoint?) {
        let tipID = "composition"
        guard let part, let p else {
            if hovered != nil { hovered = nil }
            tip?.hide(tipID)
            return
        }
        if hovered != part.id { hovered = part.id }
        let models = (period?.byModel ?? [:]).map { ($0.key, part.pick($0.value)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        tip?.show(tipID, key: part.id, at: p, glide: true) {
            TipCard(title: part.name, subtitle: part.explain, value: Fmt.tokens(Double(part.value), exact: exact)) {
                TipRow(color: part.color, label: L("Share"), value: percent(Double(part.value) / Double(total)))
                if !models.isEmpty {
                    Divider().overlay(Palette.hairline)
                    TipBar(parts: models.map { (colors.color($0.0), Double($0.1)) })
                    ForEach(models.prefix(5), id: \.0) { m, v in
                        TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.tokens(Double(v), exact: false),
                               secondary: percent(Double(v) / Double(max(1, part.value))))
                    }
                }
            }
        }
    }
}
