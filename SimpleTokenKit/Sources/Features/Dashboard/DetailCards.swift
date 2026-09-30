import SwiftUI
import Charts
import Core
import DesignSystem

// MARK: - Usage chart (card shell: title, legend, date switcher, settings)

struct UsageBarsCard: View {
    let state: AppState
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @State private var flipped = false
    /// Day shown in 1D (nil = today)
    @State private var dayKey: String?
    @State private var pickingDate = false
    @Environment(\.cardSize) private var cardSize

    private var accent: Color { settings.accent("card.usage", .blue) }
    /// Stacking by tool is only accurate for tokens (tokscale does not split cost / messages by tool)
    private var stack: String {
        settings.usageStack == "tool" && report.metric != .tokens ? "model" : settings.usageStack
    }
    private var isDay: Bool { report.range == .day }
    private var shownDay: String { dayKey ?? Fmt.dayKey() }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.usage.localizedName) · Settings"), accentKey: "card.usage", accentDefault: .blue,
                     onHide: { settings.setVisible(.usage, false) }, done: { flipped = false }) {
                OptionRow(L("Stacking")) {
                    GlassSegmented([("model", L("By model")), ("tool", L("By tool")), ("none", L("Unstacked"))], selection: $settings.usageStack)
                }
                if settings.usageStack == "tool" && report.metric != .tokens {
                    Text("Stacking by tool supports tokens only; other metrics stack by model.").font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
                OptionRow(L("1D interval")) {
                    GlassSegmented([(60, L("Hourly")), (30, L("Every 30 min"))], selection: $settings.intradayMinutes)
                }
                OptionRow(L("Average line")) { MiniToggle(isOn: $settings.usageShowAverage) }
                Text("Unstacked bars use the color below.").font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    private var front: some View {
        let columns = isDay ? [] : multiDayColumns
        let slots = isDay ? IntradaySlots.build(models: state.halfHourModels(shownDay), day: state.daySummary(shownDay),
                                                metric: report.metric, minutes: settings.intradayMinutes,
                                                stack: stack, colors: colors, isToday: shownDay == Fmt.dayKey()) : []
        let used: Set<String> = isDay
            ? Set(slots.flatMap { $0.values.map(\.0) })
            : Set(columns.flatMap { $0.values.map(\.0) })
        let total = isDay ? slots.reduce(0) { $0 + $1.total } : columns.reduce(0) { $0 + $1.total }
        let average = columns.isEmpty ? 0 : total / Double(columns.count)
        let busiest = slots.max { $0.total < $1.total }
        let keys = stack == "none" ? [] : order.filter { used.contains($0) }
        let header = WidgetHeader(title, icon: SettingsStore.Card.usage.icon, onSettings: { flipped = true }) {
            if cardSize == .medium { Text("Total \(Fmt.metric(total, report.metric, exact: false))") }
        }
        return VStack(alignment: .leading, spacing: cardSize == .medium ? 6 : 8) {
            if isDay, cardSize != .medium {
                // Date switcher sits on the title line when it fits, otherwise below the title
                ViewThatFits(in: .horizontal) {
                    WidgetHeader(title, icon: SettingsStore.Card.usage.icon, onSettings: { flipped = true }) { dayNavigator.fixedSize() }
                    VStack(alignment: .leading, spacing: 8) {
                        header
                        dayNavigator
                    }
                }
            } else {
                header
            }
            if cardSize != .medium {
                // Total at the top; the wide size puts the legend to its right to save chart height
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    BigNumber(Fmt.metric(total, report.metric, exact: exact), size: WidgetStyle.number(.large) - 2, value: total)
                    Group {
                        if isDay {
                            if let busiest, busiest.total > 0 {
                                Text("Busiest \(String(format: "%d:%02d", Int(busiest.start), Int(busiest.start * 60) % 60))")
                            }
                        } else {
                            Text(averageLabel(Fmt.metric(average, report.metric, exact: false), weekly: report.weeklyBuckets))
                        }
                    }
                    .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer(minLength: 12)
                    if cardSize == .wide, !keys.isEmpty { legend(keys, trailing: true) }
                }
            }
            Group {
                if isDay {
                    IntradayBars(slots: slots, metric: report.metric, minutes: settings.intradayMinutes, exact: exact,
                                 color: groupColor, name: groupName, showAverage: settings.usageShowAverage)
                } else {
                    StackedBars(columns: columns, weekly: report.weeklyBuckets, metric: report.metric, exact: exact,
                                average: settings.usageShowAverage ? average : nil,
                                color: groupColor, name: groupName)
                }
            }
            // Changing range / metric / stacking / day cross-fades the chart; new bars grow from the bottom
            .id("\(report.range.rawValue)|\(report.metric.rawValue)|\(stack)|\(settings.intradayMinutes)|\(shownDay)")
            .transition(.opacity)
            .frame(maxHeight: .infinity)
            if cardSize == .large, !keys.isEmpty {
                legend(keys, trailing: false)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .medium ? 0 : 2))
        .help(isDay ? L("Intraday data comes from Claude Code session logs (kept for 90 days); other tools have no intraday records.") : "")
    }

    /// Legend below the chart: wraps, so many models never overflow the card
    private func legend(_ keys: [String], trailing: Bool) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 5, alignment: trailing ? .trailing : .leading) {
            ForEach(keys, id: \.self) { g in
                HStack(spacing: 5) {
                    Swatch(groupColor(g), size: 7)
                    Text(groupName(g)).font(.app(Typo.small)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .animation(.smooth(duration: 0.3), value: keys)
    }

    /// 1D date switcher: ‹ date › + calendar jump + back to today
    private var dayNavigator: some View {
        let days = state.intraday.snapshot.days
        let earliest = days.first ?? Fmt.dayKey()
        let today = Fmt.dayKey()
        return HStack(spacing: 4) {
            if shownDay != today {
                Button("Today") { withAnimation(.smooth) { dayKey = nil } }
                    .buttonStyle(.glass).controlSize(.mini)
            }
            navButton("chevron.left", enabled: shownDay > earliest) { step(-1) }
            Button { pickingDate = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.app(Typo.small))
                    Text(Fmt.longDate(shownDay))
                        .font(.app(Typo.small, .medium)).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
                DatePicker("", selection: Binding(
                    get: { RangeAnalytics.date(shownDay) },
                    set: { d in
                        let key = Fmt.dayKey(d)
                        withAnimation(.smooth) { dayKey = key == today ? nil : key }
                        pickingDate = false
                    }
                ), in: RangeAnalytics.date(earliest)...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
            }
            navButton("chevron.right", enabled: shownDay < today) { step(1) }
        }
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.app(Typo.small, .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        let next = Fmt.dayKey(Calendar.current.date(byAdding: .day, value: delta, to: RangeAnalytics.date(shownDay))!)
        withAnimation(.smooth) { dayKey = next >= Fmt.dayKey() ? nil : next }
    }

    private var title: String {
        if isDay { return "\(report.metric.localizedLabel) · \(settings.intradayMinutes == 60 ? L("Hourly") : L("Every 30 min"))" }
        return "\(report.metric.localizedLabel) · \(report.weeklyBuckets ? L("Weekly") : L("Daily"))"
    }

    private var order: [String] {
        switch stack {
        case "tool": ["claude", "codex", "copilot", ModelPalette.otherKey]
        case "none": ["total"]
        default: colors.stackOrder
        }
    }

    private func groupColor(_ key: String) -> Color {
        switch stack {
        case "tool": colors.toolColor(key)
        case "none": accent
        default: colors.groupColor(key)
        }
    }

    private func groupName(_ key: String) -> String {
        switch stack {
        case "tool": ModelPalette.toolLabel(key)
        case "none": report.metric.localizedLabel
        default: colors.name(key)
        }
    }

    private var multiDayColumns: [StackedBars.Column] {
        if stack == "tool" {
            let size = report.weeklyBuckets ? 7 : 1
            return stride(from: 0, to: report.days.count, by: size).map { i in
                let group = report.days[i..<min(report.days.count, i + size)]
                var grouped: [String: Double] = [:]
                for d in group {
                    for (client, t) in d.byClient {
                        let key = ["claude", "codex", "copilot"].contains(client) ? client : ModelPalette.otherKey
                        grouped[key, default: 0] += Double(t)
                    }
                }
                return .init(key: group.first!.date, values: order.compactMap { g in grouped[g].map { (g, $0) } }.filter { $0.1 > 0 })
            }
        }
        return report.buckets.map { b in
            var grouped: [String: Double] = [:]
            for (model, v) in b.byModel { grouped[stack == "none" ? "total" : colors.group(model), default: 0] += v }
            return .init(key: b.start, values: order.compactMap { g in grouped[g].map { (g, $0) } }.filter { $0.1 > 0 })
        }
    }
}

/// Multi-day: bars stacked by group (stacked by hand, with ≈2px background gaps between segments)
struct StackedBars: View {
    struct Column {
        let key: String
        let values: [(String, Double)]
        var total: Double { values.reduce(0) { $0 + $1.1 } }
    }

    let columns: [Column]
    let weekly: Bool
    let metric: UsageMetric
    let exact: Bool
    var average: Double?
    let color: (String) -> Color
    let name: (String) -> String
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var selected: String?
    @State private var grown = false

    private struct Segment: Identifiable {
        var id: String { bucket + "|" + group }
        let bucket: String
        let group: String
        let start: Double
        let end: Double
    }

    private var segments: [Segment] {
        let maxTotal = max(1, columns.map(\.total).max() ?? 0)
        let gap = maxTotal * 2 / 130
        return columns.flatMap { c -> [Segment] in
            var acc = 0.0
            return c.values.enumerated().compactMap { i, pair in
                let (g, v) = pair
                defer { acc += v }
                let start = acc + (i > 0 ? gap / 2 : 0)
                let end = acc + v - (i < c.values.count - 1 ? gap / 2 : 0)
                guard end - start > gap * 0.6 || c.values.count == 1 else { return nil }   // segments too small to draw only appear in the tip
                return Segment(bucket: c.key, group: g, start: start, end: end)
            }
        }
    }

    var body: some View {
        let maxTotal = max(1, columns.map(\.total).max() ?? 0)
        let dense = columns.count > 60
        Chart {
            ForEach(segments) { s in
                BarMark(x: .value("Time", s.bucket),
                        yStart: .value("Value", grown ? s.start : 0),
                        yEnd: .value("Value", grown ? s.end : 0),
                        width: .ratio(dense ? 0.8 : 0.62))
                    .cornerRadius(dense ? 1 : 2.5)
                    .foregroundStyle(color(s.group))
                    .opacity(selected == nil || selected == s.bucket ? 1 : 0.4)
            }
            if let average, average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(averageLabel(Fmt.metric(average, metric, exact: false), weekly: weekly))
                            .font(.app(Typo.axis)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.ground.opacity(0.75)))
                            .fixedSize()
                    }
            }
        }
        .chartYScale(domain: 0...(maxTotal * 1.08))
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                // First and last labels align to the edges so the chart bounds do not clip them
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top) {
                    let key = value.as(String.self) ?? ""
                    Text(key == columns.last?.key && !weekly ? L("Today") : Fmt.shortDate(key))
                        .font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [maxTotal * 0.5, maxTotal]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                AxisValueLabel {
                    Text(Fmt.metric(value.as(Double.self) ?? 0, metric, exact: false)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartHover(String.self) { key, p in hover(key, p) }
        .onAppear { withAnimation(.smooth(duration: 0.7).delay(0.05)) { grown = true } }
    }

    private func hover(_ key: String?, _ p: CGPoint) {
        let tipID = "usage.bars"
        guard let key, let column = columns.first(where: { $0.key == key }) else {
            selected = nil
            tip?.hide(tipID)
            return
        }
        selected = key
        let title = weekly ? L("Week of \(Fmt.shortDate(key))") : DayDetailTip.dateTitle(key)
        tip?.show(tipID, at: p) {
            TipCard(title: title, subtitle: average.map { avg -> String in
                guard avg > 0 else { return "" }
                let pct = String(format: "%.0f%%", abs(column.total - avg) / avg * 100)
                return column.total >= avg
                    ? (weekly ? L("\(pct) above weekly avg") : L("\(pct) above daily avg"))
                    : (weekly ? L("\(pct) below weekly avg") : L("\(pct) below daily avg"))
            }) {
                TipRow(label: L("Total"), value: Fmt.metric(column.total, metric, exact: exact))
                if column.values.count > 1 {
                    TipBar(parts: column.values.map { (color($0.0), $0.1) })
                    ForEach(column.values.reversed(), id: \.0) { g, v in
                        TipRow(color: color(g), label: name(g), value: Fmt.metric(v, metric, exact: false),
                               secondary: percent(v / max(1e-9, column.total)))
                    }
                }
            }
        }
    }

    private var ticks: [String] {
        guard let first = columns.first, let last = columns.last else { return [] }
        return [first.key, columns[columns.count / 2].key, last.key]
    }
}

// MARK: - 1D: half-hour / hourly bars

/// One time slot: values per group (already converted to the selected metric via the day's summary)
struct IntradaySlot: Identifiable {
    let id: Int
    let start: Double      // hours
    let end: Double
    let values: [(String, Double)]
    let future: Bool
    let current: Bool
    var total: Double { values.reduce(0) { $0 + $1.1 } }
}

enum IntradaySlots {
    /// Session-log token distribution × each model's amount in the day's summary (tokens / cost / messages),
    /// so the 1D bars add up to the same day on other cards; models missing from the summary count raw tokens.
    static func build(models: [String: [Int]], day: DailyHistoryArchive.DaySummary, metric: UsageMetric,
                      minutes: Int, stack: String, colors: ModelColors, isToday: Bool) -> [IntradaySlot] {
        let now = Date()
        let cal = Calendar.current
        let nowHalf = isToday ? cal.component(.hour, from: now) * 2 + (cal.component(.minute, from: now) >= 30 ? 1 : 0) : 47
        var scale: [String: Double] = [:]
        let costPerToken = day.tokens > 0 ? day.cost / Double(day.tokens) : 0
        let messagesPerToken = day.tokens > 0 ? Double(day.messages) / Double(day.tokens) : 0
        for (model, list) in models {
            let raw = Double(list.reduce(0, +))
            guard raw > 0 else { continue }
            let tokens = Double(day.byModel[model] ?? 0)
            switch metric {
            case .tokens: scale[model] = tokens > 0 ? tokens / raw : 1
            case .cost:
                if let c = day.costByModel[model], tokens > 0 { scale[model] = c / raw }
                else { scale[model] = costPerToken }
            case .messages: scale[model] = messagesPerToken * (tokens > 0 ? tokens / raw : 1)
            }
        }
        let per = minutes == 60 ? 2 : 1
        return stride(from: 0, to: 48, by: per).map { i in
            var grouped: [String: Double] = [:]
            for (model, list) in models {
                let raw = (i..<min(48, i + per)).reduce(0) { $0 + (list.indices.contains($1) ? list[$1] : 0) }
                guard raw > 0 else { continue }
                let key = stack == "none" ? "total" : stack == "tool" ? "claude" : colors.group(model)
                grouped[key, default: 0] += Double(raw) * (scale[model] ?? 1)
            }
            let order = stack == "model" ? colors.stackOrder : Array(grouped.keys)
            return IntradaySlot(id: i, start: Double(i) / 2, end: Double(i + per) / 2,
                                values: order.compactMap { k in grouped[k].map { (k, $0) } },
                                future: i > nowHalf, current: isToday && nowHalf >= i && nowHalf < i + per)
        }
    }
}

/// 1D: a real time axis (0–24h, a tick every 6 hours). The current slot is outlined; future slots are faint placeholders.
struct IntradayBars: View {
    let slots: [IntradaySlot]
    let metric: UsageMetric
    let minutes: Int
    let exact: Bool
    let color: (String) -> Color
    let name: (String) -> String
    var showAverage: Bool
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var hovered: Int?
    @State private var grown = false

    private struct Piece: Identifiable {
        var id: String { "\(slot)|\(group)" }
        let slot: Int
        let group: String
        let x0: Double, x1: Double
        let y0: Double, y1: Double
    }

    private func pieces(maxValue: Double) -> [Piece] {
        let pad = minutes == 60 ? 0.14 : 0.08
        let gap = maxValue * 2 / 130
        return slots.filter { !$0.future }.flatMap { s -> [Piece] in
            var acc = 0.0
            return s.values.enumerated().map { i, pair in
                defer { acc += pair.1 }
                let y0 = acc + (i > 0 ? gap / 2 : 0)
                let y1 = max(y0 + maxValue * 0.004, acc + pair.1 - (i < s.values.count - 1 ? gap / 2 : 0))
                return Piece(slot: s.id, group: pair.0, x0: s.start + pad, x1: s.end - pad, y0: y0, y1: y1)
            }
        }
    }

    var body: some View {
        let maxValue = max(1e-9, slots.map(\.total).max() ?? 0)
        let pad = minutes == 60 ? 0.14 : 0.08
        let active = slots.filter { !$0.future && $0.total > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.total } / Double(active.count)
        Chart {
            ForEach(slots.filter { $0.future || $0.total == 0 }) { s in
                // Empty / future slots: short faint placeholders that show how far the day has got
                RectangleMark(xStart: .value("Hour", s.start + pad), xEnd: .value("Hour", s.end - pad),
                              yStart: .value("Value", 0), yEnd: .value("Value", maxValue * (s.future ? 0.03 : 0.012)))
                    .foregroundStyle(Color.white.opacity(s.future ? 0.07 : 0.12))
                    .cornerRadius(1)
            }
            ForEach(pieces(maxValue: maxValue)) { p in
                RectangleMark(xStart: .value("Hour", p.x0), xEnd: .value("Hour", p.x1),
                              yStart: .value("Value", grown ? p.y0 : 0), yEnd: .value("Value", grown ? p.y1 : 0))
                    .foregroundStyle(color(p.group))
                    .cornerRadius(1.5)
                    .opacity(hovered == nil || hovered == p.slot ? 1 : 0.4)
            }
            if let current = slots.first(where: \.current), current.total > 0 {
                RectangleMark(xStart: .value("Hour", current.start + pad - 0.05), xEnd: .value("Hour", current.end - pad + 0.05),
                              yStart: .value("Value", 0), yEnd: .value("Value", current.total + maxValue * 0.02))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 1) {
                        Text("Now").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    }
            }
            if showAverage, average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        // Half a label width of padding at both ends keeps every tick label centered (re-anchoring the ends would misalign them with the rest)
        .chartXScale(domain: 0...24, range: .plotDimension(padding: 12))
        .chartYScale(domain: 0...(maxValue * 1.12))
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisTick(length: 3).foregroundStyle(Color.white.opacity(0.18))
                AxisValueLabel(anchor: .top) {
                    Text(verbatim: "\(Int(value.as(Double.self) ?? 0)):00").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [maxValue * 0.5, maxValue]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                AxisValueLabel {
                    Text(Fmt.metric(value.as(Double.self) ?? 0, metric, exact: false)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartHover(Double.self) { h, p in hover(h, p, average: average) }
        .onAppear { withAnimation(.smooth(duration: 0.7).delay(0.05)) { grown = true } }
    }

    private func hover(_ h: Double?, _ p: CGPoint, average: Double) {
        let tipID = "usage.intraday"
        guard let h, let s = slots.first(where: { h >= $0.start && h < $0.end }), !s.future else {
            hovered = nil
            tip?.hide(tipID)
            return
        }
        hovered = s.id
        let cumulative = slots.filter { $0.id <= s.id }.reduce(0) { $0 + $1.total }
        let label = String(format: "%d:%02d – %d:%02d", Int(s.start), Int(s.start * 60) % 60, Int(s.end) % 24 == 0 && s.end == 24 ? 24 : Int(s.end), Int(s.end * 60) % 60)
        tip?.show(tipID, at: p) {
            TipCard(title: label, subtitle: s.current ? L("In progress") : nil) {
                if s.total == 0 {
                    Text("No usage in this slot").font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    TipRow(label: L("This slot"), value: Fmt.metric(s.total, metric, exact: exact),
                           secondary: average > 0 ? String(format: "×%.1f", s.total / average) : nil)
                    if s.values.count > 1 {
                        TipBar(parts: s.values.map { (color($0.0), $0.1) })
                        ForEach(s.values.reversed(), id: \.0) { g, v in
                            TipRow(color: color(g), label: name(g), value: Fmt.metric(v, metric, exact: false),
                                   secondary: percent(v / max(1e-9, s.total)))
                        }
                    }
                }
                Divider().overlay(Palette.hairline)
                TipRow(label: L("Day total so far"), value: Fmt.metric(cumulative, metric, exact: false))
            }
        }
    }
}

// MARK: - Calendar heatmap (single-hue scale, dark to bright)

struct CalendarCard: View {
    let history: [DailyHistoryArchive.DaySummary]
    let liveToday: DailyHistoryArchive.DaySummary?
    let rangeDays: Int
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var hovered: String?
    @State private var progress = 0.0
    @State private var flipped = false
    /// How many weeks fit in the grid area (cells up to 16pt, set by the widget size)
    @State private var fitWeeks = 26
    @Environment(\.cardSize) private var cardSize

    private var accent: Color { settings.accent("card.calendar", .green) }
    /// Weeks shown: fills the widget by default, capped by the limit when one is set
    private var weeks: Int {
        settings.calendarWeeks > 0 ? min(settings.calendarWeeks, fitWeeks) : fitWeeks
    }

    static let gap: CGFloat = 2
    static let labelW: CGFloat = 16
    static let monthH: CGFloat = 13

    static func fit(_ size: CGSize, maxCell: CGFloat) -> Int {
        let cell = min(maxCell, (size.height - monthH - gap * 6) / 7)
        guard cell > 2 else { return 13 }
        return max(4, min(53, Int((size.width - labelW + gap) / (cell + gap))))
    }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.calendar.localizedName) · Settings"), accentKey: "card.calendar", accentDefault: .green,
                     onHide: { settings.setVisible(.calendar, false) }, done: { flipped = false }) {
                OptionRow(L("Shade by")) {
                    GlassSegmented(UsageMetric.allCases.map { ($0, $0.localizedLabel) }, selection: $settings.calendarMetric)
                }
                OptionRow(L("Show up to")) {
                    GlassSegmented([(0, L("Fill")), (13, L("\(13) wk")), (26, L("\(26) wk")), (53, L("1 year"))], selection: $settings.calendarWeeks)
                }
            }
        }
    }

    private var front: some View {
        let weeks = weeks
        let cells = cellData(weeks: weeks)
        let values = cells.map { settings.calendarMetric.value($0.day) }
        let maxValue = max(1e-9, values.max() ?? 0)
        let active = cells.filter { $0.day.tokens > 0 }.count
        let grid = gridView(weeks: weeks, cells: cells, values: values, maxValue: maxValue)
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.calendar.localizedName, icon: SettingsStore.Card.calendar.icon, onSettings: { flipped = true }) {
                Text(cardSize == .medium ? L("Last \(weeks) wk · \(active) active days") : L("Last \(weeks) weeks"))
            }
            switch cardSize {
            case .wide:
                // 4×2: number and facts in the left column, grid on the right
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        headline(active: active, total: cells.count)
                        Spacer(minLength: 0)
                        ForEach(Array(facts(cells: cells.map(\.day), values: values).enumerated()), id: \.offset) { _, f in
                            Fact(label: f.0, value: f.1)
                        }
                        scale
                    }
                    .frame(width: 150, alignment: .leading)
                    grid.frame(maxHeight: .infinity)
                }
            case .large:
                headline(active: active, total: cells.count)
                grid.frame(maxHeight: .infinity)
                HStack(alignment: .bottom) {
                    FactsRow(facts(cells: cells.map(\.day), values: values))
                    scale
                }
            default:
                grid.frame(maxHeight: .infinity)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .medium ? 0 : 2))
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { progress = 1 } }
    }

    private func headline(active: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            BigNumber(L("\(active) days"), size: WidgetStyle.number(.large) - 2)
            Text("Active out of \(total)").font(.app(Typo.small)).foregroundStyle(.tertiary)
        }
    }

    /// The whole grid is drawn at once (Canvas) and hover finds the cell by coordinates: hundreds of small views with their own animation and hover handling are too heavy
    private func gridView(weeks: Int, cells: [Cell], values: [Double], maxValue: Double) -> some View {
        GeometryReader { geo in
            let cell = CalendarCanvas.cellSize(geo.size, weeks: weeks)
            let step = cell + Self.gap
            CalendarCanvas(cells: cells.map { c in
                               let v = settings.calendarMetric.value(c.day)
                               return .init(id: c.id, week: c.week, weekday: c.weekday,
                                            level: v <= 0 ? 0 : 0.18 + 0.82 * sqrt(v / maxValue))
                           },
                           weeks: weeks, months: monthLabels(weeks: weeks), accent: accent, hovered: hovered, progress: progress)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase else { hover(nil, at: nil, values: values); return }
                    let week = Int(floor((p.x - Self.labelW) / step)), weekday = Int(floor(p.y / step))
                    let hit = p.x >= Self.labelW ? cells.first { $0.week == week && $0.weekday == weekday } : nil
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    hover(hit, at: CGPoint(x: origin.x + p.x, y: origin.y + p.y), values: values)
                }
        }
        .onGeometryChange(for: Int.self, of: { Self.fit($0.size, maxCell: cardSize == .medium ? 14 : 18) }) { fitWeeks = $0 }
    }

    private func facts(cells: [DailyHistoryArchive.DaySummary], values: [Double]) -> [(String, String)] {
        var best = 0, run = 0
        for d in cells { run = d.tokens > 0 ? run + 1 : 0; best = max(best, run) }
        var out = [(L("Longest streak"), L("\(best) days"))]
        if let top = zip(cells, values).max(by: { $0.1 < $1.1 }), top.1 > 0 {
            out.append((L("Peak · \(Fmt.shortDate(top.0.date))"), Fmt.metric(top.1, settings.calendarMetric, exact: false)))
        }
        return out
    }

    private var scale: some View {
        HStack(spacing: 3) {
            Text("Less").font(.app(Typo.axis)).foregroundStyle(.tertiary)
            ForEach([0.0, 0.3, 0.55, 0.8, 1.0], id: \.self) { l in
                RoundedRectangle(cornerRadius: 2).fill(l == 0 ? Color.white.opacity(0.045) : accent.opacity(l)).frame(width: 9, height: 9)
            }
            Text("More").font(.app(Typo.axis)).foregroundStyle(.tertiary)
        }
    }

    private func hover(_ c: Cell?, at p: CGPoint?, values: [Double]) {
        let tipID = "calendar"
        guard let c, let p else {
            if hovered != nil { hovered = nil }
            tip?.hide(tipID)
            return
        }
        guard hovered != c.id || tip?.id != tipID else { tip?.move(tipID, to: p); return }
        hovered = c.id
        let v = settings.calendarMetric.value(c.day)
        let rank = values.filter { $0 > v }.count + 1
        let activeValues = values.filter { $0 > 0 }
        let avg = activeValues.isEmpty ? 0 : activeValues.reduce(0, +) / Double(activeValues.count)
        var note: String?
        if v > 0 {
            note = L("Last \(weeks) weeks: #\(rank) highest")
            if avg > 0 {
                let pct = String(format: "%.0f%%", abs(v - avg) / avg * 100)
                note! += " · " + (v >= avg ? L("\(pct) above active-day avg") : L("\(pct) below active-day avg"))
            }
        }
        tip?.show(tipID, at: p) { DayDetailTip(day: c.day, colors: colors, exact: exact, note: note) }
    }

    private struct Cell: Identifiable {
        var id: String { day.date }
        let day: DailyHistoryArchive.DaySummary
        let week: Int
        let weekday: Int
    }

    private func startMonday(weeks: Int) -> Date {
        let cal = Calendar.current
        let today = Date()
        let weekday = (cal.component(.weekday, from: today) + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -weekday, to: today)!
        return cal.date(byAdding: .day, value: -(weeks - 1) * 7, to: thisMonday)!
    }

    private func cellData(weeks: Int) -> [Cell] {
        var byDate = Dictionary(history.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        if let liveToday { byDate[liveToday.date] = liveToday }
        let cal = Calendar.current
        let start = startMonday(weeks: weeks)
        let todayKey = Fmt.dayKey()
        var out: [Cell] = []
        for w in 0..<weeks {
            for d in 0..<7 {
                let key = Fmt.dayKey(cal.date(byAdding: .day, value: w * 7 + d, to: start)!)
                if key > todayKey { continue }
                out.append(Cell(day: byDate[key] ?? .init(date: key), week: w, weekday: d))
            }
        }
        return out
    }

    private func monthLabels(weeks: Int) -> [(week: Int, text: String)] {
        let cal = Calendar.current
        let start = startMonday(weeks: weeks)
        var labels: [(week: Int, text: String)] = []
        var lastMonth = -1
        for w in 0..<max(1, weeks - 2) {
            let monday = cal.date(byAdding: .day, value: w * 7, to: start)!
            let m = cal.component(.month, from: monday)
            if m != lastMonth { labels.append((w, Fmt.monthName(monday))); lastMonth = m }
        }
        // Show every other label when crowded
        return weeks > 30 ? labels.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) : labels
    }
}

// MARK: - Time of day: weekday × hour, dot area = usage

struct PunchcardCard: View {
    let card: IntradayScanner.Punchcard
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var hovered: Int?
    @State private var progress = 0.0
    @State private var flipped = false

    private var accent: Color { settings.accent("card.punchcard", .green) }
    @Environment(\.cardSize) private var cardSize

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.punchcard.localizedName) · Settings"), accentKey: "card.punchcard", accentDefault: .green,
                     onHide: { settings.setVisible(.punchcard, false) }, done: { flipped = false }) {
                OptionRow(L("Range")) {
                    GlassSegmented([7, 30, 90].map { ($0, L("\($0) days")) }, selection: $settings.punchcardDays)
                }
                Text("Claude Code only (from session logs).").font(.app(Typo.small)).foregroundStyle(.tertiary)
            }
        }
    }

    private var front: some View {
        let grid = card.grid
        let maxValue = max(1, grid.flatMap { $0 }.max() ?? 0)
        let busiest = busiestHour
        let dots = GeometryReader { geo in
            let colW = (geo.size.width - 16) / 24
            let rowH = (geo.size.height - 14) / 7
            PunchcardCanvas(grid: grid, maxValue: Double(maxValue), accent: accent, hovered: hovered, progress: progress)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, p.x >= 16, p.y < 7 * rowH else { hover(nil, at: nil); return }
                    let h = min(23, Int((p.x - 16) / colW)), d = min(6, Int(p.y / rowH))
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    hover(d * 24 + h, at: CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                }
        }
        .id(settings.punchcardDays)
        .transition(.opacity)
        let headline = VStack(alignment: .leading, spacing: 1) {
            BigNumber(busiest.map { "\($0):00" } ?? "—", size: WidgetStyle.number(.large) - 2)
            Text("Busiest hour").font(.app(Typo.small)).foregroundStyle(.tertiary)
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.punchcard.localizedName, icon: SettingsStore.Card.punchcard.icon, onSettings: { flipped = true }) {
                if cardSize == .medium {
                    Text(busiest.map { L("Last \(settings.punchcardDays) days · busiest \($0):00") } ?? L("Last \(settings.punchcardDays) days"))
                } else {
                    Text("Last \(settings.punchcardDays) days · Claude Code")
                }
            }
            switch cardSize {
            case .wide:
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        headline
                        Spacer(minLength: 0)
                        ForEach(Array(facts(grid).enumerated()), id: \.offset) { _, f in Fact(label: f.0, value: f.1) }
                    }
                    .frame(width: 150, alignment: .leading)
                    dots.frame(maxHeight: .infinity)
                }
            case .large:
                headline
                dots.frame(maxHeight: .infinity)
                FactsRow(facts(grid))
            default:
                dots.frame(maxHeight: .infinity)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .medium ? 0 : 2))
        .animation(.smooth(duration: 0.35), value: settings.punchcardDays)
        .onAppear { withAnimation(.smooth(duration: 0.9)) { progress = 1 } }
    }

    /// Facts: busiest weekday, late-night share, weekend share
    private func facts(_ grid: [[Int]]) -> [(String, String)] {
        let total = max(1, grid.flatMap { $0 }.reduce(0, +))
        let byDay = grid.enumerated().map { d, row in Double(row.reduce(0, +)) / Double(max(1, card.dayCount.indices.contains(d) ? card.dayCount[d] : 1)) }
        let bestDay = byDay.indices.max { byDay[$0] < byDay[$1] }
        let night = grid.reduce(0) { acc, row in acc + row.enumerated().filter { $0.offset >= 22 || $0.offset < 7 }.reduce(0) { $0 + $1.element } }
        let weekend = grid.count >= 7 ? (grid[5] + grid[6]).reduce(0, +) : 0
        var out: [(String, String)] = []
        if let bestDay, byDay[bestDay] > 0 { out.append((L("Busiest weekday"), Fmt.weekdaysFromMonday[bestDay])) }
        out.append((L("10 PM – 7 AM"), percent(Double(night) / Double(total))))
        out.append((L("Weekends"), percent(Double(weekend) / Double(total))))
        return out
    }

    private var busiestHour: Int? {
        var hours = Array(repeating: 0, count: 24)
        for row in card.grid { for (h, v) in row.enumerated() { hours[h] += v } }
        guard let best = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[best] > 0 else { return nil }
        return best
    }

    private func hover(_ idx: Int?, at p: CGPoint?) {
        let tipID = "punchcard"
        guard let idx, let p else {
            if hovered != nil { hovered = nil }
            tip?.hide(tipID)
            return
        }
        guard hovered != idx || tip?.id != tipID else { tip?.move(tipID, to: p); return }
        hovered = idx
        let d = idx / 24, h = idx % 24
        let v = card.grid[d][h]
        let total = max(1, card.grid.flatMap { $0 }.reduce(0, +))
        let times = max(1, card.dayCount[d])
        let models = card.models[d][h].sorted { $0.value > $1.value }
        let weekday = Fmt.weekdaysFromMonday[d]
        tip?.show(tipID, at: p) {
            TipCard(title: "\(weekday) \(h):00 – \(h + 1):00", subtitle: L("Last \(settings.punchcardDays) days · \(times) × \(weekday)")) {
                if v == 0 {
                    Text("No usage in this slot").font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    TipRow(label: L("Total"), value: Fmt.tokens(Double(v), exact: exact), secondary: percent(Double(v) / Double(total)))
                    TipRow(label: L("Avg per \(weekday)"), value: Fmt.tokens(Double(v) / Double(times), exact: false))
                    if !models.isEmpty {
                        Divider().overlay(Palette.hairline)
                        TipBar(parts: models.map { (colors.color($0.key), Double($0.value)) })
                        ForEach(models.prefix(5), id: \.key) { m, t in
                            TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.tokens(Double(t), exact: false),
                                   secondary: percent(Double(t) / Double(v)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Canvas grids

/// Calendar grid: rounded cells in week columns and weekday rows (cell size from the smaller of width and height), months along the bottom; columns fade in one by one as progress goes 0→1
private struct CalendarCanvas: View, Animatable {
    struct Cell { let id: String; let week: Int; let weekday: Int; let level: Double }
    let cells: [Cell]
    let weeks: Int
    let months: [(week: Int, text: String)]
    let accent: Color
    let hovered: String?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func cellSize(_ size: CGSize, weeks: Int) -> CGFloat {
        let gap = CalendarCard.gap
        let byWidth = (size.width - CalendarCard.labelW - gap * CGFloat(weeks - 1)) / CGFloat(max(1, weeks))
        let byHeight = (size.height - CalendarCard.monthH - gap * 6) / 7
        return max(2, min(byWidth, byHeight))
    }

    var body: some View {
        Canvas { ctx, size in
            let gap = CalendarCard.gap, labelW = CalendarCard.labelW
            let cell = Self.cellSize(size, weeks: weeks)
            let label = Color.white.opacity(0.35)
            for (i, text) in [0, 2, 4].map({ Fmt.weekdayInitialsFromMonday[$0] }).enumerated() {
                ctx.draw(Text(text).font(.app(Typo.axis)).foregroundStyle(label),
                         at: CGPoint(x: 0, y: CGFloat(i * 2) * (cell + gap) + cell / 2), anchor: .leading)
            }
            let bottom = 7 * (cell + gap)
            for m in months {
                ctx.draw(Text(m.text).font(.app(Typo.axis)).foregroundStyle(label),
                         at: CGPoint(x: labelW + CGFloat(m.week) * (cell + gap), y: bottom + 1), anchor: .topLeading)
            }
            let spread = 0.5 / Double(max(1, weeks))
            var hoveredRect: CGRect?
            for c in cells {
                let t = min(1, max(0, (progress - Double(c.week) * spread) * 2))
                guard t > 0 else { continue }
                let rect = CGRect(x: labelW + CGFloat(c.week) * (cell + gap), y: CGFloat(c.weekday) * (cell + gap),
                                  width: cell, height: cell)
                let color = c.level <= 0 ? Color.white.opacity(0.045 * t) : accent.opacity(c.level * t)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, cell / 4)), with: .color(color))
                if c.id == hovered { hoveredRect = rect }
            }
            if let r = hoveredRect?.insetBy(dx: -1.5, dy: -1.5) {
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.9)), lineWidth: 1.2)
            }
        }
    }
}

/// Time of day: weekday × hour dots, area ∝ usage; they grow from top left to bottom right as progress goes 0→1
private struct PunchcardCanvas: View, Animatable {
    let grid: [[Int]]
    let maxValue: Double
    let accent: Color
    let hovered: Int?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let labelW: CGFloat = 16
            let colW = (size.width - labelW) / 24
            let rowH = (size.height - 14) / 7
            let label = Color.white.opacity(0.35)
            // Label every other row when rows are short, so weekday labels do not collide
            for d in 0..<7 where rowH >= 13 || d % 2 == 0 {
                ctx.draw(Text(Fmt.weekdayInitialsFromMonday[d]).font(.app(Typo.axis)).foregroundStyle(label),
                         at: CGPoint(x: 0, y: CGFloat(d) * rowH + rowH / 2), anchor: .leading)
            }
            for h in [0, 6, 12, 18] {
                ctx.draw(Text(verbatim: "\(h):00").font(.app(Typo.axis)).foregroundStyle(label),
                         at: CGPoint(x: labelW + CGFloat(h) * colW + colW / 2, y: 7 * rowH + 2), anchor: .top)
            }
            let maxR = min(colW, rowH) / 2 - 0.5
            for d in 0..<min(7, grid.count) {
                for h in 0..<min(24, grid[d].count) {
                    let v = grid[d][h]
                    let delay = Double(h) / 24 * 0.35 + Double(d) / 7 * 0.15
                    let t = min(1, max(0, (progress - delay) / 0.5))
                    let fraction = sqrt(Double(v) / maxValue)
                    let r = (v > 0 ? max(1.6, fraction * maxR) : 1) * t
                    guard r > 0 else { continue }
                    let center = CGPoint(x: labelW + (CGFloat(h) + 0.5) * colW, y: (CGFloat(d) + 0.5) * rowH)
                    let hoveredHere = hovered == d * 24 + h
                    let rr = hoveredHere ? r * 1.2 + 0.5 : r
                    let circle = Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2))
                    ctx.fill(circle, with: .color(v > 0 ? accent.opacity(0.3 + 0.7 * fraction) : Color.white.opacity(0.12)))
                    if hoveredHere {
                        ctx.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                    }
                }
            }
        }
    }
}

// MARK: - Tool share

struct ToolsCard: View {
    let report: RangeReport
    let catalog: [DailyHistoryArchive.CatalogEntry]
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hovered: String?
    @State private var rowsNarrow = false
    @Environment(\.cardSize) private var cardSize

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.tools.localizedName) · Settings"), onHide: { settings.setVisible(.tools, false) }, done: { flipped = false }) {
                Text("Tools turned off are left out of every stat.").font(.app(Typo.small)).foregroundStyle(.tertiary)
                ForEach(catalog) { entry in
                    OptionRow(ModelPalette.toolLabel(entry.key)) {
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(
                                get: { colors.toolColor(entry.key) },
                                set: { settings.toolColorOverrides[entry.key] = $0.hexString }
                            ), supportsOpacity: false).labelsHidden().controlSize(.mini)
                            MiniToggle(isOn: Binding(
                                get: { !settings.excludedClients.contains(entry.key) },
                                set: { if $0 { settings.excludedClients.remove(entry.key) } else { settings.excludedClients.insert(entry.key) } }
                            ))
                        }
                    }
                }
            }
        }
    }

    private var front: some View {
        let all = max(1, report.clients.reduce(0) { $0 + $1.tokens })
        let shown = report.clients.filter { Double($0.tokens) / Double(all) >= 0.0005 }
        let total = max(1, shown.reduce(0) { $0 + $1.tokens })
        let bar = ProportionBar(parts: shown.map { (colors.toolColor($0.key), Double($0.tokens)) }, height: cardSize == .large ? 8 : 6) { i, p in
            if let i { hover(shown[i], total: total, at: p) } else { hover(nil, total: total, at: nil) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.tools.localizedName, icon: SettingsStore.Card.tools.icon, onSettings: { flipped = true }) {
                if cardSize != .small { Text("\(report.range.localizedLabel) · \(shown.count) tools") }
            }
            switch cardSize {
            case .small:
                // 1×1: the most used tool + its share, with a share bar of all tools at the bottom
                if let top = shown.first {
                    HStack(spacing: 6) {
                        EntityMark(logo: BrandLogos.tool(top.key), color: colors.toolColor(top.key), size: 15)
                        Text(ModelPalette.toolLabel(top.key)).font(.app(Typo.body, .medium)).lineLimit(1)
                    }
                    BigNumber(percent(Double(top.tokens) / Double(total)), size: WidgetStyle.number(.small))
                    Spacer(minLength: 0)
                    bar
                    Text(shown.count > 1 ? L("+\(shown.count - 1) more tools") : L("The only tool used"))
                        .font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    Text("No usage in this range").font(.app(Typo.small)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            case .medium:
                bar
                rows(shown.prefix(3), total: total, sparkline: true)
                Spacer(minLength: 0)
            default:
                // 2×2: total + daily stacked bars per tool + list
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(Fmt.tokens(Double(all), exact: exact), size: WidgetStyle.number(.large) - 2, value: Double(all))
                    Text("\(shown.count) tools with usage").font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
                ToolArea(days: report.days, keys: shown.map(\.key), color: colors.toolColor)
                    .frame(maxHeight: .infinity)
                rows(shown.prefix(4), total: total, sparkline: false)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large ? 2 : 0))
    }

    private func rows(_ list: ArraySlice<RangeReport.Share>, total: Int, sparkline: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list)) { s in
                HStack(spacing: 8) {
                    EntityMark(logo: BrandLogos.tool(s.key), color: colors.toolColor(s.key), size: 13)
                    Text(ModelPalette.toolLabel(s.key)).font(.app(Typo.body)).lineLimit(1)
                    Spacer(minLength: 4)
                    if sparkline, !rowsNarrow {
                        Sparkline(values: report.days.map { Double($0.byClient[s.key] ?? 0) }, color: colors.toolColor(s.key), height: 14)
                            .frame(width: 56)
                            .allowsHitTesting(false)
                    }
                    Text(Fmt.tokens(Double(s.tokens), exact: exact)).font(.app(Typo.small)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                    Text(percent(Double(s.tokens) / Double(total))).font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .monospacedDigit()
                .frame(height: 21)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered == s.key ? 0.06 : 0)))
                .contentShape(Rectangle())
                .dashboardHover { p in hover(p == nil ? nil : s, total: total, at: p) }
            }
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < 300 }) { rowsNarrow = $0 }
    }

    private func hover(_ s: RangeReport.Share?, total: Int, at p: CGPoint?) {
        let tipID = "tools"
        guard let s, let p else { hovered = nil; tip?.hide(tipID); return }
        hovered = s.key
        let days = report.days.filter { ($0.byClient[s.key] ?? 0) > 0 }
        let models = report.days.reduce(into: [String: Int]()) { acc, d in
            // Daily summaries have no tool × model split: approximate by the model's vendor (Claude → Claude Code, OpenAI → Codex)
            for (m, t) in d.byModel where Self.belongs(model: m, to: s.key) { acc[m, default: 0] += t }
        }.sorted { $0.value > $1.value }
        let entry = catalog.first { $0.key == s.key }
        tip?.show(tipID, at: p) {
            TipCard(title: ModelPalette.toolLabel(s.key), subtitle: report.range.localizedLabel) {
                TipRow(color: colors.toolColor(s.key), label: "Tokens", value: Fmt.tokens(Double(s.tokens), exact: exact),
                       secondary: percent(Double(s.tokens) / Double(total)))
                TipRow(label: L("Days with usage"), value: "\(days.count) / \(report.days.count)")
                if let last = days.last { TipRow(label: L("Last used"), value: Fmt.shortDate(last.date)) }
                if let entry { TipRow(label: L("All-time total"), value: Fmt.tokens(Double(entry.tokens), exact: false)) }
                if !models.isEmpty {
                    Divider().overlay(Palette.hairline)
                    ForEach(models.prefix(4), id: \.key) { m, t in
                        TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.tokens(Double(t), exact: false))
                    }
                }
            }
        }
    }

    static func belongs(model: String, to client: String) -> Bool {
        switch client {
        case "claude": ModelPalette.vendor(model) == .anthropic
        case "codex": ModelPalette.vendor(model) == .openai
        default: false
        }
    }
}

func percent(_ fraction: Double) -> String {
    fraction < 0.01 ? String(format: "%.1f%%", fraction * 100) : String(format: "%.0f%%", fraction * 100)
}

/// "Daily avg 1.2 M" / "Weekly avg 1.2 M"
func averageLabel(_ value: String, weekly: Bool) -> String {
    weekly ? L("Weekly avg \(value)") : L("Daily avg \(value)")
}

/// Daily usage per tool, stacked (large tools card)
struct ToolArea: View {
    let days: [DailyHistoryArchive.DaySummary]
    let keys: [String]
    let color: (String) -> Color

    var body: some View {
        Chart {
            ForEach(keys.reversed(), id: \.self) { key in
                ForEach(days, id: \.date) { d in
                    BarMark(x: .value("Day", d.date), y: .value("Usage", Double(d.byClient[key] ?? 0)), width: .ratio(days.count > 60 ? 0.8 : 0.6))
                        .foregroundStyle(by: .value("Tool", key))
                        .cornerRadius(1.5)
                }
            }
        }
        .chartForegroundStyleScale(domain: keys.reversed(), range: keys.reversed().map { color($0).opacity(0.85) })
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                AxisValueLabel {
                    Text(Fmt.tokens(value.as(Double.self) ?? 0, exact: false)).font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Horizontal share bar: 2px gaps between segments, grows from zero on appear, animates data changes; the hovered segment is highlighted
struct ProportionBar: View {
    let parts: [(Color, Double)]
    var height: CGFloat = 8
    var onHover: ((Int?, CGPoint?) -> Void)? = nil
    @State private var appeared = false
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let total = max(1e-9, parts.reduce(0) { $0 + $1.1 })
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(parts[i].0)
                        .opacity(hovered == nil || hovered == i ? 1 : 0.45)
                        .frame(width: max(2, (geo.size.width - gaps) * parts[i].1 / total * (appeared ? 1 : 0)))
                        .contentShape(Rectangle())
                        .dashboardHover { p in
                            hovered = p == nil ? (hovered == i ? nil : hovered) : i
                            onHover?(p == nil ? nil : i, p)
                        }
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
            .animation(.smooth(duration: 0.6), value: parts.map(\.1))
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .frame(height: height)
        .onAppear { withAnimation(.smooth(duration: 0.9)) { appeared = true } }
    }
}

// MARK: - Token breakdown (cache = two blues, fresh = two warms)

struct CompositionCard: View {
    let state: AppState
    let range: TimeRange
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hovered: Int?
    @Environment(\.cardSize) private var cardSize

    private struct Part {
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
            Part(name: L("Cache read"), value: period?.cacheReadTokens ?? 0, color: c[0],
                 explain: L("Cache hit, ~1/10 of the input price"), pick: \.cacheRead),
            Part(name: L("Cache write"), value: period?.cacheWriteTokens ?? 0, color: c[1],
                 explain: L("First write to cache, a bit above input"), pick: \.cacheWrite),
            Part(name: L("Input"), value: period?.inputTokens ?? 0, color: c[2],
                 explain: L("New input that missed the cache"), pick: \.input),
            Part(name: L("Output"), value: period?.outputTokens ?? 0, color: c[3],
                 explain: L("Model-generated, the priciest"), pick: \.output),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.value })
        let inputs = max(1, parts[0].value + parts[1].value + parts[2].value)
        let hit = Double(parts[0].value) / Double(inputs)
        let hitText = String(format: "%.1f%%", hit * 100)
        let bar = ProportionBar(parts: parts.map { ($0.color, max(Double($0.value), Double(total) * 0.006)) },
                                height: cardSize == .small ? 7 : 8) { i, p in
            hover(i.map { parts[$0] }, index: i, period: period, total: total, at: p)
        }
        let donut = DonutChart(parts: parts.enumerated().map { (key: "\($0.offset)", value: max(Double($0.element.value), Double(total) * 0.01), color: $0.element.color) },
                               inner: 0.7, hovered: hovered.map { "\($0)" },
                               onHover: { k, p in
                                   let i = k.flatMap(Int.init)
                                   hover(i.map { parts[$0] }, index: i, period: period, total: total, at: p)
                               }) {
            if settings.compositionShowHitRate {
                VStack(spacing: 0) {
                    Text(hitText).font(.app(cardSize == .large ? Typo.value + 1 : Typo.title + 1, .semibold)).monospacedDigit()
                        .foregroundStyle(c[0])
                    Text("Hit rate").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.composition.localizedName, icon: SettingsStore.Card.composition.icon, onSettings: { flipped = true }) {
                if cardSize != .small {
                    Text(settings.compositionPeriod == "auto" && range != .day && range != .all ? L("\(label) (calendar month)") : label)
                }
            }
            switch cardSize {
            case .small:
                // 1×1: large cache hit rate, breakdown bar at the bottom
                BigNumber(hitText, size: WidgetStyle.number(.small), color: c[0], value: hit)
                Text("Cache hit rate · \(label)").font(.app(Typo.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                bar
                Text("Output \(percent(Double(parts[3].value) / Double(total))) · new input \(percent(Double(parts[2].value) / Double(total)))")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
            case .medium:
                HStack(alignment: .center, spacing: 16) {
                    donut.frame(width: 88, height: 88)
                    partRows(parts, period: period, total: total)
                }
                .frame(maxHeight: .infinity)
            default:
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(Fmt.tokens(Double(total), exact: exact), size: WidgetStyle.number(.large) - 2, value: Double(total))
                    Text("\(label) total · \(percent(Double(parts[0].value) / Double(total))) from cache").font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .center, spacing: 18) {
                    donut.frame(width: 118, height: 118)
                    partRows(parts, period: period, total: total, explain: true)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large ? 2 : 0))
    }

    private func partRows(_ parts: [Part], period: UsagePeriod?, total: Int, explain: Bool = false) -> some View {
        VStack(spacing: explain ? 4 : 0) {
            ForEach(parts.indices, id: \.self) { i in
                let part = parts[i]
                HStack(spacing: 7) {
                    Swatch(part.color, size: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(part.name).font(.app(Typo.body)).lineLimit(1)
                        if explain {
                            Text(part.explain).font(.app(Typo.axis)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.tokens(Double(part.value), exact: exact)).font(.app(Typo.small)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                    Text(percent(Double(part.value) / Double(total))).font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .monospacedDigit()
                .frame(height: explain ? 30 : 21)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered == i ? 0.06 : 0)))
                .contentShape(Rectangle())
                .dashboardHover { p in hover(p == nil ? nil : part, index: i, period: period, total: total, at: p) }
            }
        }
    }

    private func hover(_ part: Part?, index: Int?, period: UsagePeriod?, total: Int, at p: CGPoint?) {
        let tipID = "composition"
        guard let part, let p else { hovered = nil; tip?.hide(tipID); return }
        hovered = index
        let models = (period?.byModel ?? [:]).map { ($0.key, part.pick($0.value)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        tip?.show(tipID, at: p) {
            TipCard(title: part.name, subtitle: part.explain) {
                TipRow(color: part.color, label: "Tokens", value: Fmt.tokens(Double(part.value), exact: exact),
                       secondary: percent(Double(part.value) / Double(total)))
                if !models.isEmpty {
                    Divider().overlay(Palette.hairline)
                    ForEach(models.prefix(5), id: \.0) { m, v in
                        TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.tokens(Double(v), exact: false),
                               secondary: percent(Double(v) / Double(max(1, part.value))))
                    }
                }
            }
        }
    }
}

// MARK: - This month's cost: cumulative + month-end projection + last month reference

struct CostCard: View {
    let month: RangeAnalytics.MonthCost
    let colors: ModelColors
    let summary: (String) -> DailyHistoryArchive.DaySummary
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var selectedDay: Int?
    @State private var appeared = false
    @State private var flipped = false
    @Environment(\.cardSize) private var cardSize

    private var accent: Color { settings.accent("card.cost", .blue) }

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

    private var points: [(day: Int, date: String, cost: Double, cumulative: Double)] {
        month.days.enumerated().map { (day: $0.offset + 1, date: $0.element.date, cost: $0.element.cost, cumulative: $0.element.cumulative) }
    }

    private var front: some View {
        let points = points
        let spent = points.last?.cumulative ?? 0
        let yMax = max(settings.costShowProjection ? month.projected : 0,
                       settings.costShowLastMonth ? month.lastMonthTotal : 0, spent, 1) * 1.1
        let number = BigNumber(Fmt.money(spent), size: WidgetStyle.number(cardSize), color: accent, value: spent)
        let header = WidgetHeader(SettingsStore.Card.cost.localizedName, icon: SettingsStore.Card.cost.icon, tint: accent, onSettings: { flipped = true }) {
            if cardSize != .small, settings.costShowLastMonth, month.lastMonthTotal > 0 {
                Text("Last month \(Fmt.money(month.lastMonthTotal))")
            }
        }
        return Group {
            switch cardSize {
            case .small:
                VStack(alignment: .leading, spacing: 2) {
                    header
                    number
                    projectionLine(spent: spent)
                    Sparkline(values: points.map(\.cumulative), color: accent)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            case .medium:
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            number
                            projectionLine(spent: spent)
                            Spacer(minLength: 0)
                            if let change = changeVsLastMonth { DeltaChip(percent: change) }
                        }
                        .frame(width: 150, alignment: .leading)
                        chart(points: points, yMax: yMax, compact: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .large:
                VStack(alignment: .leading, spacing: 8) {
                    header
                    VStack(alignment: .leading, spacing: 2) {
                        number
                        projectionLine(spent: spent)
                    }
                    chart(points: points, yMax: yMax)
                        .frame(maxHeight: .infinity)
                    FactsRow(facts(points: points))
                }
            case .wide:
                VStack(alignment: .leading, spacing: 8) {
                    header
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 4) {
                            number
                            projectionLine(spent: spent)
                            Spacer(minLength: 10)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(facts(points: points).enumerated()), id: \.offset) { _, f in Fact(label: f.0, value: f.1) }
                            }
                        }
                        .frame(width: 190, alignment: .leading)
                        chart(points: points, yMax: yMax)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large || cardSize == .wide ? 2 : 0), radius: 18)
        .onAppear { withAnimation(.smooth(duration: 1.0)) { appeared = true } }
    }

    private func projectionLine(spent: Double) -> some View {
        Group {
            if settings.costShowProjection, month.projected > spent * 1.005 {
                Text("Projected \(Fmt.money(month.projected))")
            } else {
                Text("\(month.days.count) / \(month.daysInMonth) days")
            }
        }
        .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
    }

    /// How much the month-end projection at the current pace is above / below last month
    private var changeVsLastMonth: Double? {
        guard month.lastMonthTotal > 0 else { return nil }
        let expected = max(month.projected, month.days.last?.cumulative ?? 0)
        return (expected - month.lastMonthTotal) / month.lastMonthTotal * 100
    }

    private func deviation(_ cost: Double, _ avg: Double) -> String {
        let pct = String(format: "%.0f%%", abs(cost - avg) / avg * 100)
        return cost >= avg ? L("\(pct) above this month's daily avg") : L("\(pct) below this month's daily avg")
    }

    private func facts(points: [(day: Int, date: String, cost: Double, cumulative: Double)]) -> [(String, String)] {
        let spent = points.last?.cumulative ?? 0
        var out = [(L("Daily avg"), Fmt.money(spent / Double(max(1, points.count))))]
        if let top = points.max(by: { $0.cost < $1.cost }) { out.append((L("Peak · \(Fmt.shortDate(top.date))"), Fmt.money(top.cost))) }
        if let change = changeVsLastMonth { out.append((L("Projected vs last month"), String(format: "%@%.0f%%", change >= 0 ? "+" : "−", abs(change)))) }
        return out
    }

    private func costSummary(spent: Double, projection: Bool, lastMonth: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Spent").foregroundStyle(.tertiary)
            Text(Fmt.money(spent)).foregroundStyle(accent).fontWeight(.semibold)
            if projection {
                Text("· Projected \(Fmt.money(month.projected))").foregroundStyle(.tertiary)
            }
            if lastMonth {
                Text("· Last month \(Fmt.money(month.lastMonthTotal))").foregroundStyle(.tertiary)
            }
        }
        .font(.app(Typo.small)).monospacedDigit().lineLimit(1).fixedSize()
    }

    private func chart(points: [(day: Int, date: String, cost: Double, cumulative: Double)], yMax: Double, compact: Bool = false) -> some View {
        let dailyMax = max(1, points.map(\.cost).max() ?? 0)
        return Chart {
            if settings.costShowLastMonth, !compact {
                RuleMark(y: .value("Last month", month.lastMonthTotal))
                    .foregroundStyle(Color.white.opacity(0.14))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Last month \(Fmt.money(month.lastMonthTotal))").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                    }
            }
            if settings.costShowDailyBars {
                // Daily cost: thin background bars (the largest day scaled to 30% of the chart height)
                ForEach(points, id: \.day) { p in
                    BarMark(x: .value("Day", p.day), yStart: .value("Cost", 0),
                            yEnd: .value("Cost", appeared ? p.cost / dailyMax * yMax * 0.3 : 0), width: .fixed(5))
                        .foregroundStyle(accent.opacity(selectedDay == p.day ? 0.8 : 0.32))
                        .cornerRadius(2)
                }
            }
            ForEach(points, id: \.day) { p in
                AreaMark(x: .value("Day", p.day), y: .value("Cumulative", appeared ? p.cumulative : 0))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", p.day), y: .value("Cumulative", appeared ? p.cumulative : 0), series: .value("s", "cumulative"))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if settings.costShowProjection, let last = points.last, last.day < month.daysInMonth {
                // Projection: dashed = not yet happened
                ForEach([(last.day, last.cumulative), (month.daysInMonth, month.projected)], id: \.0) { d, v in
                    LineMark(x: .value("Day", d), y: .value("Cumulative", appeared ? v : 0), series: .value("s", "projection"))
                        .foregroundStyle(accent.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [4, 4]))
                }
                PointMark(x: .value("Day", month.daysInMonth), y: .value("Cumulative", appeared ? month.projected : 0))
                    .foregroundStyle(accent.opacity(0.7)).symbolSize(24)
                    // Annotation goes to the point's top left: the month-end point hugs the right edge, so a right-side label would overflow the card
                    .annotation(position: .topLeading, spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        if !compact {
                            Text("≈ \(Fmt.money(month.projected))").font(.app(Typo.small)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
            }
            if let selected = selectedDay.flatMap({ d in points.first { $0.day == d } }) {
                RuleMark(x: .value("Day", selected.day)).foregroundStyle(Color.white.opacity(0.3))
                PointMark(x: .value("Day", selected.day), y: .value("Cumulative", selected.cumulative))
                    .foregroundStyle(accent).symbolSize(56)
            } else if let last = points.last {
                PointMark(x: .value("Day", last.day), y: .value("Cumulative", appeared ? last.cumulative : 0))
                    .foregroundStyle(accent).symbolSize(48)
            }
        }
        // Padding at both ends keeps the first / last date labels and the month-end point off the edges and unclipped
        .chartXScale(domain: 1...month.daysInMonth, range: .plotDimension(padding: 14))
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: [1, 15, month.daysInMonth]) { value in
                AxisValueLabel {
                    Text("Day \(value.as(Int.self) ?? 0)").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(.hidden)
        .chartHover(Double.self) { x, p in hover(x, p, points: points) }
    }

    private func hover(_ x: Double?, _ p: CGPoint, points: [(day: Int, date: String, cost: Double, cumulative: Double)]) {
        let tipID = "cost"
        guard let x, let point = points.first(where: { $0.day == Int(x.rounded()) }) else {
            selectedDay = nil
            tip?.hide(tipID)
            return
        }
        selectedDay = point.day
        let day = summary(point.date)
        let avg = (points.last?.cumulative ?? 0) / Double(max(1, points.count))
        let models = day.costByModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        tip?.show(tipID, at: p) {
            TipCard(title: DayDetailTip.dateTitle(point.date),
                    subtitle: avg > 0 && point.cost > 0 ? deviation(point.cost, avg) : nil) {
                TipRow(color: accent, label: L("This day"), value: Fmt.money(point.cost))
                TipRow(label: L("Month to date"), value: Fmt.money(point.cumulative))
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
    }
}
