import SwiftUI
import Charts
import Core
import DesignSystem

/// Metrics a stat tile can show. Each uses a different mini chart so no two tiles look alike.
enum StatKind: String, CaseIterable, Identifiable {
    case average, peak, active, perMillion, totalCost, messages, topModel, weekday
    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .average: L("Daily average")
        case .peak: L("Peak day")
        case .active: L("Active days")
        case .perMillion: L("Per million tokens")
        case .totalCost: L("Total cost")
        case .messages: L("Message count")
        case .topModel: L("Top model")
        case .weekday: L("Busiest weekday")
        }
    }

    var icon: String {
        switch self {
        case .average: "chart.bar.xaxis"
        case .peak: "arrow.up.to.line"
        case .active: "calendar"
        case .perMillion: "dollarsign.circle"
        case .totalCost: "creditcard"
        case .messages: "bubble.left.and.bubble.right"
        case .topModel: "cpu"
        case .weekday: "calendar.day.timeline.left"
        }
    }

    /// Explanation on the back
    var explain: String {
        switch self {
        case .average: L("Average daily usage over the selected range; the small text averages only days with usage. Bars above the dashed line are days above the daily average.")
        case .peak: L("The days with the highest usage. Hover to see that day's models and tools.")
        case .active: L("Days with usage, the current streak and the longest streak; each cell is one day.")
        case .perMillion: L("Cost per million tokens at list prices; the curve shows each day. More cache reads make it cheaper.")
        case .totalCost: L("Total cost over the selected range at list prices (not actual spend on a subscription).")
        case .messages: L("Number of model replies and the average tokens per reply.")
        case .topModel: L("The model with the most usage; the bar below shows each model's share.")
        case .weekday: L("Average daily usage by weekday; the tallest bar is the busiest weekday.")
        }
    }

    var defaultAccent: Accent {
        // Usage and cost = blue, activity = green, messages = indigo (also cool), top model = terracotta (follows the model)
        switch self {
        case .average, .peak, .perMillion, .totalCost: .blue
        case .messages: .indigo
        case .active, .weekday: .green
        case .topModel: .claude
        }
    }
}

// MARK: - Stat widgets

/// A stat widget. Small (1×1): value + its own mini chart; medium (2×1): value and details on the left, a larger chart on the right.
/// Back: colour, size, hide.
struct StatTile: View {
    let kind: StatKind
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @Environment(\.cardSize) private var cardSize
    @State private var flipped = false
    @State private var hovering = false

    private var accentKey: String { "tile.\(kind.rawValue)" }
    private var accent: Color { settings.accent(accentKey, kind.defaultAccent) }
    private var tipID: String { "tile.\(kind.rawValue)" }
    private var card: SettingsStore.Card { SettingsStore.Card(rawValue: "stat." + kind.rawValue) ?? .statAverage }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: kind.localizedName, accentKey: accentKey, accentDefault: kind.defaultAccent,
                     onHide: { settings.setVisible(card, false) }, padding: 12, radius: 18, done: { flipped = false }) {
                Text(kind.explain).font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Front

    private var header: some View {
        WidgetHeader(kind.localizedName, icon: kind.icon, tint: accent, onSettings: hovering ? { flipped = true } : nil)
    }

    private var front: some View {
        let content = tileContent
        return Group {
            if cardSize == .small {
                // 1×1: number at the top, one line of detail below, mini chart fills the bottom
                VStack(alignment: .leading, spacing: 2) {
                    header
                    value(content.value, size: WidgetStyle.number(.small))
                    Text(content.sub).font(.app(Typo.small)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail).monospacedDigit()
                    chart(detail: false)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 8)
                }
            } else {
                // 2×1: number + two facts on the left, a larger chart on the right
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 0) {
                            value(content.value, size: WidgetStyle.number(.medium))
                            Spacer(minLength: 4)
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(details.enumerated()), id: \.offset) { _, f in Fact(label: f.0, value: f.1) }
                            }
                        }
                        .frame(width: 168, alignment: .leading)
                        chart(detail: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .glassCard(padding: WidgetStyle.padding, radius: 18, tint: accent)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    /// The two facts shown at medium size
    private var details: [(String, String)] {
        let s = report.stats
        let days = report.days
        switch kind {
        case .average:
            let sorted = days.map(\.tokens).filter { $0 > 0 }.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            return [(L("Active-day avg"), Fmt.tokens(s.averagePerActiveDay, exact: false)), (L("Median"), Fmt.tokens(Double(median), exact: false))]
        case .peak:
            guard let peak = s.peak else { return [] }
            let ratio = s.averagePerDay > 0 ? Double(peak.tokens) / s.averagePerDay : 0
            return [(L("Date"), Fmt.shortDate(peak.date)), (L("vs daily avg"), L("\(String(format: "%.1f", ratio))×"))]
        case .active:
            return [(L("Current streak"), L("\(s.streak) d")), (L("Longest streak"), L("\(longestStreak) d"))]
        case .perMillion:
            let rates = days.filter { $0.tokens > 0 }.map { $0.cost / (Double($0.tokens) / 1e6) }
            return [(L("Lowest day"), Fmt.money(rates.min() ?? 0)), (L("Highest day"), Fmt.money(rates.max() ?? 0))]
        case .totalCost:
            return [(L("Daily avg"), Fmt.money(s.totalCost / Double(max(1, s.totalDays)))), (L("Highest day"), Fmt.money(days.map(\.cost).max() ?? 0))]
        case .messages:
            let messages = days.reduce(0) { $0 + $1.messages }
            let tokens = days.reduce(0) { $0 + $1.tokens }
            return [(L("Per message"), messages > 0 ? Fmt.tokens(Double(tokens) / Double(messages), exact: false) : "—"),
                    (L("Daily avg"), L("\(messages / max(1, s.totalDays)) msgs"))]
        case .topModel:
            guard let top = report.models.first else { return [] }
            let total = max(1, report.models.reduce(0) { $0 + $1.tokens })
            return [(L("Share"), percent(Double(top.tokens) / Double(total))), (L("Model count"), String(report.models.count))]
        case .weekday:
            let avg = weekdayAverages
            let active = avg.indices.filter { avg[$0] > 0 }
            let low = active.min { avg[$0] < avg[$1] }
            let best = avg.indices.max { avg[$0] < avg[$1] }
            return [(L("Avg per day"), best.map { Fmt.tokens(avg[$0], exact: false) } ?? "—"), (L("Quietest"), low.map { Fmt.weekdaysFromMonday[$0] } ?? "—")]
        }
    }

    private func value(_ text: String, size: CGFloat) -> some View {
        BigNumber(text, size: kind == .topModel ? size * 0.8 : size, color: kind == .topModel ? accent : .primary)
    }

    private var tileContent: (value: String, sub: String) {
        let s = report.stats
        switch kind {
        case .average:
            return (Fmt.tokens(s.averagePerDay, exact: exact), L("Active-day avg \(Fmt.tokens(s.averagePerActiveDay, exact: exact))"))
        case .peak:
            guard let peak = s.peak else { return ("—", L("No usage in range")) }
            let ratio = s.averagePerDay > 0 ? Double(peak.tokens) / s.averagePerDay : 0
            return (Fmt.tokens(Double(peak.tokens), exact: exact),
                    L("\(Fmt.shortDate(peak.date)) · \(String(format: "%.1f", ratio))× daily avg"))
        case .active:
            return ("\(s.activeDays) / \(s.totalDays)", L("Streak \(s.streak) d · longest \(longestStreak) d"))
        case .perMillion:
            return (Fmt.money(s.costPerMillion), L("Total \(Fmt.money(s.totalCost))"))
        case .totalCost:
            return (Fmt.money(s.totalCost), L("Daily avg \(Fmt.money(s.totalCost / Double(max(1, s.totalDays))))"))
        case .messages:
            let messages = report.days.reduce(0) { $0 + $1.messages }
            let tokens = report.days.reduce(0) { $0 + $1.tokens }
            return (Fmt.metric(Double(messages), .messages, exact: true),
                    messages > 0 ? L("~\(Fmt.tokens(Double(tokens) / Double(messages), exact: false)) tokens per message") : L("No messages in range"))
        case .topModel:
            guard let top = report.models.first else { return ("—", L("No usage in range")) }
            let total = max(1, report.models.reduce(0) { $0 + $1.tokens })
            return (colors.name(top.key), L("\(percent(Double(top.tokens) / Double(total))) share · \(report.models.count) models"))
        case .weekday:
            let avg = weekdayAverages
            guard let best = avg.indices.max(by: { avg[$0] < avg[$1] }), avg[best] > 0 else { return ("—", L("No usage in range")) }
            return (Fmt.weekdaysFromMonday[best], L("Avg per day \(Fmt.tokens(avg[best], exact: exact))"))
        }
    }

    @ViewBuilder private func chart(detail: Bool) -> some View {
        switch kind {
        case .average:
            MiniBars(values: report.days.map { Double($0.tokens) }, color: accent, average: report.stats.averagePerDay) { i, p in
                hoverDay(i, p)
            }
        case .peak:
            TopDays(days: report.days, color: accent, exact: exact, count: detail ? 5 : 3) { day, p in
                if let day, let p {
                    tip?.show(tipID, at: p) { DayDetailTip(day: day, colors: colors, exact: exact) }
                } else { tip?.hide(tipID) }
            }
        case .active:
            DayStrip(days: Array(report.days.suffix(detail ? 120 : 60)), color: accent) { day, p in
                if let day, let p {
                    tip?.show(tipID, at: p) { DayDetailTip(day: day, colors: colors, exact: exact) }
                } else { tip?.hide(tipID) }
            }
        case .perMillion:
            Sparkline(values: report.days.map { $0.tokens > 0 ? $0.cost / (Double($0.tokens) / 1e6) : 0 }, color: accent) { i, p in
                showValue(i, p) { L("\(Fmt.money(report.days[$0].tokens > 0 ? report.days[$0].cost / (Double(report.days[$0].tokens) / 1e6) : 0)) / 1M") }
            }
        case .totalCost:
            MiniBars(values: report.days.map(\.cost), color: accent,
                     average: report.stats.totalCost / Double(max(1, report.days.count))) { i, p in
                showValue(i, p) { Fmt.money(report.days[$0].cost) }
            }
        case .messages:
            Sparkline(values: report.days.map { Double($0.messages) }, color: accent) { i, p in
                showValue(i, p) { Fmt.metric(Double(report.days[$0].messages), .messages, exact: true) }
            }
        case .topModel:
            let total = Double(max(1, report.models.reduce(0) { $0 + $1.tokens }))
            ProportionBar(parts: report.models.prefix(6).map { (colors.color($0.key), Double($0.tokens)) },
                          height: detail ? 10 : 8) { i, p in
                if let i, let p {
                    let share = report.models[i]
                    tip?.show(tipID, at: p) {
                        TipCard(title: colors.name(share.key), subtitle: ModelPalette.vendor(share.key).localizedName) {
                            TipRow(color: colors.color(share.key), label: "Tokens", value: Fmt.tokens(Double(share.tokens), exact: exact),
                                   secondary: percent(Double(share.tokens) / total))
                            TipRow(label: L("Cost"), value: Fmt.money(share.cost))
                        }
                    }
                } else { tip?.hide(tipID) }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        case .weekday:
            WeekdayBars(values: weekdayAverages, color: accent) { i, p in
                if let i, let p {
                    tip?.show(tipID, at: p) {
                        TipCard(title: Fmt.weekdaysFromMonday[i], subtitle: L("\(report.range.localizedLabel) · avg per day")) {
                            TipRow(color: accent, label: "Tokens", value: Fmt.tokens(weekdayAverages[i], exact: exact))
                        }
                    }
                } else { tip?.hide(tipID) }
            }
        }
    }

    private func hoverDay(_ i: Int?, _ p: CGPoint?) {
        guard let i, let p, report.days.indices.contains(i) else { tip?.hide(tipID); return }
        let day = report.days[i]
        let avg = report.stats.averagePerDay
        let delta = avg > 0 ? (Double(day.tokens) - avg) / avg * 100 : 0
        tip?.show(tipID, at: p) {
            DayDetailTip(day: day, colors: colors, exact: exact,
                         note: day.tokens > 0 ? deltaNote(delta) : nil)
        }
    }

    private func deltaNote(_ delta: Double) -> String {
        let pct = String(format: "%.0f%%", abs(delta))
        return delta >= 0 ? L("\(pct) above daily avg") : L("\(pct) below daily avg")
    }

    private func showValue(_ i: Int?, _ p: CGPoint?, _ text: @escaping (Int) -> String) {
        guard let i, let p, report.days.indices.contains(i) else { tip?.hide(tipID); return }
        tip?.show(tipID, at: p) {
            TipCard(title: DayDetailTip.dateTitle(report.days[i].date)) {
                TipRow(color: accent, label: kind.localizedName, value: text(i))
            }
        }
    }

    /// Daily average for Monday…Sunday (each weekday's total in the range / its number of occurrences)
    private var weekdayAverages: [Double] {
        var sum = Array(repeating: 0.0, count: 7), count = Array(repeating: 0, count: 7)
        let cal = Calendar.current
        for d in report.days {
            let w = (cal.component(.weekday, from: RangeAnalytics.date(d.date)) + 5) % 7
            sum[w] += Double(d.tokens)
            count[w] += 1
        }
        return (0..<7).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : 0 }
    }

    private var longestStreak: Int {
        var best = 0, run = 0
        for d in report.days {
            run = d.tokens > 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }
}

// MARK: - Mini charts

/// Mini trend (line + fading area). A fixed 40 points, so changing the range morphs point by point instead of redrawing the whole line
struct Sparkline: View {
    let values: [Double]
    var color: Color = .white
    var height: CGFloat? = nil
    /// Hover: index in the original series + pointer position
    var onHover: ((Int?, CGPoint?) -> Void)? = nil
    @State private var hovered: Int?

    private var points: [(x: Double, y: Double)] {
        let raw = values.enumerated().map { (Double($0.offset), $0.element) }
        return resampled(raw.isEmpty ? [(0, 0)] : raw, count: 40)
    }

    var body: some View {
        let pts = points
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("i", p.x), y: .value("v", p.y))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", p.x), y: .value("v", p.y))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            if let hovered, values.indices.contains(hovered) {
                RuleMark(x: .value("i", Double(hovered))).foregroundStyle(Color.white.opacity(0.25))
                PointMark(x: .value("i", Double(hovered)), y: .value("v", values[hovered])).foregroundStyle(color).symbolSize(26)
            } else if let last = pts.last {
                PointMark(x: .value("i", last.x), y: .value("v", last.y)).foregroundStyle(color).symbolSize(14)
            }
        }
        .chartXScale(domain: 0...Double(max(1, values.count - 1)))
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartHover(Double.self) { x, p in
            guard let onHover else { return }
            let i = x.map { Int($0.rounded()) }.flatMap { values.indices.contains($0) ? $0 : nil }
            hovered = i
            onHover(i, i == nil ? nil : p)
        }
        .frame(height: height)
    }
}

/// Daily mini bars + average line (daily avg, total cost): bars below the average are fainter
struct MiniBars: View {
    let values: [Double]
    let color: Color
    let average: Double
    var onHover: ((Int?, CGPoint?) -> Void)? = nil
    @State private var hovered: Int?

    var body: some View {
        let maxValue = max(1e-9, values.max() ?? 0)
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                let half = values.count > 60 ? 0.45 : 0.33
                RectangleMark(xStart: .value("Day", Double(i) - half), xEnd: .value("Day", Double(i) + half),
                              yStart: .value("Value", 0), yEnd: .value("Value", max(v, maxValue * 0.02)))
                    .foregroundStyle(v <= 0 ? Color.white.opacity(0.1) : color.opacity(hovered == i ? 1 : v >= average ? 0.85 : 0.4))
                    .cornerRadius(values.count > 60 ? 0.5 : 1.5)
            }
            RuleMark(y: .value("Average", average))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXScale(domain: -0.6...(Double(values.count) - 0.4))
        .chartYScale(domain: 0...(maxValue * 1.05))
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartHover(Double.self) { x, p in
            let i = x.map { Int($0.rounded()) }.flatMap { values.indices.contains($0) ? $0 : nil }
            hovered = i
            onHover?(i, i == nil ? nil : p)
        }
        .animation(.smooth(duration: 0.4), value: values.count)
    }
}

/// Peak days: the three highest-usage days in the range, bars scaled to the peak
struct TopDays: View {
    let days: [DailyHistoryArchive.DaySummary]
    let color: Color
    let exact: Bool
    var count = 3
    var onHover: ((DailyHistoryArchive.DaySummary?, CGPoint?) -> Void)? = nil

    var body: some View {
        let top = days.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }.prefix(count)
        let peak = Double(top.first?.tokens ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(top.enumerated()), id: \.element.date) { rank, d in
                HStack(spacing: 5) {
                    Text(Fmt.shortDate(d.date)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(rank == 0 ? 1 : 0.5))
                            .frame(width: max(3, geo.size.width * Double(d.tokens) / peak))
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 5)
                }
                .frame(height: 9)
                .contentShape(Rectangle())
                .dashboardHover { p in onHover?(p == nil ? nil : d, p) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.4), value: top.map(\.date))
    }
}

/// Active days: one cell per day (active = solid, idle = empty track). Drawn in one pass (Canvas); hover maps coordinates to a date
struct DayStrip: View {
    let days: [DailyHistoryArchive.DaySummary]
    var color: Color = Palette.activity
    var onHover: ((DailyHistoryArchive.DaySummary?, CGPoint?) -> Void)? = nil
    @State private var hovered: Int?
    @State private var progress = 0.0

    var body: some View {
        GeometryReader { geo in
            let n = max(1, days.count)
            let step = geo.size.width / CGFloat(n)
            DayStripCanvas(active: days.map { $0.tokens > 0 }, color: color, hovered: hovered, progress: progress)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase else { hovered = nil; onHover?(nil, nil); return }
                    let i = min(days.count - 1, max(0, Int(p.x / step)))
                    guard days.indices.contains(i) else { return }
                    hovered = i
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    onHover?(days[i], CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                }
        }
        .onAppear { withAnimation(.smooth(duration: 0.7)) { progress = 1 } }
    }
}

private struct DayStripCanvas: View, Animatable {
    let active: [Bool]
    let color: Color
    let hovered: Int?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = max(1, active.count)
            let gap: CGFloat = n > 60 ? 1 : 2
            let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for (i, on) in active.enumerated() {
                let t = min(1, max(0, (progress - Double(i) / Double(n) * 0.4) / 0.6))
                let full = min(size.height, 28)
                let h = (on ? full * (hovered == i ? 1 : 0.8) : full * 0.25) * t
                guard h > 0 else { continue }
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                let fill = on ? color.opacity(hovered == i ? 1 : 0.85) : Color.white.opacity(hovered == i ? 0.2 : 0.08)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, w / 2)), with: .color(fill))
            }
        }
    }
}

/// Average bars for Monday…Sunday; the tallest is solid
struct WeekdayBars: View {
    let values: [Double]
    let color: Color
    var onHover: ((Int?, CGPoint?) -> Void)? = nil
    @State private var hovered: Int?

    var body: some View {
        let maxValue = max(1e-9, values.max() ?? 0)
        let best = values.indices.max { values[$0] < values[$1] }
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color.opacity(i == best || i == hovered ? 1 : 0.4))
                            .frame(height: max(2, geo.size.height * values[i] / maxValue))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    Text(Fmt.weekdayInitialsFromMonday[i]).font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .dashboardHover { p in
                    hovered = p == nil ? (hovered == i ? nil : hovered) : i
                    onHover?(p == nil ? nil : i, p)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: values)
    }
}
