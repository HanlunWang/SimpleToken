import SwiftUI
import Core
import DesignSystem

// MARK: - Usage chart (card shell: title, legend, date switcher, settings)

/// Usage over the range as stacked columns: one per day or week, split by model or tool, with the range's
/// average as a dashed rule. At 1D the columns are the day's hours (or half hours) with a marker on the
/// current one. Clicking a legend chip puts that series in focus; the rest turn grey.
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
    /// The legend chip in focus: its segments keep their colour, the rest turn grey
    @State private var focus: String?
    /// Width of the chart, for how many date labels fit under it
    @State private var chartWidth: CGFloat = 300
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

    /// One column of the chart: a day, a week or a time slot, with a value per colour slot
    private struct Column {
        let key: String
        let values: [Double]
        var total: Double { values.reduce(0, +) }
    }

    private var front: some View {
        let keys = order
        let slots = isDay ? IntradaySlots.build(models: state.halfHourModels(shownDay), day: state.daySummary(shownDay),
                                                metric: report.metric, minutes: settings.intradayMinutes,
                                                stack: stack, colors: colors, isToday: shownDay == Fmt.dayKey()) : []
        let columns = isDay
            ? slots.map { s in Column(key: "\(s.id)", values: keys.map { k in s.values.first { $0.0 == k }?.1 ?? 0 }) }
            : multiDayColumns(keys)
        // Series present in the range: the legend names only these
        let used = keys.enumerated().filter { g in columns.contains { $0.values[g.offset] > 0 } }.map(\.element)
        let total = columns.reduce(0) { $0 + $1.total }
        let active = slots.filter { !$0.future && $0.total > 0 }
        let average = isDay
            ? (active.isEmpty ? 0 : active.reduce(0) { $0 + $1.total } / Double(active.count))
            : (columns.isEmpty ? 0 : total / Double(columns.count))
        let busiest = slots.max { $0.total < $1.total }
        let legendKeys = stack == "none" ? [] : used
        // A series in focus that the range no longer has would leave every column grey with no chip to release it
        let focus = focus.flatMap { legendKeys.contains($0) ? $0 : nil }
        let header = WidgetHeader(title, icon: SettingsStore.Card.usage.icon, tint: accent, onSettings: { flipped = true }) {
            if cardSize == .medium { Text("Total \(Fmt.metric(total, report.metric, exact: false))") }
        }
        return VStack(alignment: .leading, spacing: cardSize == .medium ? 6 : 8) {
            if isDay, cardSize != .medium {
                // Date switcher sits on the title line when it fits, otherwise below the title
                ViewThatFits(in: .horizontal) {
                    WidgetHeader(title, icon: SettingsStore.Card.usage.icon, tint: accent, onSettings: { flipped = true }) { dayNavigator.fixedSize() }
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
                    .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 12)
                    if cardSize == .wide, !legendKeys.isEmpty { legend(legendKeys, focus: focus, trailing: true) }
                }
            }
            chart(columns: columns, slots: slots, keys: keys, average: average, focus: focus)
                .frame(maxHeight: .infinity)
            if cardSize == .large, !legendKeys.isEmpty {
                legend(legendKeys, focus: focus, trailing: false)
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .medium ? 0 : 2))
        .help(isDay ? L("Intraday data comes from Claude Code session logs (kept for 90 days); other tools have no intraday records.") : "")
        .onChange(of: stack) { self.focus = nil }
    }

    // MARK: Chart

    private func chart(columns: [Column], slots: [IntradaySlot], keys: [String], average: Double, focus: String?) -> some View {
        let labelled = BarLabels.keep(count: columns.count, limit: max(2, min(8, Int(chartWidth / 56))))
        let bars: [BarChart.Bar] = isDay
            ? slots.enumerated().map { i, s in
                BarChart.Bar(id: columns[i].key, segments: columns[i].values, emphasis: s.future ? 0.35 : 1,
                             label: s.start.truncatingRemainder(dividingBy: 6) == 0 ? String(format: "%d:00", Int(s.start)) : nil,
                             cap: s.current && s.total > 0 ? L("Now") : nil)
            }
            : columns.enumerated().map { i, c in
                BarChart.Bar(id: c.key, segments: c.values,
                             label: labelled(i) ? (i == columns.count - 1 && !report.weeklyBuckets ? L("Today") : Fmt.shortDate(c.key)) : nil)
            }
        // The rule carries no label: the average is written beside the number (large / wide), and a label
        // drawn over the bars is unreadable at the medium size
        let rule: (value: Double, label: String)? = settings.usageShowAverage && average > 0 ? (average, "") : nil
        return BarChart(bars: bars, colors: keys.map(groupColor), format: ChartAxis.format(report.metric), rule: rule,
                        ratio: isDay ? 0.72 : 0.68, tipID: "usage.bars", focus: focus.flatMap { keys.firstIndex(of: $0) },
                        tip: { i in
                            isDay
                                ? AnyView(slotTip(slots[i], column: columns[i], keys: keys, average: average, slots: slots))
                                : AnyView(bucketTip(columns[i], keys: keys, average: average))
                        })
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { chartWidth = $0 }
        .animation(Motion.data, value: "\(report.range.rawValue)|\(report.metric.rawValue)|\(shownDay)|\(settings.intradayMinutes)|\(settings.usageShowAverage)")
        // A different stacking is a different picture: cross-fade rather than morph
        .id(stack)
        .transition(.opacity)
    }

    /// "Hourly avg 1.2 M" / "Avg per 30 min 1.2 M"
    private func intradayAverageLabel(_ average: Double) -> String {
        let value = Fmt.metric(average, report.metric, exact: false)
        return settings.intradayMinutes == 60 ? L("Hourly avg \(value)") : L("Avg per 30 min \(value)")
    }

    /// Readout for a day or week: the day's full breakdown when the bucket is one day of tokens, else the
    /// bucket's total split by series
    @ViewBuilder
    private func bucketTip(_ c: Column, keys: [String], average: Double) -> some View {
        let note = deviation(c.total, average: average)
        if !report.weeklyBuckets, report.metric == .tokens, let day = report.days.first(where: { $0.date == c.key }) {
            DayDetailTip(day: day, colors: colors, exact: exact, note: note)
        } else {
            let title = report.weeklyBuckets ? L("Week of \(Fmt.shortDate(c.key))") : DayDetailTip.dateTitle(c.key)
            TipCard(title: title, subtitle: note, value: Fmt.metric(c.total, report.metric, exact: exact)) {
                if c.total <= 0 {
                    Text(report.weeklyBuckets ? L("No usage this week") : L("No usage this day")).font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    seriesRows(c, keys: keys)
                }
            }
        }
    }

    /// Readout for one time slot of the day
    @ViewBuilder
    private func slotTip(_ s: IntradaySlot, column c: Column, keys: [String], average: Double, slots: [IntradaySlot]) -> some View {
        if s.future {
            EmptyView()
        } else {
            let cumulative = slots.filter { $0.id <= s.id }.reduce(0) { $0 + $1.total }
            let label = String(format: "%d:%02d – %d:%02d", Int(s.start), Int(s.start * 60) % 60, Int(s.end), Int(s.end * 60) % 60)
            TipCard(title: label, subtitle: s.current ? L("In progress") : nil, value: Fmt.metric(s.total, report.metric, exact: exact)) {
                if s.total == 0 {
                    Text("No usage in this slot").font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    if average > 0 {
                        // How this slot compares with a typical one
                        TipRow(label: intradayAverageLabel(average), value: String(format: "×%.1f", s.total / average))
                    }
                    seriesRows(c, keys: keys)
                }
                Divider().overlay(Palette.hairline)
                TipRow(label: L("Day total so far"), value: Fmt.metric(cumulative, report.metric, exact: false))
            }
        }
    }

    /// A distribution bar and one row per series with usage, largest first
    @ViewBuilder
    private func seriesRows(_ c: Column, keys: [String]) -> some View {
        let parts = zip(keys, c.values).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        if parts.count > 1 {
            TipBar(parts: parts.map { (groupColor($0.0), $0.1) })
            ForEach(parts, id: \.0) { g, v in
                TipRow(color: groupColor(g), label: groupName(g), value: Fmt.metric(v, report.metric, exact: false),
                       secondary: percent(v / max(1e-9, c.total)))
            }
        }
    }

    /// "12% above daily avg"; nil without an average or for an empty bucket
    private func deviation(_ value: Double, average: Double) -> String? {
        guard !isDay, settings.usageShowAverage, average > 0, value > 0 else { return nil }
        let pct = String(format: "%.0f%%", abs(value - average) / average * 100)
        return value >= average
            ? (report.weeklyBuckets ? L("\(pct) above weekly avg") : L("\(pct) above daily avg"))
            : (report.weeklyBuckets ? L("\(pct) below weekly avg") : L("\(pct) below daily avg"))
    }

    // MARK: Legend

    /// Legend chips below or beside the chart: they wrap, so many models never overflow the card. A click
    /// puts that series in focus; a second click releases it.
    private func legend(_ keys: [String], focus: String?, trailing: Bool) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 2, alignment: trailing ? .trailing : .leading) {
            ForEach(keys, id: \.self) { g in
                let lit = focus == nil || focus == g
                HStack(spacing: 5) {
                    Swatch(lit ? groupColor(g) : Palette.muted, size: 7)
                    Text(groupName(g)).font(.app(Typo.small, focus == g ? .semibold : .regular))
                        .foregroundStyle(focus == g ? .primary : .secondary).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(Capsule().fill(Color.white.opacity(focus == g ? 0.09 : 0)))
                .opacity(lit ? 1 : 0.55)
                .contentShape(Capsule())
                .onTapGesture { withAnimation(Motion.data) { self.focus = focus == g ? nil : g } }
                .help(focus == g ? L("Click to show every series again") : L("Click to focus on \(groupName(g))"))
            }
        }
        // The chips carry their own padding; keep the first swatch on the card's edge
        .padding(.horizontal, -6)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .animation(.smooth(duration: 0.3), value: keys)
    }

    // MARK: Day switcher

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

    // MARK: Series

    private var title: String {
        if isDay { return "\(report.metric.localizedLabel) · \(settings.intradayMinutes == 60 ? L("Hourly") : L("Every 30 min"))" }
        return "\(report.metric.localizedLabel) · \(report.weeklyBuckets ? L("Weekly") : L("Daily"))"
    }

    /// Colour slots, fixed per stacking mode so a range switch morphs the columns instead of reshuffling them
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

    private func multiDayColumns(_ keys: [String]) -> [Column] {
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
                return Column(key: group.first!.date, values: keys.map { grouped[$0] ?? 0 })
            }
        }
        return report.buckets.map { b in
            var grouped: [String: Double] = [:]
            for (model, v) in b.byModel { grouped[stack == "none" ? "total" : colors.group(model), default: 0] += v }
            return Column(key: b.start, values: keys.map { grouped[$0] ?? 0 })
        }
    }
}

/// Which bars of a chart carry a date label: the newest always does, then every `step`th bar before it,
/// so at most `limit` labels share the width and none collide
enum BarLabels {
    static func keep(count: Int, limit: Int) -> (Int) -> Bool {
        guard count > 0 else { return { _ in false } }
        let step = max(1, Int((Double(count) / Double(max(1, limit))).rounded(.up)))
        return { i in (count - 1 - i) % step == 0 }
    }
}

/// "Daily avg 1.2 M" / "Weekly avg 1.2 M"
func averageLabel(_ value: String, weekly: Bool) -> String {
    weekly ? L("Weekly avg \(value)") : L("Daily avg \(value)")
}

// MARK: - 1D: half-hour / hourly slots

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
