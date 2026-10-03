import SwiftUI
import Core
import DesignSystem

// MARK: - This month's cost: cumulative + month-end projection + last month reference

/// What this month has cost so far, adding up day by day against last month's curve, with where the
/// month is heading at the current pace. Hovering a day shows that day's cost and its models.
struct CostCard: View {
    let month: RangeAnalytics.MonthCost
    let colors: ModelColors
    let summary: (String) -> DailyHistoryArchive.DaySummary
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var selected: Int?
    @State private var flipped = false
    @State private var hovering = false
    @Environment(\.cardSize) private var cardSize

    private var accent: Color { settings.accent("card.cost", .blue) }
    private static let tipID = "cost"

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.cost.localizedName) · Settings"), accentKey: "card.cost", accentDefault: .blue,
                     onHide: { settings.setVisible(.cost, false) }, done: { flipped = false }) {
                OptionRow(L("Month-end projection")) { MiniToggle(isOn: $settings.costShowProjection) }
                OptionRow(L("Last month's total line")) { MiniToggle(isOn: $settings.costShowLastMonth) }
                OptionRow(L("Daily cost bars")) { MiniToggle(isOn: $settings.costShowDailyBars) }
            }
        }
    }

    /// The month's numbers, laid out for the chart
    private struct Figures {
        /// This month so far, adding up: x is the end of each day across the whole month (0…1)
        let points: [(x: Double, y: Double)]
        /// Each day's own cost
        let daily: [Double]
        /// Last month adding up, across its own length (0…1)
        let comparison: [(x: Double, y: Double)]
        /// Last month's total through the same day of the month; nil without a last month
        let lastAtSameDay: Double?
        let spent: Double
        let top: Double
        /// Month start, middle and end
        let labels: [String]
    }

    private var figures: Figures {
        let days = month.days
        let span = Double(max(1, month.daysInMonth))
        let points = days.enumerated().map { (x: Double($0.offset + 1) / span, y: $0.element.cumulative) }
        let spent = days.last?.cumulative ?? 0
        // Last month, day by day, from the archive
        var comparison: [(x: Double, y: Double)] = []
        if let first = days.first?.date {
            let cal = Calendar.current
            let start = cal.date(byAdding: .month, value: -1, to: RangeAnalytics.date(first))!
            let count = cal.range(of: .day, in: .month, for: start)?.count ?? 30
            var acc = 0.0
            comparison = (0..<count).map { i in
                acc += summary(Fmt.dayKey(cal.date(byAdding: .day, value: i, to: start)!)).cost
                return (x: Double(i + 1) / Double(count), y: acc)
            }
        }
        let lastAtSameDay: Double? = month.lastMonthTotal > 0 && !comparison.isEmpty
            ? comparison[min(comparison.count - 1, max(0, days.count - 1))].y : nil
        let top = max(settings.costShowProjection ? month.projected : 0,
                      settings.costShowLastMonth ? month.lastMonthTotal : 0, spent, 1) * 1.1
        var labels: [String] = []
        if let first = days.first?.date {
            let cal = Calendar.current
            let startDate = RangeAnalytics.date(first)
            labels = [0, month.daysInMonth / 2, month.daysInMonth - 1].map { Fmt.shortDate(Fmt.dayKey(cal.date(byAdding: .day, value: $0, to: startDate)!)) }
        }
        return Figures(points: points, daily: days.map(\.cost), comparison: comparison, lastAtSameDay: lastAtSameDay,
                       spent: spent, top: top, labels: labels)
    }

    private var front: some View {
        let f = figures
        // 1×1 has no room for the settings button beside the title: it appears while the pointer is over the card
        let header = WidgetHeader(SettingsStore.Card.cost.localizedName, icon: SettingsStore.Card.cost.icon, tint: accent,
                                  onSettings: cardSize != .small || hovering ? { flipped = true } : nil) {
            // Large and wide list last month among the facts
            if cardSize == .medium, settings.costShowLastMonth, month.lastMonthTotal > 0 {
                Text("Last month \(Fmt.money(month.lastMonthTotal))")
            } else if cardSize == .large || cardSize == .wide {
                Text(Fmt.monthName(Date()))
            }
        }
        return Group {
            switch cardSize {
            case .small:
                // 1×1: the amount, a line of context, each day's cost as a small line
                VStack(alignment: .leading, spacing: 2) {
                    header
                    MoneyNumber(f.spent, size: WidgetStyle.number(.small))
                    subline(f)
                    SparkLine(values: f.daily, color: accent, tipID: Self.tipID, tip: { i in AnyView(dayTip(i, f)) })
                        .frame(maxHeight: .infinity)
                        .padding(.top, 6)
                }
            case .medium:
                // 2×1: amount and change on the left, the curve without axes on the right
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            MoneyNumber(f.spent, size: WidgetStyle.number(.medium))
                            subline(f)
                            Spacer(minLength: 0)
                            delta(f)
                        }
                        .frame(width: 140, alignment: .leading)
                        chart(f, axes: false, labels: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .large:
                // 2×2: amount, the curve with axes, three facts
                VStack(alignment: .leading, spacing: 8) {
                    header
                    VStack(alignment: .leading, spacing: 3) {
                        MoneyNumber(f.spent, size: WidgetStyle.number(.large))
                        HStack(spacing: 6) {
                            delta(f)
                            subline(f)
                        }
                    }
                    chart(f, axes: true, labels: false)
                        .frame(maxHeight: .infinity)
                    FactsRow(facts(f))
                }
            case .wide:
                // 4×2: amount, change and facts in a column on the left, the full chart on the right
                VStack(alignment: .leading, spacing: 8) {
                    header
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 4) {
                            MoneyNumber(f.spent, size: WidgetStyle.number(.wide))
                            HStack(spacing: 6) {
                                delta(f)
                                subline(f)
                            }
                            Spacer(minLength: 10)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(facts(f).enumerated()), id: \.offset) { _, fact in Fact(label: fact.0, value: fact.1) }
                            }
                        }
                        .frame(width: 190, alignment: .leading)
                        chart(f, axes: true, labels: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large || cardSize == .wide ? 2 : 0), radius: 18)
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }

    /// "Projected $120" while the month runs, else how far into the month we are
    private func subline(_ f: Figures) -> some View {
        Group {
            if settings.costShowProjection, month.projected > f.spent * 1.005, cardSize == .small || cardSize == .medium {
                Text("Projected \(Fmt.money(month.projected))")
            } else {
                Text("\(month.days.count) / \(month.daysInMonth) days")
            }
        }
        .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
    }

    /// Change against last month at the same day (a rise in cost is the bad direction)
    @ViewBuilder
    private func delta(_ f: Figures) -> some View {
        if let before = f.lastAtSameDay, before > 0 {
            DeltaChip(percent: (f.spent - before) / before * 100, invert: true)
                .help("Compared with last month through the same day")
        }
    }

    private func facts(_ f: Figures) -> [(String, String)] {
        var out: [(String, String)] = []
        if settings.costShowProjection { out.append((L("Projected"), Fmt.money(month.projected))) }
        if month.lastMonthTotal > 0 { out.append((L("Last month"), Fmt.money(month.lastMonthTotal))) }
        out.append((L("Daily avg"), Fmt.money(f.spent / Double(max(1, month.days.count)))))
        if out.count < 3, let top = month.days.max(by: { $0.cost < $1.cost }), top.cost > 0 {
            out.append((L("Peak · \(Fmt.shortDate(top.date))"), Fmt.money(top.cost)))
        }
        return out
    }

    private func chart(_ f: Figures, axes: Bool, labels: Bool) -> some View {
        let palette = AreaChart.colors(for: accent)
        let running = f.points.count < month.daysInMonth
        return AreaChart(points: f.points, comparison: settings.costShowLastMonth ? f.comparison : [], top: f.top, axes: axes,
                         format: ChartAxis.money, xLabels: labels ? f.labels : [], selected: selected,
                         line: palette.line, area: palette.area,
                         bars: settings.costShowDailyBars && axes ? f.daily : nil,
                         projection: settings.costShowProjection && running ? (x: 1, y: month.projected) : nil,
                         rule: settings.costShowLastMonth && axes && month.lastMonthTotal > 0 ? (month.lastMonthTotal, L("Last month")) : nil) { i, p in
            selected = i
            guard let i, i < month.days.count else { tip?.hide(Self.tipID); return }
            tip?.show(Self.tipID, key: month.days[i].date, at: p, glide: true) { dayTip(i, f) }
        }
        .animation(Motion.data, value: "\(settings.costShowProjection)|\(settings.costShowLastMonth)|\(settings.costShowDailyBars)|\(month.days.count)")
    }

    /// One day's readout: its cost, the month so far, last month at the same point, the day's models
    private func dayTip(_ i: Int, _ f: Figures) -> some View {
        let point = month.days[i]
        let day = summary(point.date)
        let avg = f.spent / Double(max(1, month.days.count))
        let models = day.costByModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let before = f.comparison.indices.contains(i) ? f.comparison[i].y : nil
        return TipCard(title: DayDetailTip.dateTitle(point.date), subtitle: avg > 0 && point.cost > 0 ? deviation(point.cost, avg) : nil,
                       icon: SettingsStore.Card.cost.icon, tint: accent, value: Fmt.money(point.cost)) {
            TipRow(label: L("Month to date"), value: Fmt.money(point.cumulative))
            if let before, settings.costShowLastMonth, month.lastMonthTotal > 0 {
                TipRow(label: L("Last month, same day"), value: Fmt.money(before))
            }
            if !models.isEmpty {
                Divider().overlay(Palette.hairline)
                TipBar(parts: models.map { (colors.color($0.key), $0.value) })
                ForEach(models.prefix(4), id: \.key) { m, c in
                    TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.money(c),
                           secondary: percent(c / max(1e-9, point.cost)))
                }
            }
        }
    }

    private func deviation(_ cost: Double, _ avg: Double) -> String {
        let pct = String(format: "%.0f%%", abs(cost - avg) / avg * 100)
        return cost >= avg ? L("\(pct) above this month's daily avg") : L("\(pct) below this month's daily avg")
    }
}
