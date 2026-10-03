import SwiftUI
import Core
import DesignSystem

// MARK: - Time of day: weekday × hour, dot area = usage

/// When the work happens: a dot per weekday and hour whose area is the usage in that slot over the last
/// days (Claude Code session logs). Hovering a dot names its models.
struct PunchcardCard: View {
    let card: IntradayScanner.Punchcard
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var hovered: Int?
    @State private var flipped = false
    @Environment(\.cardSize) private var cardSize
    private var entrance = Entrance()

    private var accent: Color { settings.accent("card.punchcard", .green) }

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
        let maxValue = Double(max(1, grid.flatMap { $0 }.max() ?? 0))
        let busiest = busiestHour
        let dots = GeometryReader { geo in
            let colW = (geo.size.width - PunchcardCanvas.labelW) / 24
            let rowH = (geo.size.height - PunchcardCanvas.axisH) / 7
            PunchcardCanvas(progress: entrance.amount, values: AnimatableVector(grid.flatMap { $0.map { Double($0) / maxValue } }),
                            accent: accent, hovered: hovered)
                .onAppear { entrance.start(.smooth(duration: 0.9)) }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, tip?.scrolling != true, p.x >= PunchcardCanvas.labelW, p.y >= 0, p.y < 7 * rowH else {
                        hover(nil, at: nil)
                        return
                    }
                    let h = min(23, Int((p.x - PunchcardCanvas.labelW) / colW)), d = min(6, Int(p.y / rowH))
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    // The readout sits over the dot, not the pointer
                    hover(d * 24 + h, at: CGPoint(x: origin.x + PunchcardCanvas.labelW + (CGFloat(h) + 0.5) * colW,
                                                  y: origin.y + CGFloat(d) * rowH + rowH * 0.15))
                }
        }
        .animation(Motion.data, value: settings.punchcardDays)
        let headline = VStack(alignment: .leading, spacing: 1) {
            BigNumber(busiest.map { String(format: "%d:00", $0) } ?? "—", size: WidgetStyle.number(.large) - 2)
            Text("Busiest hour").font(.app(Typo.small)).foregroundStyle(.tertiary)
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.punchcard.localizedName, icon: SettingsStore.Card.punchcard.icon, tint: accent, onSettings: { flipped = true }) {
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
        if hovered != idx { hovered = idx }
        let d = idx / 24, h = idx % 24
        let v = card.grid[d][h]
        let total = max(1, card.grid.flatMap { $0 }.reduce(0, +))
        let times = max(1, card.dayCount[d])
        let models = card.models[d][h].sorted { $0.value > $1.value }
        let weekday = Fmt.weekdaysFromMonday[d]
        tip?.show(tipID, key: "\(idx)", at: p, glide: true) {
            TipCard(title: "\(weekday) \(h):00 – \(h + 1):00", subtitle: L("Last \(settings.punchcardDays) days · \(times) × \(weekday)"),
                    value: v > 0 ? Fmt.tokens(Double(v), exact: exact) : nil) {
                if v == 0 {
                    Text("No usage in this slot").font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    TipRow(label: L("Share"), value: percent(Double(v) / Double(total)))
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

/// Time of day: weekday × hour dots, area ∝ usage, on a faint grid; they grow from top left to bottom
/// right as progress goes 0→1, and a new range morphs their sizes
private struct PunchcardCanvas: View, Animatable {
    static let labelW: CGFloat = 16
    static let axisH: CGFloat = 14

    var progress: Double
    /// 7 × 24 values, each a share of the busiest slot (0…1)
    var values: AnimatableVector
    let accent: Color
    let hovered: Int?

    nonisolated var animatableData: AnimatablePair<Double, AnimatableVector> {
        get { AnimatablePair(progress, values) }
        set {
            progress = newValue.first
            values = newValue.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let labelW = Self.labelW
            let colW = (size.width - labelW) / 24
            let rowH = (size.height - Self.axisH) / 7
            // Label every other row when rows are short, so weekday labels do not collide
            for d in 0..<7 where rowH >= 13 || d % 2 == 0 {
                ctx.text(Text(Fmt.weekdayInitialsFromMonday[d]).font(.app(Typo.axis)).foregroundStyle(Ink.tertiary),
                         at: CGPoint(x: 0, y: CGFloat(d) * rowH + rowH / 2), anchor: .leading)
            }
            for h in [0, 6, 12, 18] {
                ctx.text(Text(verbatim: "\(h):00").font(.app(Typo.axis)).foregroundStyle(Ink.tertiary),
                         at: CGPoint(x: labelW + CGFloat(h) * colW + colW / 2, y: 7 * rowH + 2), anchor: .top)
            }
            // A faint grid: a hairline under each row and one every six hours
            for d in 0...7 {
                ctx.fill(Path(CGRect(x: labelW, y: CGFloat(d) * rowH - 0.5, width: colW * 24, height: 1)), with: .color(Palette.hairline))
            }
            for h in stride(from: 0, through: 24, by: 6) {
                ctx.fill(Path(CGRect(x: labelW + CGFloat(h) * colW - 0.5, y: 0, width: 1, height: rowH * 7)), with: .color(Palette.hairline))
            }
            let tone = Depth.Tone(accent)
            let maxR = min(colW, rowH) / 2 - 1
            var lifted: (center: CGPoint, radius: CGFloat)?
            for d in 0..<7 {
                for h in 0..<24 {
                    let v = min(1, max(0, values[d * 24 + h]))
                    let delay = Double(h) / 24 * 0.35 + Double(d) / 7 * 0.15
                    let t = min(1, max(0, (progress - delay) / 0.5))
                    guard t > 0 else { continue }
                    let center = CGPoint(x: labelW + (CGFloat(h) + 0.5) * colW, y: (CGFloat(d) + 0.5) * rowH)
                    guard v > 0.0005 else {
                        // Nothing here: a speck marks the slot
                        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)), with: .color(.white.opacity(0.1 * t)))
                        continue
                    }
                    let fraction = v.squareRoot()
                    let r = max(1.5, CGFloat(fraction) * maxR) * CGFloat(t)
                    if hovered == d * 24 + h {
                        lifted = (center, r)
                        continue
                    }
                    ctx.dot(center: center, radius: r, tone: tone, opacity: 0.7 + 0.3 * fraction)
                }
            }
            // The hovered dot comes last, a little larger and ringed, so it sits over its neighbours
            if let lifted {
                let r = lifted.radius * 1.15 + 0.5
                ctx.dot(center: lifted.center, radius: r, tone: tone)
                ctx.stroke(Path(ellipseIn: CGRect(x: lifted.center.x - r - 1.5, y: lifted.center.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2)),
                           with: .color(.white.opacity(0.9)), lineWidth: 1.2)
            }
        }
    }
}
