import SwiftUI
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

/// A stat widget. Small (1×1): the number, one line of context and a small chart at the bottom; medium (2×1):
/// the number and its context on the left, a taller chart on the right. Back: colour, size, hide.
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
    private var medium: Bool { cardSize != .small }

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
        Group {
            if medium {
                // 2×1: number and context on the left, the chart fills the right
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            number(size: WidgetStyle.number(.medium))
                            subline
                            Spacer(minLength: 0)
                            secondaryLine
                        }
                        .frame(minWidth: 120, maxWidth: 150, alignment: .leading)
                        .layoutPriority(1)
                        visual
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                // 1×1: number, one line of context, a small chart along the bottom
                VStack(alignment: .leading, spacing: 3) {
                    header
                    number(size: WidgetStyle.number(.small))
                    subline
                    Spacer(minLength: 2)
                    visual
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .glassCard(padding: WidgetStyle.padding, radius: 18, tint: accent)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    // MARK: Number

    @ViewBuilder private func number(size: CGFloat) -> some View {
        switch kind {
        case .perMillion: MoneyNumber(stats.costPerMillion, size: size)
        case .totalCost: MoneyNumber(stats.totalCost, size: size)
        case .topModel: topModelName(size: size)
        default: BigNumber(headline.text, size: size, value: headline.value)
        }
    }

    private var stats: RangeReport.Stats { report.stats }
    private var days: [DailyHistoryArchive.DaySummary] { report.days }
    private var messages: Int { days.reduce(0) { $0 + $1.messages } }
    private var tokens: Int { days.reduce(0) { $0 + $1.tokens } }
    private var topModel: RangeReport.Share? { report.models.first }
    private var modelTotal: Double { Double(max(1, report.models.reduce(0) { $0 + $1.tokens })) }

    /// The big number as text, with the value behind it for the digits' transition
    private var headline: (text: String, value: Double?) {
        switch kind {
        case .average: (Fmt.tokens(stats.averagePerDay, exact: exact), stats.averagePerDay)
        case .peak: stats.peak.map { (Fmt.tokens(Double($0.tokens), exact: exact), Double($0.tokens)) } ?? ("—", nil)
        case .active: ("\(stats.activeDays) / \(stats.totalDays)", Double(stats.activeDays))
        case .messages: (Fmt.exact(messages), Double(messages))
        case .weekday: (busiestWeekday.map { Fmt.weekdaysFromMonday[$0] } ?? "—", nil)
        case .perMillion, .totalCost, .topModel: ("", nil)
        }
    }

    /// The top model's name beside its mark, in text colour; the mark wears the model's colour
    @ViewBuilder private func topModelName(size: CGFloat) -> some View {
        if let top = topModel {
            HStack(spacing: 6) {
                EntityMark(logo: BrandLogos.model(top.key), color: colors.color(top.key), size: size * 0.6)
                Text(colors.name(top.key)).font(.app(size * 0.68, .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6).truncationMode(.middle)
            }
            .frame(height: size * 1.2)
        } else {
            BigNumber("—", size: size)
        }
    }

    // MARK: Context lines

    private var subline: some View {
        Text(subText).font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
    }

    private var subText: String {
        switch kind {
        case .average:
            return L("Active-day avg \(Fmt.tokens(stats.averagePerActiveDay, exact: exact))")
        case .peak:
            guard let peak = stats.peak else { return L("No usage in range") }
            return L("\(Fmt.shortDate(peak.date)) · \(String(format: "%.1f", peakRatio))× daily avg")
        case .active:
            return L("Streak \(stats.streak) d · longest \(longestStreak) d")
        case .perMillion:
            return L("Total \(Fmt.money(stats.totalCost))")
        case .totalCost:
            return L("Daily avg \(Fmt.money(stats.totalCost / Double(max(1, stats.totalDays))))")
        case .messages:
            return messages > 0 ? L("~\(Fmt.tokens(Double(tokens) / Double(messages), exact: false)) tokens per message") : L("No messages in range")
        case .topModel:
            guard let top = topModel else { return L("No usage in range") }
            return L("\(percent(Double(top.tokens) / modelTotal)) share · \(report.models.count) models")
        case .weekday:
            guard let best = busiestWeekday else { return L("No usage in range") }
            return L("Avg per day \(Fmt.tokens(weekdays[best].average, exact: exact))")
        }
    }

    /// Medium only: the change against the previous period, or one more fact when there is none
    @ViewBuilder private var secondaryLine: some View {
        let line = secondary
        HStack(spacing: 6) {
            if let delta = line.delta {
                DeltaChip(percent: delta, invert: line.invert)
            }
            Text(line.text).font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
        }
        .frame(height: 18)
    }

    private var secondary: (delta: Double?, invert: Bool, text: String) {
        let vs = L("vs previous period")
        let previous = report.previousDays ?? []
        let prevTokens = previous.reduce(0) { $0 + $1.tokens }
        let prevCost = previous.reduce(0) { $0 + $1.cost }
        switch kind {
        case .average:
            if let d = change(stats.averagePerDay, previous.isEmpty ? nil : Double(prevTokens) / Double(previous.count)) { return (d, false, vs) }
            let sorted = days.map(\.tokens).filter { $0 > 0 }.sorted()
            return (nil, false, "\(L("Median")) \(Fmt.tokens(Double(sorted.isEmpty ? 0 : sorted[sorted.count / 2]), exact: false))")
        case .peak:
            if let peak = stats.peak, let d = change(Double(peak.tokens), previous.map(\.tokens).max().map(Double.init)) { return (d, false, vs) }
            return (nil, false, stats.peak.map { Fmt.longDate($0.date) } ?? "")
        case .active:
            if let d = change(Double(stats.activeDays), previous.isEmpty ? nil : Double(previous.filter { $0.tokens > 0 }.count)) { return (d, false, vs) }
            return (nil, false, "\(L("Longest streak")) \(L("\(longestStreak) d"))")
        case .perMillion:
            if let d = change(stats.costPerMillion, prevTokens > 0 ? prevCost / (Double(prevTokens) / 1e6) : nil) { return (d, true, vs) }
            let rates = days.filter { $0.tokens > 0 }.map { $0.cost / (Double($0.tokens) / 1e6) }
            return (nil, true, "\(L("Lowest day")) \(Fmt.money(rates.min() ?? 0))")
        case .totalCost:
            if let d = change(stats.totalCost, previous.isEmpty ? nil : prevCost) { return (d, true, vs) }
            return (nil, true, "\(L("Highest day")) \(Fmt.money(days.map(\.cost).max() ?? 0))")
        case .messages:
            if let d = change(Double(messages), previous.isEmpty ? nil : Double(previous.reduce(0) { $0 + $1.messages })) { return (d, false, vs) }
            return (nil, false, "\(L("Daily avg")) \(L("\(messages / max(1, stats.totalDays)) msgs"))")
        case .topModel:
            guard let top = topModel else { return (nil, false, "") }
            if let d = change(Double(top.tokens), previous.isEmpty ? nil : Double(previous.reduce(0) { $0 + ($1.byModel[top.key] ?? 0) })) { return (d, false, vs) }
            return (nil, false, "\(L("Cost")) \(Fmt.money(top.cost))")
        case .weekday:
            let active = weekdays.indices.filter { weekdays[$0].average > 0 }
            let low = active.min { weekdays[$0].average < weekdays[$1].average }
            return (nil, false, low.map { "\(L("Quietest")) · \(Fmt.weekdaysFromMonday[$0])" } ?? "")
        }
    }

    /// Change in percent; nil without a comparison or when it was zero
    private func change(_ now: Double, _ before: Double?) -> Double? {
        guard let before, before > 0 else { return nil }
        return (now - before) / before * 100
    }

    private var peakRatio: Double {
        guard let peak = stats.peak, stats.averagePerDay > 0 else { return 0 }
        return Double(peak.tokens) / stats.averagePerDay
    }

    // MARK: Visuals

    /// Small: at most 34 pt along the bottom; medium: fills the right column
    @ViewBuilder private var visual: some View {
        switch kind {
        case .average:
            dayBars(value: { Double($0.tokens) }, rule: stats.averagePerDay)
                .frame(height: medium ? nil : 30)
        case .totalCost:
            dayBars(value: \.cost, rule: stats.totalCost / Double(max(1, stats.totalDays)))
                .frame(height: medium ? nil : 30)
        case .peak:
            TopDays(days: Array(days.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }.prefix(3)), color: accent, roomy: medium) { day, p in
                if let day, let p {
                    tip?.show(tipID, key: day.date, at: p) { DayDetailTip(day: day, colors: colors, exact: exact, note: deltaNote(for: day)) }
                } else { tip?.hide(tipID) }
            }
            .frame(height: medium ? nil : 34)
        case .active:
            DayStrip(days: days, color: accent) { day, p in
                if let day, let p {
                    tip?.show(tipID, key: day.date, at: p, glide: true) { DayDetailTip(day: day, colors: colors, exact: exact) }
                } else { tip?.hide(tipID) }
            }
            .frame(height: medium ? nil : 30)
        case .perMillion:
            // Days without usage have no rate: leave them out instead of dipping to zero
            let active = days.filter { $0.tokens > 0 }
            SparkLine(values: active.map { $0.cost / (Double($0.tokens) / 1e6) }, color: accent, tipID: tipID) { i in
                AnyView(rateTip(active[i]))
            }
            .frame(height: medium ? nil : 30)
        case .messages:
            SparkLine(values: days.map { Double($0.messages) }, color: accent, tipID: tipID) { i in
                AnyView(DayDetailTip(day: days[i], colors: colors, exact: exact))
            }
            .frame(height: medium ? nil : 30)
        case .topModel:
            modelShares
        case .weekday:
            weekdayBars
        }
    }

    /// The range's days as bars (grouped when there are more than fit), with the average as a dashed line
    private func dayBars(value: @escaping (DailyHistoryArchive.DaySummary) -> Double, rule: Double) -> some View {
        let groups = buckets(limit: medium ? 36 : 30)
        let values = groups.map { g in g.reduce(0) { $0 + value($1) } / Double(max(1, g.count)) }
        return SparkBars(values: values, color: accent, rule: rule, tipID: tipID) { i in
            AnyView(bucketTip(groups[i], metricRule: rule, value: value))
        }
    }

    /// Consecutive groups of days, oldest first, at most `limit` of them
    private func buckets(limit: Int) -> [ArraySlice<DailyHistoryArchive.DaySummary>] {
        guard !days.isEmpty else { return [] }
        let per = max(1, Int((Double(days.count) / Double(limit)).rounded(.up)))
        return stride(from: 0, to: days.count, by: per).map { days[$0..<min(days.count, $0 + per)] }
    }

    /// Share bar of the models (the top model's tile); medium names the three biggest under it
    @ViewBuilder private var modelShares: some View {
        let parts = report.models.prefix(6).map { (key: $0.key, value: Double($0.tokens), color: colors.color($0.key)) }
        if parts.isEmpty {
            Color.clear.frame(height: medium ? nil : 8)
        } else if medium {
            VStack(alignment: .leading, spacing: 6) {
                SegmentBar(parts: parts, height: 10, tipID: tipID) { key in AnyView(modelTip(key)) }
                ForEach(report.models.prefix(3)) { share in
                    HStack(spacing: 6) {
                        EntityMark(logo: BrandLogos.model(share.key), color: colors.color(share.key), size: 11)
                        Text(colors.name(share.key)).font(.app(Typo.small)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(percent(Double(share.tokens) / modelTotal)).font(.num(Typo.small, .medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .dashboardHover { p in
                        if let p { tip?.show(tipID, key: share.key, at: p) { modelTip(share.key) } } else { tip?.hide(tipID) }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            SegmentBar(parts: parts, height: 8, tipID: tipID) { key in AnyView(modelTip(key)) }
                .frame(height: 8)
        }
    }

    /// Average per weekday as bars, the busiest at full strength, with the weekdays' initials under them
    private var weekdayBars: some View {
        let averages = weekdays.map(\.average)
        let best = busiestWeekday
        return VStack(spacing: 3) {
            SparkBars(values: averages, color: accent, emphasis: averages.indices.map { $0 == best ? 1 : 0.55 }, tipID: tipID) { i in
                AnyView(weekdayTip(i))
            }
            .frame(height: medium ? nil : 22)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(Fmt.weekdayInitialsFromMonday[i]).font(.app(8)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 9)
        }
    }

    // MARK: Readouts

    /// One bar: the day itself, or the days it groups
    private func bucketTip(_ group: ArraySlice<DailyHistoryArchive.DaySummary>, metricRule: Double,
                           value: (DailyHistoryArchive.DaySummary) -> Double) -> some View {
        Group {
            if group.count == 1, let day = group.first {
                DayDetailTip(day: day, colors: colors, exact: exact, note: kind == .average ? deltaNote(for: day) : nil)
            } else if let first = group.first, let last = group.last {
                let groupTokens = group.reduce(0) { $0 + $1.tokens }
                let groupCost = group.reduce(0) { $0 + $1.cost }
                let perDay = group.reduce(0) { $0 + value($1) } / Double(group.count)
                TipCard(title: "\(Fmt.shortDate(first.date)) – \(Fmt.shortDate(last.date))", subtitle: L("\(group.count) days"),
                        icon: kind.icon, tint: accent, value: kind == .totalCost ? Fmt.money(perDay) : Fmt.tokens(perDay, exact: exact)) {
                    TipRow(label: L("Daily avg"), value: kind == .totalCost ? Fmt.money(metricRule) : Fmt.tokens(metricRule, exact: exact))
                    TipRow(label: "Tokens", value: Fmt.tokens(Double(groupTokens), exact: exact))
                    TipRow(label: L("Cost"), value: Fmt.money(groupCost))
                    TipRow(label: L("Messages"), value: Fmt.metric(Double(group.reduce(0) { $0 + $1.messages }), .messages, exact: true))
                }
            }
        }
    }

    /// How far a day sits from the daily average
    private func deltaNote(for day: DailyHistoryArchive.DaySummary) -> String? {
        guard day.tokens > 0, stats.averagePerDay > 0 else { return nil }
        let delta = (Double(day.tokens) - stats.averagePerDay) / stats.averagePerDay * 100
        let pct = String(format: "%.0f%%", abs(delta))
        return delta >= 0 ? L("\(pct) above daily avg") : L("\(pct) below daily avg")
    }

    /// Cost per million tokens on one day
    private func rateTip(_ day: DailyHistoryArchive.DaySummary) -> some View {
        let rate = day.tokens > 0 ? day.cost / (Double(day.tokens) / 1e6) : 0
        return TipCard(title: DayDetailTip.dateTitle(day.date), icon: kind.icon, tint: accent, value: L("\(Fmt.money(rate)) / 1M")) {
            if day.tokens == 0 {
                Text("No usage this day").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                TipRow(label: "Tokens", value: Fmt.tokens(Double(day.tokens), exact: exact))
                TipRow(label: L("Cost"), value: Fmt.money(day.cost))
            }
        }
    }

    private func modelTip(_ key: String) -> some View {
        Group {
            if let share = report.models.first(where: { $0.key == key }) {
                TipCard(title: colors.name(share.key), subtitle: ModelPalette.vendor(share.key).localizedName,
                        icon: kind.icon, tint: colors.color(share.key), value: percent(Double(share.tokens) / modelTotal)) {
                    TipRow(color: colors.color(share.key), label: "Tokens", value: Fmt.tokens(Double(share.tokens), exact: exact))
                    TipRow(label: L("Cost"), value: Fmt.money(share.cost))
                }
            }
        }
    }

    private func weekdayTip(_ i: Int) -> some View {
        let w = weekdays[i]
        return TipCard(title: Fmt.weekdaysFromMonday[i], subtitle: L("\(report.range.localizedLabel) · avg per day"),
                       icon: kind.icon, tint: accent, value: Fmt.tokens(w.average, exact: exact)) {
            TipRow(color: accent, label: "Tokens", value: Fmt.tokens(w.sum, exact: exact))
            TipRow(label: L("Active days"), value: "\(w.active) / \(w.count)")
        }
    }

    // MARK: Derived

    /// Monday…Sunday: the weekday's total in the range, how often it occurs and how often it had usage
    private var weekdays: [(sum: Double, count: Int, active: Int, average: Double)] {
        var sum = Array(repeating: 0.0, count: 7), count = Array(repeating: 0, count: 7), active = Array(repeating: 0, count: 7)
        let cal = Calendar.current
        for d in days {
            let w = (cal.component(.weekday, from: RangeAnalytics.date(d.date)) + 5) % 7
            sum[w] += Double(d.tokens)
            count[w] += 1
            if d.tokens > 0 { active[w] += 1 }
        }
        return (0..<7).map { (sum[$0], count[$0], active[$0], count[$0] > 0 ? sum[$0] / Double(count[$0]) : 0) }
    }

    private var busiestWeekday: Int? {
        let averages = weekdays.map(\.average)
        guard let best = averages.indices.max(by: { averages[$0] < averages[$1] }), averages[best] > 0 else { return nil }
        return best
    }

    private var longestStreak: Int {
        var best = 0, run = 0
        for d in days {
            run = d.tokens > 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }
}

// MARK: - Mini charts

/// Peak days: the highest-usage days in the range, ranked, bars relative to the best day
private struct TopDays: View {
    let days: [DailyHistoryArchive.DaySummary]
    let color: Color
    /// Medium: taller rows with more room for the date
    let roomy: Bool
    let onHover: (DailyHistoryArchive.DaySummary?, CGPoint?) -> Void

    var body: some View {
        let peak = Double(days.first?.tokens ?? 1)
        VStack(alignment: .leading, spacing: roomy ? 8 : 2) {
            ForEach(Array(days.enumerated()), id: \.element.date) { rank, d in
                HStack(spacing: 6) {
                    Text(Fmt.shortDate(d.date)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: roomy ? 46 : 38, alignment: .leading)
                    DepthBar(fraction: Double(d.tokens) / peak, tint: color, height: roomy ? 6 : 4)
                        .opacity(rank == 0 ? 1 : 0.7)
                    Text(Fmt.tokens(Double(d.tokens), exact: false)).font(.num(Typo.axis, .medium)).foregroundStyle(.secondary)
                        .monospacedDigit().lineLimit(1).fixedSize()
                }
                .frame(height: roomy ? 16 : 10)
                .contentShape(Rectangle())
                .dashboardHover { p in onHover(p == nil ? nil : d, p) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: roomy ? .leading : .bottomLeading)
        .animation(Motion.data, value: days.map(\.date))
    }
}

/// Active days: one rounded cell per day of the range, lit when it had usage, a groove when not. The cells
/// run in one row while they stay wide enough and wrap into more rows for long ranges. Drawn in one pass
/// (Canvas); hover maps coordinates to a day.
private struct DayStrip: View {
    let days: [DailyHistoryArchive.DaySummary]
    var color: Color = Palette.activity
    let onHover: (DailyHistoryArchive.DaySummary?, CGPoint?) -> Void
    @State private var hovered: Int?
    private var entrance = Entrance()
    @Environment(HoverTip.self) private var tip: HoverTip?

    init(days: [DailyHistoryArchive.DaySummary], color: Color = Palette.activity, onHover: @escaping (DailyHistoryArchive.DaySummary?, CGPoint?) -> Void) {
        self.days = days
        self.color = color
        self.onHover = onHover
    }

    var body: some View {
        GeometryReader { geo in
            let grid = DayGrid(count: days.count, in: geo.size)
            DayStripCanvas(progress: entrance.amount, active: days.map { $0.tokens > 0 }, tone: Depth.Tone(color), hovered: hovered, grid: grid)
                .animation(Motion.hover, value: hovered)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, tip?.scrolling != true, let i = grid.index(at: p), days.indices.contains(i) else {
                        hovered = nil
                        onHover(nil, nil)
                        return
                    }
                    hovered = i
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    let cell = grid.rect(i)
                    onHover(days[i], CGPoint(x: origin.x + cell.midX, y: origin.y + cell.minY))
                }
        }
        .onAppear { entrance.start() }
    }
}

/// Where the day cells go: square cells in as few rows as keep them readable
private struct DayGrid: Equatable {
    let columns: Int
    let rows: Int
    let side: CGFloat
    let gap: CGFloat
    let origin: CGPoint

    init(count: Int, in size: CGSize) {
        let n = max(1, count)
        let gap: CGFloat = n > 60 ? 1 : 2
        var best = (rows: 1, side: CGFloat(0))
        for r in 1...max(1, min(n, 24)) {
            let cols = Int((Double(n) / Double(r)).rounded(.up))
            let side = min((size.width - gap * CGFloat(cols - 1)) / CGFloat(cols), (size.height - gap * CGFloat(r - 1)) / CGFloat(r))
            if side > best.side + 0.01 { best = (r, side) }
        }
        rows = best.rows
        columns = Int((Double(n) / Double(rows)).rounded(.up))
        side = max(0.5, best.side)
        self.gap = gap
        // Flush left, centred vertically
        let height = CGFloat(rows) * side + CGFloat(rows - 1) * gap
        origin = CGPoint(x: 0, y: max(0, (size.height - height) / 2))
    }

    func rect(_ i: Int) -> CGRect {
        let c = i % columns, r = i / columns
        return CGRect(x: origin.x + CGFloat(c) * (side + gap), y: origin.y + CGFloat(r) * (side + gap), width: side, height: side)
    }

    func index(at p: CGPoint) -> Int? {
        let pitch = side + gap
        guard pitch > 0 else { return nil }
        let c = Int(floor((p.x - origin.x + gap / 2) / pitch)), r = Int(floor((p.y - origin.y + gap / 2) / pitch))
        guard c >= 0, c < columns, r >= 0, r < rows else { return nil }
        return r * columns + c
    }
}

private struct DayStripCanvas: View, Animatable {
    var progress: Double
    let active: [Bool]
    let tone: Depth.Tone
    let hovered: Int?
    let grid: DayGrid

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = max(1, active.count)
            let radius = min(3, grid.side * 0.3)
            for (i, on) in active.enumerated() {
                // Cells grow in from left to right
                let t = min(1, max(0, (progress - Double(i) / Double(n) * 0.4) / 0.6))
                guard t > 0.01 else { continue }
                let full = grid.rect(i)
                let rect = full.insetBy(dx: full.width * (1 - t) / 2, dy: full.height * (1 - t) / 2)
                if on {
                    ctx.cell(rect, tone: tone, radius: radius, opacity: hovered == nil || hovered == i ? 1 : 0.7)
                } else {
                    let path = Path(roundedRect: rect, cornerRadius: min(radius, rect.width / 2), style: .continuous)
                    ctx.fill(path, with: .color(Depth.groove))
                    if rect.width >= 6 { ctx.stroke(path, with: .color(Depth.grooveEdge), lineWidth: 0.5) }
                }
                if hovered == i {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(.white.opacity(0.18)))
                }
            }
        }
    }
}
