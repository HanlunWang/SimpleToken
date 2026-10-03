import SwiftUI
import Core
import DesignSystem

/// Main chart: the metric adding up over the range, against the period before it (kit `AreaChart`).
/// Hovering a day shows the total up to it in the big number and the day's own numbers in a readout.
struct HeroCard: View {
    struct Point {
        let x: Double           // 0…1 horizontal position (aligned with the previous period)
        let y: Double           // cumulative value
        let value: Double       // value of that day / time slot
        /// Day key, or the half-hour's clock time at 1D
        let key: String
        let label: String
    }

    let report: RangeReport
    let todayHalfHours: [Int]
    let compact: Bool
    @Bindable var settings: SettingsStore
    /// Model colours for the hovered day's breakdown; without them the readout stops at the totals
    var colors: ModelColors? = nil
    @Environment(HoverTip.self) private var tip: HoverTip?
    @Environment(\.cardSize) private var cardSize
    @State private var selectedIndex: Int?
    @State private var flipped = false

    private static let accentKey = "card.hero"
    private static let tipID = "hero"
    private var metric: UsageMetric { settings.metric }

    // MARK: Colours

    /// The stored accent; nil is the default, a blue that runs into indigo along the line
    private var customAccent: Color? {
        guard let stored = settings.cardAccents[Self.accentKey], !stored.isEmpty else { return nil }
        return Accent.resolve(stored, fallback: .blue)
    }

    private var chartColors: (line: [Color], area: [Color]) {
        if let customAccent { return AreaChart.colors(for: customAccent) }
        return ([Palette.usage.lit, Accent.indigo.color.lit], [Palette.usage, Accent.indigo.color])
    }

    /// One colour standing for the series: icon chips, swatches
    private var accent: Color { customAccent ?? Palette.usage }

    // MARK: Data

    private var current: [Point] {
        if report.range == .day { return intradayPoints }
        return report.current.map {
            Point(x: $0.position, y: $0.cumulative, value: $0.value, key: $0.date, label: Fmt.shortDate($0.date))
        }
    }

    /// The comparison line; empty when there is none or it is switched off
    private var previous: [(x: Double, y: Double)] {
        guard settings.heroShowPrevious else { return [] }
        if report.range == .day {
            // No reliable intraday data for yesterday: draw an even-pace line to yesterday's total
            guard let total = report.previousTotal, total > 0 else { return [] }
            return [(0, 0), (1, total)]
        }
        return report.previous?.map { ($0.position, $0.cumulative) } ?? []
    }

    /// 1D: shape from the session logs' half-hour distribution, scaled to the live total for today (which every other card uses, so they agree)
    private var intradayPoints: [Point] {
        let now = Date()
        let cal = Calendar.current
        let nowSlot = cal.component(.hour, from: now) * 2 + (cal.component(.minute, from: now) >= 30 ? 1 : 0)
        let buckets = Array(todayHalfHours.prefix(nowSlot + 1))
        let raw = Double(buckets.reduce(0, +))
        let scale = raw > 0 ? report.total / raw : 0
        var acc = 0.0
        return buckets.enumerated().map { i, v in
            acc += Double(v) * scale
            let clock = String(format: "%d:%02d", i / 2, (i % 2) * 30)
            return Point(x: Double(i + 1) / 48, y: acc, value: Double(v) * scale, key: clock, label: clock)
        }
    }

    private func selected(in points: [Point]) -> Point? {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return nil }
        return points[selectedIndex]
    }

    private var selected: Point? { selected(in: current) }

    private func top(_ points: [Point], _ previous: [(x: Double, y: Double)]) -> Double {
        let peak = max(points.map(\.y).max() ?? 0, previous.map(\.y).max() ?? 0)
        return (peak > 0 ? peak : (metric == .cost ? 1 : 10)) * 1.05
    }

    /// Labels under the plot: the range's first, middle and last day (clock times at 1D)
    private var xLabels: [String] {
        if report.range == .day { return ["0:00", "12:00", "24:00"] }
        let days = report.days
        guard days.count > 1 else { return [] }
        if days.count == 2 { return [days[0].date, days[1].date].map(Fmt.shortDate) }
        return [days[0].date, days[days.count / 2].date, days[days.count - 1].date].map(Fmt.shortDate)
    }

    /// The comparison line's value at the same horizontal position (linear interpolation)
    private func previousValue(at x: Double, in previous: [(x: Double, y: Double)]) -> Double? {
        guard let first = previous.first, let last = previous.last else { return nil }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        guard let j = previous.firstIndex(where: { $0.x >= x }), j > 0 else { return first.y }
        let a = previous[j - 1], b = previous[j]
        let t = b.x > a.x ? (x - a.x) / (b.x - a.x) : 1
        return a.y + (b.y - a.y) * t
    }

    // MARK: View

    var body: some View {
        FlipCard(flipped: flipped) {
            front
                .onChange(of: report.range) { clearSelection() }
                .onChange(of: report.metric) { clearSelection() }
        } back: {
            CardBack(title: L("Main chart · Settings"), accentKey: Self.accentKey, accentDefault: .blue,
                     onHide: { settings.setVisible(.hero, false) }, padding: 14, radius: 18,
                     done: { flipped = false }) {
                OptionRow(L("Metric")) {
                    GlassSegmented(UsageMetric.allCases.map { ($0, $0.localizedLabel) }, selection: $settings.metric)
                }
                OptionRow(L("Token numbers")) {
                    GlassSegmented([(false, L("Short \(Fmt.short(4_959_084_551))")), (true, L("Exact 4,959,084,551"))], selection: $settings.exactNumbers)
                }
                OptionRow(report.range == .ytd ? L("Same period last year line") : L("Previous period line")) { MiniToggle(isOn: $settings.heroShowPrevious) }
                Text("Metric and number format apply to all cards.").font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    private func clearSelection() {
        selectedIndex = nil
        tip?.hide(Self.tipID)
    }

    private var front: some View {
        Group {
            switch cardSize {
            case .small, .medium: mediumFront
            case .large: largeFront
            case .wide: wideFront
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .wide ? 2 : 0), radius: 18)
    }

    private var title: String {
        selected.map { L("\($0.label) · Cumulative") } ?? "\(metric.localizedLabel) · \(report.range.localizedLabel)"
    }

    private var header: some View {
        WidgetHeader(title, icon: SettingsStore.Card.hero.icon, tint: accent, onSettings: { flipped = true })
    }

    /// 2×1: header, number row, curve without axes filling the rest
    private var mediumFront: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            numberRow(size: WidgetStyle.number(.medium), legend: false)
            caption
            chart(axes: false, bars: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 2×2: header, number row, curve with axes and the days' own columns, four facts at the bottom
    private var largeFront: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            numberRow(size: WidgetStyle.number(.large), legend: false)
            caption
            chart(axes: true, bars: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)
            FactsRow(facts)
        }
    }

    /// 4×2: like large, with the metric switch in the header and a legend at the end of the number row
    private var wideFront: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                header
                controls
            }
            numberRow(size: WidgetStyle.number(.wide), legend: true)
            caption
            chart(axes: true, bars: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)
            FactsRow(facts)
        }
    }

    /// The front only has the metric switch; short / exact lives on the back and in settings
    private var controls: some View {
        GlassSegmented(UsageMetric.allCases.map { ($0, $0.localizedLabel) }, selection: $settings.metric)
    }

    // MARK: Number

    /// Big number (the total, or the total up to the hovered point) with the change against the previous period beside it
    private func numberRow(size: CGFloat, legend: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            heroNumber(size: size)
                .layoutPriority(1)
            if let change = report.changePercent {
                DeltaChip(percent: change, invert: metric == .cost)
                    .opacity(selected == nil ? 1 : 0)
            }
            Spacer(minLength: 0)
            if legend { self.legend }
        }
    }

    private func heroNumber(size: CGFloat) -> some View {
        let value = selected?.y ?? report.total
        return Group {
            if metric == .cost {
                MoneyNumber(value, size: size)
            } else {
                BigNumber(Fmt.metric(value, metric, exact: settings.exactNumbers), size: size, value: value)
            }
        }
        .animation(.snappy(duration: 0.35), value: value)
    }

    /// Under the number: the hovered point's own value, else the comparison with the previous period
    private var caption: some View {
        Text(captionText)
            .font(.app(Typo.small)).foregroundStyle(.secondary).monospacedDigit()
            .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
            .frame(height: 14, alignment: .leading)
            .contentTransition(.opacity)
    }

    private var captionText: String {
        if let selected {
            let value = Fmt.metric(selected.value, metric, exact: settings.exactNumbers)
            return report.range == .day ? L("This half-hour: \(value)") : L("This day: \(value)")
        }
        if let prev = report.previousTotal {
            return "\(comparisonLabel) \(Fmt.metric(prev, metric, exact: settings.exactNumbers))"
        }
        if report.range == .all, let first = report.days.first { return L("Since \(Fmt.longDate(first.date))") }
        return otherUnitTotal
    }

    private var comparisonLabel: String {
        switch report.range {
        case .day: L("vs yesterday")
        case .ytd: L("vs same period last year")
        default: L("vs previous period")
        }
    }

    /// Total in the other unit: cost when showing tokens, tokens otherwise
    private var otherUnitTotal: String {
        metric == .tokens ? L("Cost \(Fmt.money(report.stats.totalCost))") : "\(Fmt.tokens(totalTokens, exact: false)) tokens"
    }

    private var totalTokens: Double { report.days.reduce(0) { $0 + Double($1.tokens) } }

    // MARK: Facts

    /// Four facts: average per day, the peak day, active days and the previous period's total
    private var facts: [(String, String)] {
        let s = report.stats
        var out: [(String, String)] = []
        if report.range == .day {
            if let prev = report.previousTotal { out.append((L("Yesterday"), Fmt.metric(prev, metric, exact: false))) }
            out.append((metric == .tokens ? L("Cost") : "Tokens", metric == .tokens ? Fmt.money(s.totalCost) : Fmt.tokens(totalTokens, exact: false)))
            out.append((L("Messages"), Fmt.exact(report.days.reduce(0) { $0 + $1.messages })))
            return out
        }
        out.append((L("Daily avg"), Fmt.metric(report.total / Double(max(1, s.totalDays)), metric, exact: false)))
        if let peak = s.peak {
            out.append((L("Peak · \(Fmt.shortDate(peak.date))"), Fmt.metric(metric.value(peak), metric, exact: false)))
        }
        out.append((L("Active days"), "\(s.activeDays) / \(s.totalDays)"))
        // The 2×2 card has no room for this label, and the line under its number already says it
        if let prev = report.previousTotal, !compact {
            out.append((report.range == .ytd ? L("Same period last year") : L("Previous period"), Fmt.metric(prev, metric, exact: false)))
        } else {
            out.append((metric == .tokens ? L("Cost") : "Tokens", metric == .tokens ? Fmt.money(s.totalCost) : Fmt.tokens(totalTokens, exact: false)))
        }
        return out
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(report.range == .day ? L("Today") : L("This period")) {
                Capsule().fill(LinearGradient(colors: chartColors.line, startPoint: .leading, endPoint: .trailing))
            }
            if !previous.isEmpty {
                legendItem(report.range == .day ? L("Yesterday (even pace)") : report.range == .ytd ? L("Same period last year") : L("Previous period")) {
                    DashedLine()
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func legendItem<Mark: View>(_ text: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 5) {
            mark().frame(width: 14, height: 3)
            Text(text).font(.app(Typo.small)).foregroundStyle(.secondary)
        }
    }

    /// The comparison line's dashes, as a legend mark
    private struct DashedLine: View {
        var body: some View {
            Canvas { ctx, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(line, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
            }
        }
    }

    // MARK: Chart

    private func chart(axes: Bool, bars: Bool) -> some View {
        let points = current
        let previous = previous
        let colors = chartColors
        return AreaChart(points: points.map { (x: $0.x, y: $0.y) }, comparison: previous, top: top(points, previous), axes: axes,
                         format: ChartAxis.format(metric), xLabels: xLabels, selected: selectedIndex,
                         line: colors.line, area: colors.area, bars: bars ? points.map(\.value) : nil) { index, at in
            hover(index, at: at, points: points, previous: previous)
        }
    }

    private func hover(_ index: Int?, at point: CGPoint, points: [Point], previous: [(x: Double, y: Double)]) {
        selectedIndex = index
        guard let index, points.indices.contains(index) else { tip?.hide(Self.tipID); return }
        let p = points[index]
        let prev = previousValue(at: p.x, in: previous)
        let exact = settings.exactNumbers
        let day = report.range == .day ? nil : (report.days.indices.contains(index) ? report.days[index] : nil)
        tip?.show(Self.tipID, key: p.key, at: point, glide: true) {
            HeroTip(title: report.range == .day ? L("Today \(p.label)") : DayDetailTip.dateTitle(p.key),
                    metric: metric, value: p.value, cumulative: p.y, previous: prev, previousLabel: previousLabel,
                    accent: accent, exact: exact, day: colors == nil ? nil : day, colors: colors)
        }
    }

    private var previousLabel: String {
        switch report.range {
        case .day: L("Yesterday (even pace)")
        case .ytd: L("Same period last year")
        default: L("Previous period")
        }
    }
}

// MARK: - Hover readout

/// The hovered point: the day's own value as the headline, the total so far, the previous period at the same
/// point with the change, and (where the day has them) the models behind it
private struct HeroTip: View {
    let title: String
    let metric: UsageMetric
    let value: Double
    let cumulative: Double
    let previous: Double?
    let previousLabel: String
    let accent: Color
    let exact: Bool
    /// The hovered day; nil at 1D and without model colours (no breakdown then)
    let day: DailyHistoryArchive.DaySummary?
    let colors: ModelColors?

    var body: some View {
        let models = modelShares
        let total = max(1e-9, models.reduce(0) { $0 + $1.value })
        TipCard(title: title, icon: SettingsStore.Card.hero.icon, tint: accent, value: Fmt.metric(value, metric, exact: exact)) {
            TipRow(label: L("So far"), value: Fmt.metric(cumulative, metric, exact: exact))
            if let previous {
                HStack(spacing: 6) {
                    Text(previousLabel).font(.app(Typo.small)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Fmt.metric(previous, metric, exact: false)).font(.num(Typo.small, .medium)).lineLimit(1).fixedSize()
                    if previous > 0 {
                        DeltaChip(percent: (cumulative - previous) / previous * 100, invert: metric == .cost)
                    }
                }
            }
            if !models.isEmpty {
                Divider().overlay(Palette.hairline).padding(.vertical, 1)
                TipBar(parts: models.map { (colors?.color($0.key) ?? accent, $0.value) })
                ForEach(models.prefix(4), id: \.key) { m in
                    TipRow(color: colors?.color(m.key) ?? accent, label: colors?.name(m.key) ?? ModelPalette.shortName(m.key),
                           value: Fmt.metric(m.value, metric, exact: false), secondary: percent(m.value / total))
                }
                if models.count > 4 {
                    Text("+\(models.count - 4) more models").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The day's models in the metric's unit (messages are not kept per model)
    private var modelShares: [(key: String, value: Double)] {
        guard let day, colors != nil else { return [] }
        let raw: [String: Double]
        switch metric {
        case .tokens: raw = day.byModel.mapValues(Double.init)
        case .cost: raw = day.costByModel
        case .messages: return []
        }
        return raw.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
