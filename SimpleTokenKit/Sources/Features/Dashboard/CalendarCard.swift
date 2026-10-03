import SwiftUI
import Core
import DesignSystem

// MARK: - Calendar heatmap (one hue, five steps)

/// Usage per day as week columns of rounded cells. Brightness has five steps, each a fifth of the days
/// with usage, so a typical day sits mid-scale whatever the amounts and one huge day cannot flatten the rest.
struct CalendarCard: View {
    let history: [DailyHistoryArchive.DaySummary]
    let liveToday: DailyHistoryArchive.DaySummary?
    let rangeDays: Int
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var hovered: String?
    @State private var flipped = false
    /// How many weeks fit in the grid area (cells up to 14 / 18 / 22 pt, set by the widget size)
    @State private var fitWeeks = 26
    @Environment(\.cardSize) private var cardSize
    private var entrance = Entrance()

    private var accent: Color { settings.accent("card.calendar", .green) }
    /// Weeks shown: fills the widget by default, capped by the limit when one is set
    private var weeks: Int {
        settings.calendarWeeks > 0 ? min(settings.calendarWeeks, fitWeeks) : fitWeeks
    }

    nonisolated static let gap: CGFloat = 2
    nonisolated static let labelW: CGFloat = 16
    nonisolated static let monthH: CGFloat = 13

    nonisolated static func fit(_ size: CGSize, maxCell: CGFloat) -> Int {
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
        let active = cells.filter { $0.day.tokens > 0 }.count
        let grid = gridView(weeks: weeks, cells: cells, values: values)
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.calendar.localizedName, icon: SettingsStore.Card.calendar.icon, tint: accent, onSettings: { flipped = true }) {
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
    }

    private func headline(active: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            BigNumber(L("\(active) days"), size: WidgetStyle.number(.large) - 2)
            Text("Active out of \(total)").font(.app(Typo.small)).foregroundStyle(.tertiary)
        }
    }

    /// Day → one of five steps (0.2 … 1; 0 for an idle day): fifths of the active days
    private func steps(_ values: [Double]) -> [Double] {
        let active = values.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return values.map { _ in 0 } }
        let cuts = (1...4).map { active[min(active.count - 1, active.count * $0 / 5)] }
        return values.map { v in v <= 0 ? 0 : Double((cuts.firstIndex { v < $0 } ?? 4) + 1) / 5 }
    }

    /// The whole grid is drawn at once (Canvas) and hover finds the cell by coordinates: hundreds of small views with their own animation and hover handling are too heavy
    private func gridView(weeks: Int, cells: [Cell], values: [Double]) -> some View {
        let levels = steps(values)
        let maxCell: CGFloat = cardSize == .medium ? 14 : cardSize == .wide ? 22 : 18
        return GeometryReader { geo in
            let cell = CalendarCanvas.cellSize(geo.size, weeks: weeks)
            let step = cell + Self.gap
            CalendarCanvas(progress: entrance.amount, levels: AnimatableVector(levels),
                           cells: cells.map { .init(id: $0.id, week: $0.week, weekday: $0.weekday) },
                           weeks: weeks, months: monthLabels(weeks: weeks), accent: accent, hovered: hovered, today: Fmt.dayKey())
                .onAppear { entrance.start(.smooth(duration: 0.9)) }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, tip?.scrolling != true, p.x >= Self.labelW else { hover(nil, at: nil, values: values); return }
                    let week = Int(floor((p.x - Self.labelW) / step)), weekday = Int(floor(p.y / step))
                    guard let hit = cells.first(where: { $0.week == week && $0.weekday == weekday }) else { hover(nil, at: nil, values: values); return }
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    hover(hit, at: CGPoint(x: origin.x + Self.labelW + CGFloat(week) * step + cell / 2, y: origin.y + CGFloat(weekday) * step), values: values)
                }
        }
        .animation(Motion.data, value: settings.calendarMetric)
        .onGeometryChange(for: Int.self, of: { Self.fit($0.size, maxCell: maxCell) }) { fitWeeks = $0 }
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

    /// Less → more: the five steps of the scale
    private var scale: some View {
        HStack(spacing: 3) {
            Text("Less").font(.app(Typo.axis)).foregroundStyle(.tertiary)
            ForEach([0.0, 0.2, 0.4, 0.6, 0.8, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(level == 0 ? AnyShapeStyle(Depth.groove) : AnyShapeStyle(accent.fill.opacity(CalendarCanvas.strength(level))))
                    .frame(width: 9, height: 9)
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
        if hovered != c.id { hovered = c.id }
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
        tip?.show(tipID, key: c.id, at: p, glide: true) { DayDetailTip(day: c.day, colors: colors, exact: exact, note: note) }
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

/// Calendar grid: rounded cells in week columns and weekday rows (cell size from the smaller of width and
/// height), months along the bottom. Columns fade in one by one as progress goes 0→1; a metric switch
/// morphs the shades.
private struct CalendarCanvas: View, Animatable {
    struct Cell { let id: String; let week: Int; let weekday: Int }
    var progress: Double
    /// Per cell: the step of the scale, 0.2 … 1 (0 for an idle day)
    var levels: AnimatableVector
    let cells: [Cell]
    let weeks: Int
    let months: [(week: Int, text: String)]
    let accent: Color
    let hovered: String?
    let today: String

    nonisolated var animatableData: AnimatablePair<Double, AnimatableVector> {
        get { AnimatablePair(progress, levels) }
        set {
            progress = newValue.first
            levels = newValue.second
        }
    }

    static func cellSize(_ size: CGSize, weeks: Int) -> CGFloat {
        let gap = CalendarCard.gap
        let byWidth = (size.width - CalendarCard.labelW - gap * CGFloat(weeks - 1)) / CGFloat(max(1, weeks))
        let byHeight = (size.height - CalendarCard.monthH - gap * 6) / 7
        return max(2, min(byWidth, byHeight))
    }

    /// How strongly a step of the scale is drawn: each step clearly brighter than the one before
    static func strength(_ level: Double) -> Double {
        0.2 + 0.8 * pow(min(1, max(0, (level - 0.2) / 0.8)), 1.2)
    }

    var body: some View {
        Canvas { ctx, size in
            let gap = CalendarCard.gap, labelW = CalendarCard.labelW
            let cell = Self.cellSize(size, weeks: weeks)
            let radius = min(3, cell / 4)
            for (i, text) in [0, 2, 4].map({ Fmt.weekdayInitialsFromMonday[$0] }).enumerated() {
                ctx.text(Text(text).font(.app(Typo.axis)).foregroundStyle(Ink.tertiary),
                         at: CGPoint(x: 0, y: CGFloat(i * 2) * (cell + gap) + cell / 2), anchor: .leading)
            }
            let bottom = 7 * (cell + gap)
            // Newest month first: a label that would run into the one after it is left out
            var limit = CGFloat.infinity
            for m in months.reversed() {
                let label = ctx.resolve(Text(m.text).font(.app(Typo.axis)).foregroundStyle(Ink.tertiary))
                let x = labelW + CGFloat(m.week) * (cell + gap)
                guard x + label.measure(in: CGSize(width: 200, height: 40)).width + 5 <= limit else { continue }
                ctx.text(label, at: CGPoint(x: x, y: bottom + 1), anchor: .topLeading)
                limit = x
            }
            let tone = Depth.Tone(accent)
            let spread = 0.5 / Double(max(1, weeks))
            var hoveredRect: CGRect?
            var todayRect: CGRect?
            for (i, c) in cells.enumerated() {
                let t = min(1, max(0, (progress - Double(c.week) * spread) * 2))
                guard t > 0 else { continue }
                let rect = CGRect(x: labelW + CGFloat(c.week) * (cell + gap), y: CGFloat(c.weekday) * (cell + gap),
                                  width: cell, height: cell)
                let level = min(1, max(0, levels[i]))
                if level > 0.004 {
                    ctx.cell(rect, tone: tone, radius: radius, opacity: Self.strength(level) * t)
                } else {
                    var layer = ctx
                    layer.opacity = t
                    layer.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(Depth.groove))
                }
                if c.id == hovered { hoveredRect = rect }
                if c.id == today { todayRect = rect }
            }
            if let r = todayRect, hovered != today {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1, style: .continuous),
                           with: .color(accent.opacity(0.9)), lineWidth: 1)
            }
            if let r = hoveredRect {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1.5, style: .continuous),
                           with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
        }
    }
}
