import SwiftUI
import Charts
import Core
import DesignSystem

/// Resamples a polyline to a fixed number of points evenly spaced on x (linear interpolation).
/// A fixed count with fixed ids lets Charts morph point by point when the range changes instead of adding / removing points.
func resampled(_ points: [(x: Double, y: Double)], count: Int) -> [(x: Double, y: Double)] {
    guard let first = points.first, let last = points.last, count > 1 else { return points }
    guard points.count > 1 else { return (0..<count).map { _ in (first.x, first.y) } }
    var out: [(x: Double, y: Double)] = []
    var j = 1
    for i in 0..<count {
        let x = first.x + (last.x - first.x) * Double(i) / Double(count - 1)
        while j < points.count - 1 && points[j].x < x { j += 1 }
        let a = points[j - 1], b = points[j]
        let t = b.x > a.x ? (x - a.x) / (b.x - a.x) : 1
        out.append((x, a.y + (b.y - a.y) * min(1, max(0, t))))
    }
    return out
}

/// Main chart: cumulative curve over the range + a previous-period comparison line. On hover the big number
/// shows the cumulative value at that point (Wealthsimple style).
struct HeroCard: View {
    struct Point: Identifiable {
        let id: Int
        let x: Double           // 0…1 horizontal position (aligned with the previous period)
        let y: Double           // cumulative value
        let value: Double       // value of that day / time slot
        let label: String
    }

    let report: RangeReport
    let todayHalfHours: [Int]
    let compact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var selectedX: Double?
    @State private var flipped = false
    @Environment(\.cardSize) private var cardSize

    private var line: Color { settings.accent("card.hero", .white) }

    private static let samples = 90
    private var metric: UsageMetric { settings.metric }

    // MARK: Data

    private var current: [Point] {
        if report.range == .day { return intradayPoints }
        return report.current.map {
            Point(id: $0.index, x: $0.position, y: $0.cumulative, value: $0.value, label: Fmt.shortDate($0.date))
        }
    }

    private var previous: [(x: Double, y: Double)]? {
        guard settings.heroShowPrevious else { return nil }
        if report.range == .day {
            // No reliable intraday data for yesterday: draw an even-pace line to yesterday's total
            guard let total = report.previousTotal else { return nil }
            return [(0, 0), (1, total)]
        }
        return report.previous?.map { ($0.position, $0.cumulative) }
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
            return Point(id: i, x: Double(i + 1) / 48, y: acc, value: Double(v) * scale,
                         label: String(format: "%d:%02d", i / 2, (i % 2) * 30))
        }
    }

    private var selected: Point? {
        guard let selectedX else { return nil }
        return current.min { abs($0.x - selectedX) < abs($1.x - selectedX) }
    }

    private var yMax: Double {
        max(report.total, previous?.last?.y ?? 0, 1) * 1.08
    }

    // MARK: View

    var body: some View {
        FlipCard(flipped: flipped) {
            front
                .onChange(of: report.range) { selectedX = nil }
                .onChange(of: report.metric) { selectedX = nil }
        } back: {
            CardBack(title: L("Main chart · Settings"), accentKey: "card.hero", accentDefault: .white,
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

    /// Value of the hovered day / half-hour
    private func pointValueText(_ v: Double, exact: Bool) -> String {
        let value = Fmt.metric(v, metric, exact: exact)
        return report.range == .day ? L("This half-hour: \(value)") : L("This day: \(value)")
    }

    private var header: some View {
        WidgetHeader(title, icon: SettingsStore.Card.hero.icon, onSettings: { flipped = true }) {
            if cardSize == .wide || cardSize == .large { legend }
        }
    }

    /// 2×1: number top left, curve without axes on the right
    private var mediumFront: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    heroNumber(size: WidgetStyle.number(.medium))
                    if let selected {
                        Text(pointValueText(selected.value, exact: false))
                            .font(.app(Typo.small)).foregroundStyle(.secondary)
                    } else if let change = report.changePercent {
                        DeltaChip(percent: change)
                    }
                    Spacer(minLength: 0)
                    Text(secondaryTotal).font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
                }
                .frame(width: 150, alignment: .leading)
                chart(axes: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 2×2: number + comparison, curve with axes below, three facts at the bottom
    private var largeFront: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 3) {
                heroNumber(size: WidgetStyle.number(.large))
                subline
            }
            chart(axes: true)
                .frame(maxHeight: .infinity)
            FactsRow(facts)
        }
    }

    /// 4×2: number and facts in a column on the left, large chart on the right
    private var wideFront: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                header
                controls
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    heroNumber(size: WidgetStyle.number(.wide))
                    subline
                    Spacer(minLength: 10)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                            Fact(label: f.0, value: f.1)
                        }
                    }
                }
                .frame(width: 210, alignment: .leading)
                chart(axes: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Total in the other unit: cost when showing tokens, tokens otherwise
    private var secondaryTotal: String {
        metric == .tokens ? L("Cost \(Fmt.money(report.stats.totalCost))")
            : "\(Fmt.tokens(report.days.reduce(0) { $0 + Double($1.tokens) }, exact: false)) tokens"
    }

    private var facts: [(String, String)] {
        let s = report.stats
        let perDay = report.range == .day ? nil : Fmt.metric(report.total / Double(max(1, s.totalDays)), metric, exact: false)
        var out: [(String, String)] = []
        if let perDay { out.append((L("Daily avg"), perDay)) }
        if let peak = s.peak, report.range != .day {
            let v: Double = switch metric {
            case .tokens: Double(peak.tokens)
            case .cost: peak.cost
            case .messages: Double(peak.messages)
            }
            out.append((L("Peak · \(Fmt.shortDate(peak.date))"), Fmt.metric(v, metric, exact: false)))
        }
        if report.range != .day { out.append((L("Active days"), "\(s.activeDays) / \(s.totalDays)")) }
        out.append((metric == .tokens ? L("Cost") : "Tokens", metric == .tokens ? Fmt.money(s.totalCost)
                    : Fmt.tokens(report.days.reduce(0) { $0 + Double($1.tokens) }, exact: false)))
        return Array(out.prefix(cardSize == .wide ? 4 : 3))
    }

    private func headline(numberSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(selected.map { L("\($0.label) · Cumulative") } ?? "\(metric.localizedLabel) · \(report.range.localizedLabel)")
                .font(.app(Typo.body)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
            heroNumber(size: numberSize)
            subline
        }
    }

    /// The front only has the metric switch; short / exact lives on the back and in settings
    @ViewBuilder private var controls: some View {
        GlassSegmented(UsageMetric.allCases.map { ($0, $0.localizedLabel) }, selection: $settings.metric)
    }

    private func heroNumber(size: CGFloat) -> some View {
        let value = selected?.y ?? report.total
        let text = Fmt.metric(value, metric, exact: settings.exactNumbers)
        return BigNumber(metric == .tokens && !text.contains(" ") ? text + " tokens" : text, size: size, value: value)
            .animation(.snappy(duration: 0.35), value: value)
    }

    /// Subline: drops the trailing cost / tokens first when it does not fit, then truncates
    private var subline: some View {
        ViewThatFits(in: .horizontal) {
            sublineContent(withExtra: false).fixedSize()
            sublineContent(withExtra: false).lineLimit(1).truncationMode(.tail)
        }
        .font(.app(Typo.body))
        .frame(height: 20)
        .monospacedDigit()
    }

    private func sublineContent(withExtra: Bool) -> some View {
        HStack(spacing: 8) {
            if let selected {
                Text(pointValueText(selected.value, exact: settings.exactNumbers))
                    .foregroundStyle(.secondary)
            } else {
                if let change = report.changePercent, let prev = report.previousTotal {
                    DeltaChip(percent: change)
                    Text("\(comparisonLabel) \(Fmt.metric(prev, metric, exact: settings.exactNumbers))")
                        .foregroundStyle(.secondary)
                } else if report.range == .all, let first = report.days.first {
                    Text("Since \(Fmt.longDate(first.date))").foregroundStyle(.secondary)
                }
                if withExtra {
                    Text("·").foregroundStyle(.tertiary)
                    Text(metric == .tokens ? Fmt.money(report.stats.totalCost)
                                           : Fmt.tokens(report.days.reduce(0) { $0 + Double($1.tokens) }, exact: settings.exactNumbers))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var comparisonLabel: String {
        switch report.range {
        case .day: L("vs yesterday")
        case .ytd: L("vs same period last year")
        default: L("vs previous period")
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(line, report.range == .day ? L("Today") : L("This period"))
            if previous != nil {
                legendItem(Color.white.opacity(0.3), report.range == .day ? L("Yesterday (even pace)") : report.range == .ytd ? L("Same period last year") : L("Previous period"))
            }
        }
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(text).font(.app(Typo.small)).foregroundStyle(.secondary)
        }
    }

    private func chart(axes: Bool) -> some View {
        let cur = current
        let curLine = resampled(cur.map { ($0.x, $0.y) }, count: Self.samples)
        let prevLine = previous.map { resampled($0, count: Self.samples) }
        return Chart {
            if let prevLine {
                ForEach(Array(prevLine.enumerated()), id: \.offset) { i, p in
                    LineMark(x: .value("Position", p.x), y: .value("Cumulative", p.y), series: .value("Period", "previous"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.white.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
            ForEach(Array(curLine.enumerated()), id: \.offset) { i, p in
                AreaMark(x: .value("Position", p.x), y: .value("Cumulative", p.y))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [line.opacity(0.15), line.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Position", p.x), y: .value("Cumulative", p.y), series: .value("Period", "current"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if let selected {
                RuleMark(x: .value("Position", selected.x))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Position", selected.x), y: .value("Cumulative", selected.y))
                    .foregroundStyle(line)
                    .symbolSize(56)
                if let prev = previousValue(at: selected.x) {
                    PointMark(x: .value("Position", selected.x), y: .value("Cumulative", prev))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .symbolSize(30)
                }
            } else if let last = curLine.last {
                PointMark(x: .value("Position", last.x), y: .value("Cumulative", last.y))
                    .foregroundStyle(line)
                    .symbolSize(56)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...yMax)
        .chartHover(Double.self) { x, p in hover(x, p) }
        .chartXAxis(axes ? .automatic : .hidden)
        .chartYAxis(axes ? .automatic : .hidden)
        .chartXAxis {
            AxisMarks(values: [0, 0.5, 1]) { value in
                AxisValueLabel(anchor: xAnchor(value.as(Double.self) ?? 0)) {
                    Text(xLabel(value.as(Double.self) ?? 0)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartYAxis {
            // The cumulative curve starts bottom left, so the top left is always empty; ticks on the left never cover the curve
            AxisMarks(position: .leading, values: [yMax / 1.08 * 0.5, yMax / 1.08]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    Text(Fmt.metric(value.as(Double.self) ?? 0, metric, exact: false))
                        .font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Cumulative value of the previous period at the same horizontal position (linear interpolation)
    private func previousValue(at x: Double) -> Double? {
        guard let prev = previous, prev.count > 1 else { return nil }
        let line = resampled(prev, count: 200)
        return line.min { abs($0.x - x) < abs($1.x - x) }?.y
    }

    private func hover(_ x: Double?, _ p: CGPoint) {
        let tipID = "hero"
        selectedX = x
        guard x != nil, let point = selected else { tip?.hide(tipID); return }
        let prev = previousValue(at: point.x)
        let exact = settings.exactNumbers
        tip?.show(tipID, at: p) {
            TipCard(title: report.range == .day ? L("Today \(point.label)") : point.label) {
                TipRow(color: line, label: report.range == .day ? L("This half-hour") : L("This day"), value: Fmt.metric(point.value, metric, exact: exact))
                TipRow(label: L("Cumulative so far"), value: Fmt.metric(point.y, metric, exact: exact))
                if let prev {
                    TipRow(color: Color.white.opacity(0.35), label: report.range == .ytd ? L("Same point last year") : report.range == .day ? L("Same point yesterday (even pace)") : L("Same point previous period"),
                           value: Fmt.metric(prev, metric, exact: false),
                           secondary: prev > 0 ? String(format: "%@%.0f%%", point.y >= prev ? "+" : "−", abs(point.y - prev) / prev * 100) : nil)
                }
            }
        }
    }

    private func xAnchor(_ x: Double) -> UnitPoint {
        x == 0 ? .topLeading : x == 1 ? .topTrailing : .top
    }

    private func xLabel(_ x: Double) -> String {
        if report.range == .day { return x == 0 ? "0:00" : x == 1 ? "24:00" : "12:00" }
        let days = report.days
        guard !days.isEmpty else { return "" }
        if x >= 1 { return L("Today") }
        let i = Int((x * Double(days.count - 1)).rounded())
        return Fmt.shortDate(days[min(days.count - 1, i)].date)
    }

    /// "49.59 B" → ("49.59", "B"); plain exact numbers get the unit "tokens"
    static func split(_ text: String, metric: UsageMetric) -> (number: String, unit: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (text, metric == .tokens ? "tokens" : "")
    }
}

/// Change chip: arrow plus text, colour is only a cue (direction never relies on colour alone)
struct DeltaChip: View {
    let percent: Double

    var body: some View {
        let flat = abs(percent) < 0.5
        let up = percent > 0
        let color = flat ? Color.secondary : (up ? Palette.up : Palette.down)
        Text("\(flat ? "■" : up ? "▲" : "▼") \(String(format: "%.1f%%", abs(percent)))")
            .font(.app(Typo.small, .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .glassEffect(.regular.tint((flat ? Color.gray : (up ? Palette.up : Palette.down)).opacity(0.22)), in: .capsule)
    }
}
