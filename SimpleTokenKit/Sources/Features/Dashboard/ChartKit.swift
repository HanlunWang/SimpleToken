import SwiftUI
import AppKit
import Core
import DesignSystem

// One chart kit for the whole dashboard, so every mark has the same look and moves the same way.
//
// Look: nearly flat and rounded at every corner, with a hint of light from the top left. A fill runs
// from a slightly lighter step of its hue to the hue itself, a faint sheen crosses a bar, lines cast a soft
// shadow, tracks are shallow grooves. No coloured glow, no gloss, no spheres.
//
// Motion: charts are drawn in a Canvas inside an `Animatable` view. Their numbers travel in an
// `AnimatableVector`, so switching the range or the metric morphs every chart from the old values to the
// new ones (`Motion.data`) instead of redrawing it.

enum Motion {
    /// The system's reduce-motion setting is on: charts and tips move without animation
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The data under the charts changed: a range, a metric or a filter was switched
    static var data: Animation? { reduced ? nil : .smooth(duration: 0.6) }
    /// A mark is hovered: the others step back
    static var hover: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
}

private struct ChartEntranceKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Charts grow in when they appear. Off for the copy of a widget that floats under the pointer while it is dragged.
    var chartEntrance: Bool {
        get { self[ChartEntranceKey.self] }
        set { self[ChartEntranceKey.self] = newValue }
    }
}

/// Whether a chart has appeared: its marks grow from nothing the first time it is shown
struct Entrance: DynamicProperty {
    @State private var shown = false
    @Environment(\.chartEntrance) private var enabled

    /// 0 before the chart has appeared, 1 after; multiply mark sizes by it
    var amount: Double { shown || !enabled ? 1 : 0 }

    func start(_ animation: Animation? = Motion.data) {
        guard !shown else { return }
        withAnimation(Motion.reduced ? nil : animation?.delay(0.08)) { shown = true }
    }
}

/// Text drawn inside a Canvas (the label colours of the dark appearance)
enum Ink {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
}

/// A list of numbers SwiftUI can interpolate. Lists of different lengths are padded with zeros, so a
/// mark that has no counterpart grows from nothing or shrinks to nothing.
struct AnimatableVector: VectorArithmetic, Sendable {
    var values: [Double]

    init(_ values: [Double] = []) { self.values = values }

    static var zero: AnimatableVector { AnimatableVector() }

    subscript(i: Int) -> Double { i >= 0 && i < values.count ? values[i] : 0 }

    private static func combine(_ a: AnimatableVector, _ b: AnimatableVector, _ op: (Double, Double) -> Double) -> AnimatableVector {
        let n = max(a.values.count, b.values.count)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n { out[i] = op(a[i], b[i]) }
        return AnimatableVector(out)
    }

    static func + (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector { combine(a, b, +) }
    static func - (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector { combine(a, b, -) }

    mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

// MARK: - Depth

enum Depth {
    /// A hue's fill colours, resolved once per draw (resolving a colour is not free)
    struct Tone {
        let color: Color
        let light: Color
        let gradient: Gradient

        init(_ color: Color) {
            self.color = color
            light = color.lit
            gradient = Gradient(colors: [light, color])
        }
    }

    /// Light from the left, shade on the right: makes a flat bar read as a rounded column
    static let sheen = Gradient(stops: [
        .init(color: .white.opacity(0.06), location: 0),
        .init(color: .white.opacity(0), location: 0.42),
        .init(color: .black.opacity(0), location: 0.58),
        .init(color: .black.opacity(0.08), location: 1),
    ])

    /// The same light for a horizontal bar: bright along the top, shaded underneath
    static let gloss = LinearGradient(stops: [
        .init(color: .white.opacity(0.12), location: 0),
        .init(color: .white.opacity(0), location: 0.5),
        .init(color: .black.opacity(0.06), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// Inside of a groove
    static let groove = Color.black.opacity(0.24)
    static let grooveEdge = Color.white.opacity(0.06)
}

extension GraphicsContext {
    /// A column of stacked segments (bottom first), rounded at every corner like every other mark, with a
    /// 1 px gap between segments. A segment's `colour` is 1 when it wears its hue and 0 when it is muted
    /// because another series is in focus.
    func column(_ rect: CGRect, segments: [(tone: Depth.Tone, height: CGFloat, colour: Double)], radius: CGFloat = 4, opacity: Double = 1) {
        guard rect.width > 0.4, rect.height > 0.4, opacity > 0.01 else { return }
        var layer = self
        layer.opacity = opacity
        let r = min(radius, rect.width / 2, rect.height / 2)
        layer.clip(to: Path(roundedRect: rect, cornerRadius: r, style: .continuous))
        let visible = segments.filter { $0.height > 0.3 }
        var y = rect.maxY
        for (i, segment) in visible.enumerated() {
            let gap: CGFloat = i < visible.count - 1 && segment.height > 2.5 ? 1 : 0
            let box = CGRect(x: rect.minX, y: y - segment.height + gap, width: rect.width, height: segment.height - gap)
            let colour = min(1, max(0, segment.colour))
            if colour < 0.999 { layer.fill(Path(box), with: .color(Palette.muted)) }
            if colour > 0.001 {
                var tinted = layer
                tinted.opacity = opacity * colour
                tinted.fill(Path(box), with: .linearGradient(segment.tone.gradient, startPoint: CGPoint(x: box.midX, y: box.minY), endPoint: CGPoint(x: box.midX, y: box.maxY)))
            }
            layer.fill(Path(box), with: .linearGradient(Depth.sheen, startPoint: CGPoint(x: box.minX, y: box.midY), endPoint: CGPoint(x: box.maxX, y: box.midY)))
            y -= segment.height
        }
        // The top edge catches the light
        layer.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)), with: .color(.white.opacity(0.12)))
    }

    /// A column in one hue
    func column(_ rect: CGRect, tone: Depth.Tone, radius: CGFloat = 4, opacity: Double = 1, colour: Double = 1) {
        column(rect, segments: [(tone, rect.height, colour)], radius: radius, opacity: opacity)
    }

    /// A rounded cell lit from the top (calendar days, treemap tiles)
    func cell(_ rect: CGRect, tone: Depth.Tone, radius: CGFloat, opacity: Double = 1) {
        guard rect.width > 0.4, rect.height > 0.4, opacity > 0.01 else { return }
        var layer = self
        layer.opacity = opacity
        let path = Path(roundedRect: rect, cornerRadius: min(radius, rect.width / 2, rect.height / 2), style: .continuous)
        if rect.width < 8 {
            layer.fill(path, with: .color(tone.color))
        } else {
            layer.fill(path, with: .linearGradient(tone.gradient, startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
    }

    /// A round dot with a hint of a sphere: lit top left, a touch darker at the lower right (punchcard, scatter)
    func dot(center: CGPoint, radius: CGFloat, tone: Depth.Tone, opacity: Double = 1) {
        guard radius > 0.3, opacity > 0.01 else { return }
        var layer = self
        layer.opacity = opacity
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        layer.fill(Path(ellipseIn: rect), with: .color(tone.color))
        if radius >= 3 {
            layer.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(stops: [
                .init(color: .white.opacity(0.22), location: 0),
                .init(color: .white.opacity(0), location: 0.65),
                .init(color: .black.opacity(0.12), location: 1),
            ]), center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3), startRadius: 0, endRadius: radius * 1.3))
        }
    }

    /// Text with its origin on a whole pixel. Every chart draws its text through this, so labels stay
    /// crisp and do not shimmer while the marks they sit on morph.
    func text(_ resolved: GraphicsContext.ResolvedText, at point: CGPoint, anchor: UnitPoint = .center) {
        let size = resolved.measure(in: CGSize(width: 4000, height: 400))
        let scale = max(1, environment.displayScale)
        let origin = CGPoint(x: ((point.x - size.width * anchor.x) * scale).rounded() / scale,
                             y: ((point.y - size.height * anchor.y) * scale).rounded() / scale)
        draw(resolved, at: origin, anchor: .topLeading)
    }

    func text(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) {
        self.text(resolve(text), at: point, anchor: anchor)
    }

    /// Text, kept inside `bounds` horizontally
    func label(_ text: Text, at point: CGPoint, anchor: UnitPoint, within bounds: ClosedRange<CGFloat>) {
        let resolved = resolve(text)
        let width = resolved.measure(in: CGSize(width: 1000, height: 100)).width
        let left = point.x - width * anchor.x
        let shift = max(bounds.lowerBound - left, 0) + min(bounds.upperBound - (left + width), 0)
        self.text(resolved, at: CGPoint(x: point.x + shift, y: point.y), anchor: anchor)
    }
}

enum ChartAxis {
    /// Round tick values from zero up to `top` (zero included)
    static func ticks(upTo top: Double, count: Int = 4) -> [Double] {
        guard top > 0, top.isFinite else { return [0] }
        let raw = top / Double(count)
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw * 0.999 } ?? raw
        return Array(stride(from: 0, through: top * 1.0001, by: step))
    }

    /// Tick labels for a metric (always short)
    static func format(_ metric: UsageMetric) -> (Double) -> String {
        switch metric {
        case .tokens: tokens
        case .cost: money
        case .messages: { $0 >= 10_000 ? Fmt.short($0) : Fmt.exact(Int($0.rounded())) }
        }
    }

    static let tokens: @Sendable (Double) -> String = { Fmt.short($0) }
    /// Round money ticks drop their cents so they fit the gutter ("$600", not "$600.00")
    static let money: @Sendable (Double) -> String = { value in
        value == value.rounded() ? "$" + Fmt.exact(Int(value)) : Fmt.money(value)
    }

    static let gutter: CGFloat = 40
    static let labelHeight: CGFloat = 15

    /// Room for the tick labels right of the plot: the usual gutter, wider when a label needs it
    /// (CJK units such as the hundred-million sign are wider than "B" or "M")
    static func gutter(for labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Typo.axis, weight: .medium)
        let widest = labels.reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes: [.font: font]).width) }
        return max(gutter, (widest * 1.06).rounded(.up) + 10)
    }
}

// MARK: - Bars

/// Vertical bars, plain or stacked, in the dashboard's depth style. Hovering a bar dims the others and
/// shows a readout above it; switching data morphs heights, and bars slide when their number changes
/// (the newest bar stays at the right edge).
struct BarChart: View {
    struct Bar: Identifiable {
        let id: String
        /// One value per colour, bottom first
        var segments: [Double]
        /// 1 is full strength; context bars (future hours, other periods) are fainter
        var emphasis: Double = 1
        /// Under the bar
        var label: String?
        /// Above the bar: a count, a marker ("now"), or the amount of a bar that was cut off
        var cap: String?
    }

    let bars: [Bar]
    let colors: [Color]
    /// Top of the scale; by default a little above the tallest bar
    var top: Double?
    /// Grid lines and tick labels on the right
    var axis = true
    var format: (Double) -> String = ChartAxis.tokens
    /// A dashed line across the bars (the average)
    var rule: (value: Double, label: String)?
    var ratio: CGFloat = 0.68
    var maxBarWidth: CGFloat = 34
    var tipID = "bars"
    /// The colour slot in focus: the other segments turn grey
    var focus: Int?
    var tip: ((Int) -> AnyView)?
    var onTap: ((Int) -> Void)?

    init(bars: [Bar], colors: [Color], top: Double? = nil, axis: Bool = true, format: @escaping (Double) -> String = ChartAxis.tokens,
         rule: (value: Double, label: String)? = nil, ratio: CGFloat = 0.68, maxBarWidth: CGFloat = 34, tipID: String = "bars",
         focus: Int? = nil, tip: ((Int) -> AnyView)? = nil, onTap: ((Int) -> Void)? = nil) {
        self.bars = bars
        self.colors = colors
        self.top = top
        self.axis = axis
        self.format = format
        self.rule = rule
        self.ratio = ratio
        self.maxBarWidth = maxBarWidth
        self.tipID = tipID
        self.focus = focus
        self.tip = tip
        self.onTap = onTap
    }

    @State private var hovered: Int?
    private var entrance = Entrance()
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    private var scaleTop: Double {
        max(top ?? (bars.map { $0.segments.reduce(0, +) }.max() ?? 0) * 1.08, 1e-9)
    }

    var body: some View {
        let top = scaleTop
        let groups = max(1, colors.count)
        let ticks = axis ? ChartAxis.ticks(upTo: top) : []
        let layout = BarLayout(axis: axis, labels: bars.contains { $0.label != nil }, caps: bars.contains { $0.cap != nil },
                               gutter: ChartAxis.gutter(for: ticks.map(format)))
        // Right-anchored: slot 0 is the newest bar, so a longer range adds bars on the left
        let reversed = bars.reversed()
        let grow = entrance.amount
        let values = reversed.flatMap { bar in (0..<groups).map { $0 < bar.segments.count ? max(0, bar.segments[$0]) * grow : 0 } }
        let emphasis = reversed.enumerated().map { j, bar in
            bar.emphasis * (hovered == nil || hovered == bars.count - 1 - j ? 1 : 0.45)
        }
        BarCanvas(count: Double(bars.count), top: top, values: AnimatableVector(values), emphasis: AnimatableVector(emphasis),
                  colour: AnimatableVector((0..<groups).map { focus == nil || focus == $0 ? 1 : 0 }), bars: bars, tones: colors.map(Depth.Tone.init), ticks: ticks, format: format,
                  rule: rule, layout: layout, ratio: ratio, maxBarWidth: maxBarWidth, hovered: hovered)
            .animation(Motion.hover, value: hovered)
            .animation(Motion.data, value: focus)
            .onAppear { entrance.start() }
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            guard case .active(let p) = phase, hoverTip?.scrolling != true, let i = index(at: p, size: geo.size, layout: layout) else {
                                hovered = nil
                                hoverTip?.hide(tipID)
                                return
                            }
                            hovered = i
                            guard let tip else { return }
                            let plot = layout.plot(in: geo.size)
                            let slot = plot.width / CGFloat(max(1, bars.count))
                            let total = bars[i].segments.reduce(0, +)
                            let origin = geo.frame(in: .named(HoverTip.space)).origin
                            let anchor = CGPoint(x: origin.x + plot.minX + (CGFloat(i) + 0.5) * slot,
                                                 y: origin.y + plot.maxY - plot.height * CGFloat(min(1, total / top)))
                            hoverTip?.show(tipID, key: bars[i].id, at: anchor, glide: true) { tip(i) }
                        }
                        .onTapGesture { location in
                            if let i = index(at: location, size: geo.size, layout: layout) { onTap?(i) }
                        }
                }
            }
    }

    private func index(at point: CGPoint, size: CGSize, layout: BarLayout) -> Int? {
        let plot = layout.plot(in: size)
        guard !bars.isEmpty, point.x >= plot.minX, point.x <= plot.maxX else { return nil }
        return min(bars.count - 1, Int((point.x - plot.minX) / (plot.width / CGFloat(bars.count))))
    }
}

struct BarLayout: Equatable {
    var axis: Bool
    var labels: Bool
    var caps: Bool
    var gutter: CGFloat = ChartAxis.gutter

    func plot(in size: CGSize) -> CGRect {
        let top: CGFloat = caps ? 13 : axis ? 5 : 1
        let bottom: CGFloat = labels ? ChartAxis.labelHeight : 0
        let trailing: CGFloat = axis ? gutter : 0
        return CGRect(x: 0, y: top, width: max(1, size.width - trailing), height: max(1, size.height - top - bottom))
    }
}

private struct BarCanvas: View, Animatable {
    var count: Double
    var top: Double
    var values: AnimatableVector
    var emphasis: AnimatableVector
    /// Per colour slot: 1 wears its hue, 0 is muted
    var colour: AnimatableVector

    let bars: [BarChart.Bar]
    let tones: [Depth.Tone]
    let ticks: [Double]
    let format: (Double) -> String
    let rule: (value: Double, label: String)?
    let layout: BarLayout
    let ratio: CGFloat
    let maxBarWidth: CGFloat
    let hovered: Int?

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<AnimatableVector, AnimatablePair<AnimatableVector, AnimatableVector>>> {
        get { AnimatablePair(AnimatablePair(count, top), AnimatablePair(values, AnimatablePair(emphasis, colour))) }
        set {
            count = newValue.first.first
            top = newValue.first.second
            values = newValue.second.first
            emphasis = newValue.second.second.first
            colour = newValue.second.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let plot = layout.plot(in: size)
            let top = max(top, 1e-9)
            let groups = max(1, tones.count)
            let slot = plot.width / CGFloat(max(1, count))
            let width = min(maxBarWidth, max(1.5, slot * ratio))
            func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(value / top) }

            for tick in ticks {
                let ty = y(tick)
                guard ty >= plot.minY - 2 else { continue }
                ctx.fill(Path(CGRect(x: plot.minX, y: ty - 0.5, width: plot.width, height: 1)), with: .color(Palette.hairline))
                ctx.text(Text(format(tick)).font(.num(Typo.axis, .medium)).foregroundStyle(Ink.tertiary),
                         at: CGPoint(x: plot.maxX + 6, y: ty), anchor: .leading)
            }

            // A soft band behind the hovered bar
            if let hovered, hovered < bars.count {
                let x = plot.maxX - (CGFloat(bars.count - 1 - hovered) + 0.5) * slot
                let band = CGRect(x: x - slot / 2 + 0.5, y: plot.minY - 2, width: max(1, slot - 1), height: plot.height + 2)
                ctx.fill(Path(roundedRect: band, cornerRadius: min(5, slot / 3)), with: .color(.white.opacity(0.055)))
            }

            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: plot.minX, y: 0, width: plot.width, height: size.height)))
            let slots = Int((Double(values.values.count) / Double(groups)).rounded(.up))
            for j in 0..<slots {
                let x = plot.maxX - (CGFloat(j) + 0.5) * slot
                guard x > plot.minX - slot else { break }
                var segments: [(tone: Depth.Tone, height: CGFloat, colour: Double)] = []
                var height: CGFloat = 0
                for g in 0..<groups {
                    let h = plot.height * CGFloat(max(0, values[j * groups + g]) / top)
                    segments.append((tones[g], h, colour[g]))
                    height += h
                }
                height = min(height, plot.height + 1)
                if height < 0.4 {
                    // Nothing here: a faint tick on the baseline
                    clipped.fill(Path(roundedRect: CGRect(x: x - width / 2, y: plot.maxY - 1.5, width: width, height: 1.5), cornerRadius: 0.75),
                                 with: .color(.white.opacity(0.10 * min(1, emphasis[j] + 0.4))))
                    continue
                }
                clipped.column(CGRect(x: x - width / 2, y: plot.maxY - height, width: width, height: height), segments: segments,
                               radius: min(4, width * 0.3), opacity: min(1, max(0, emphasis[j])))
            }

            if let rule, rule.value > 0 {
                let ry = y(rule.value)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: ry))
                line.addLine(to: CGPoint(x: plot.maxX, y: ry))
                ctx.stroke(line, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if !rule.label.isEmpty {
                    ctx.text(Text(rule.label).font(.app(Typo.axis, .medium)).foregroundStyle(Ink.secondary),
                             at: CGPoint(x: plot.minX + 2, y: ry - 2), anchor: .bottomLeading)
                }
            }

            for (i, bar) in bars.enumerated() {
                let j = bars.count - 1 - i
                let x = plot.maxX - (CGFloat(j) + 0.5) * slot
                guard x > plot.minX - 1 else { continue }
                if let label = bar.label {
                    ctx.label(Text(label).font(.app(Typo.axis)).foregroundStyle(hovered == i ? Ink.secondary : Ink.tertiary),
                              at: CGPoint(x: x, y: plot.maxY + 4), anchor: .top, within: 0...size.width)
                }
                if let cap = bar.cap {
                    let total = (0..<groups).reduce(0.0) { $0 + values[j * groups + $1] }
                    ctx.label(Text(cap).font(.num(Typo.axis, .semibold)).foregroundStyle(hovered == i || bar.emphasis >= 1 ? Ink.secondary : Ink.tertiary),
                              at: CGPoint(x: x, y: max(plot.minY, y(total)) - 2), anchor: .bottom, within: 0...size.width)
                }
            }
        }
    }
}

// MARK: - Small bars

/// A row of small bars in one colour (stat tiles, trends). With a readout, hovering a bar dims the
/// others and shows what that bar stands for. A dashed `rule` (the average) can cross the bars.
struct SparkBars: View {
    let values: [Double]
    var color: Color = Palette.usage
    /// Per-bar strength, 1 by default
    var emphasis: [Double]?
    /// A dashed line at this value
    var rule: Double?
    var tipID: String?
    var tip: ((Int) -> AnyView)?
    private var entrance = Entrance()
    @State private var hovered: Int?
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    init(values: [Double], color: Color = Palette.usage, emphasis: [Double]? = nil, rule: Double? = nil, tipID: String? = nil, tip: ((Int) -> AnyView)? = nil) {
        self.values = values
        self.color = color
        self.emphasis = emphasis
        self.rule = rule
        self.tipID = tipID
        self.tip = tip
    }

    var body: some View {
        let top = max(values.max() ?? 0, rule ?? 0, 1e-9)
        let grow = entrance.amount
        let strength = values.indices.map { i in
            (emphasis.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? 1) * (hovered == nil || hovered == i ? 1 : 0.45)
        }
        let canvas = SparkCanvas(values: AnimatableVector(values.map { max(0, $0) / top * grow }), emphasis: AnimatableVector(strength),
                                 rule: (rule ?? 0) / top, present: values.map { $0 > 0 }, color: color)
            .onAppear { entrance.start() }
        if let tip, let tipID, !values.isEmpty {
            canvas
                .animation(Motion.hover, value: hovered)
                .overlay {
                    GeometryReader { geo in
                        // A taller hit area than the bars: short bars are still easy to point at
                        Color.clear.contentShape(Rectangle().inset(by: -4))
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                guard case .active(let p) = phase, hoverTip?.scrolling != true else {
                                    hovered = nil
                                    hoverTip?.hide(tipID)
                                    return
                                }
                                let slot = geo.size.width / CGFloat(values.count)
                                let i = min(values.count - 1, max(0, Int(p.x / slot)))
                                hovered = i
                                let origin = geo.frame(in: .named(HoverTip.space)).origin
                                let at = CGPoint(x: origin.x + (CGFloat(i) + 0.5) * slot, y: origin.y + geo.size.height * (1 - CGFloat(max(0, values[i]) / top)))
                                hoverTip?.show(tipID, key: "\(i)", at: at, glide: true) { tip(i) }
                            }
                    }
                }
        } else {
            canvas
        }
    }
}

private struct SparkCanvas: View, Animatable {
    var values: AnimatableVector
    var emphasis: AnimatableVector
    var rule: Double
    /// Bars that have a value (the others are a faint tick on the baseline)
    let present: [Bool]
    let color: Color

    nonisolated var animatableData: AnimatablePair<AnimatablePair<AnimatableVector, AnimatableVector>, Double> {
        get { AnimatablePair(AnimatablePair(values, emphasis), rule) }
        set {
            values = newValue.first.first
            emphasis = newValue.first.second
            rule = newValue.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = present.count
            guard n > 0 else { return }
            let tone = Depth.Tone(color)
            let gap: CGFloat = n > 16 ? 1.5 : n > 6 ? 2.5 : 4
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let x = CGFloat(i) * (w + gap)
                let h = size.height * CGFloat(min(1, values[i]))
                if !present[i], h < 0.5 {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - 1.5, width: w, height: 1.5), cornerRadius: 0.75), with: .color(.white.opacity(0.12)))
                    continue
                }
                let height = max(present[i] ? 2 : 0, h)
                ctx.column(CGRect(x: x, y: size.height - height, width: w, height: height), tone: tone, radius: min(3, w * 0.3),
                           opacity: min(1, max(0, emphasis[i])))
            }
            if rule > 0.001 {
                let ry = size.height * (1 - CGFloat(min(1, rule)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: ry))
                line.addLine(to: CGPoint(x: size.width, y: ry))
                ctx.stroke(line, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}

// MARK: - Small line

/// A small line with its area fading into the card and a dot at the newest point (stat tiles, panel).
/// Switching data morphs the line; with a readout, hovering marks a point.
struct SparkLine: View {
    let values: [Double]
    var color: Color = Palette.usage
    var tipID: String?
    var tip: ((Int) -> AnyView)?
    private var entrance = Entrance()
    @State private var hovered: Int?
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    init(values: [Double], color: Color = Palette.usage, tipID: String? = nil, tip: ((Int) -> AnyView)? = nil) {
        self.values = values
        self.color = color
        self.tipID = tipID
        self.tip = tip
    }

    static let samples = 60

    var body: some View {
        let top = max(values.max() ?? 0, 1e-9)
        let points = values.enumerated().map { (x: Double($0.offset) / Double(max(1, values.count - 1)), y: $0.element / top) }
        let canvas = SparkLineCanvas(values: AnimatableVector(AreaChart.sample(points.isEmpty ? [(0, 0)] : points, upTo: 1, samples: Self.samples).map { $0 * entrance.amount }),
                                     color: color, hovered: hovered.map { (x: Double($0) / Double(max(1, values.count - 1)), y: values[$0] / top) })
            .onAppear { entrance.start() }
        if let tip, let tipID, values.count > 1 {
            canvas
                .animation(Motion.hover, value: hovered)
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle().inset(by: -4))
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                guard case .active(let p) = phase, hoverTip?.scrolling != true else {
                                    hovered = nil
                                    hoverTip?.hide(tipID)
                                    return
                                }
                                let i = min(values.count - 1, max(0, Int((p.x / geo.size.width * CGFloat(values.count - 1)).rounded())))
                                hovered = i
                                let origin = geo.frame(in: .named(HoverTip.space)).origin
                                let at = CGPoint(x: origin.x + geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                                 y: origin.y + geo.size.height * (1 - CGFloat(values[i] / top)))
                                hoverTip?.show(tipID, key: "\(i)", at: at, glide: true) { tip(i) }
                            }
                    }
                }
        } else {
            canvas
        }
    }
}

private struct SparkLineCanvas: View, Animatable {
    var values: AnimatableVector
    let color: Color
    let hovered: (x: Double, y: Double)?

    nonisolated var animatableData: AnimatableVector {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = values.values.count
            guard n > 1 else { return }
            let inset: CGFloat = 4
            let h = size.height - inset * 2
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: inset + h * (1 - CGFloat(min(1.05, max(0, values[i])))))
            }
            var line = Path()
            for i in 0..<n {
                if i == 0 { line.move(to: point(i)) } else { line.addLine(to: point(i)) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.26), color.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: inset), endPoint: CGPoint(x: 0, y: size.height)))
            var lifted = ctx
            lifted.addFilter(.shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1.5))
            lifted.stroke(line, with: .color(color.lit), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if let hovered {
                let p = CGPoint(x: size.width * CGFloat(hovered.x), y: inset + h * (1 - CGFloat(min(1.05, max(0, hovered.y)))))
                ctx.fill(Path(CGRect(x: p.x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.3)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Palette.ground.opacity(0.9)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
            } else {
                let p = point(n - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color.lit))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)), with: .color(.white))
            }
        }
    }
}

// MARK: - Horizontal bars

/// A share of a whole (or of the biggest row) as a raised bar in a groove
struct DepthBar: View {
    let fraction: Double
    /// The bar's hue; nil draws it in the neutral ink
    var tint: Color?
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Depth.groove)
                .overlay(Capsule().strokeBorder(Depth.grooveEdge, lineWidth: 0.5))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.map { AnyShapeStyle($0.fillAcross) } ?? AnyShapeStyle(LinearGradient(colors: [Palette.mono(0.45), Palette.mono(0.7)], startPoint: .leading, endPoint: .trailing)))
                        .overlay(Capsule().fill(Depth.gloss))
                        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
        }
        .frame(height: height)
        .animation(Motion.data, value: fraction)
    }
}

/// A limit window as a bar in a groove: how much is used, a tick where even use would be by now, and a
/// faint extension to where the window is heading at the current pace.
struct PaceBar: View {
    /// Used share, 0…1
    let fraction: Double
    /// Elapsed share of the window, 0…1 (the tick); nil draws none
    var pace: Double?
    /// Where the window is heading by its reset, 0…1; nil draws none
    var projected: Double?
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(Depth.groove)
                .overlay(Capsule().strokeBorder(Depth.grooveEdge, lineWidth: 0.5))
                .overlay(alignment: .leading) {
                    if let projected, projected > fraction {
                        Capsule().fill(tint.opacity(0.22))
                            .frame(width: max(height, w * min(1, projected)))
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.fillAcross)
                        .overlay(Capsule().fill(Depth.gloss))
                        .frame(width: fraction > 0 ? max(height, w * min(1, fraction)) : 0)
                }
                .overlay(alignment: .leading) {
                    if let pace {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.75))
                            .frame(width: 2, height: height + 6)
                            .offset(x: max(0, min(w - 2, w * min(1, pace) - 1)))
                    }
                }
        }
        .frame(height: height)
        .animation(Motion.data, value: fraction)
        .animation(Motion.data, value: projected ?? 0)
    }
}

/// Proportional segments with gaps (share at a glance). Hovering a segment names it.
struct SegmentBar: View {
    let parts: [(key: String, value: Double, color: Color)]
    var height: CGFloat = 8
    var tipID = "segments"
    /// The part in focus: the others turn grey
    var focus: String?
    var tip: ((String) -> AnyView)?
    @State private var hovered: String?
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    var body: some View {
        let total = max(1e-9, parts.reduce(0) { $0 + $1.value })
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(parts, id: \.key) { p in
                    RoundedRectangle(cornerRadius: height / 2.6, style: .continuous).fill((focus == nil || focus == p.key ? p.color : Palette.muted).fill)
                        .overlay(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous).fill(Depth.gloss))
                        .frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1) * 2) * p.value / total))
                        .opacity(hovered == nil || hovered == p.key ? 1 : 0.45)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .contentShape(Rectangle().inset(by: -5))
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard let tip, case .active(let point) = phase, hoverTip?.scrolling != true else {
                    hovered = nil
                    hoverTip?.hide(tipID)
                    return
                }
                // The segment under the pointer, by running width
                var x: CGFloat = 0
                var hit = parts.last?.key
                for p in parts {
                    let w = max(2, (geo.size.width - CGFloat(parts.count - 1) * 2) * p.value / total) + 2
                    if point.x < x + w { hit = p.key; break }
                    x += w
                }
                guard let hit else { return }
                hovered = hit
                let origin = geo.frame(in: .named(HoverTip.space)).origin
                hoverTip?.show(tipID, key: hit, at: CGPoint(x: origin.x + point.x, y: origin.y), glide: false) { tip(hit) }
            }
        }
        .frame(height: height)
        .animation(Motion.hover, value: hovered)
        .animation(Motion.data, value: parts.map(\.value))
    }
}

/// How much of the whole a number is: a filled groove
struct ShareBar: View {
    let fraction: Double
    var color: Color = Palette.usage

    var body: some View {
        DepthBar(fraction: fraction, tint: color, height: 6)
            // Easier to point at than six points of height
            .contentShape(Rectangle().inset(by: -7))
    }
}

// MARK: - Area

/// One line adding up over the range, with the area under it, against a dashed comparison line.
/// Both lines are resampled to a fixed number of points, so any range morphs into any other.
/// Optional: faint columns under the line (the day's own value) and a dashed projection to the range's end.
struct AreaChart: View {
    /// The range's points: x is 0…1 across the range, y adding up
    let points: [(x: Double, y: Double)]
    let comparison: [(x: Double, y: Double)]
    let top: Double
    var axes = true
    var format: (Double) -> String = ChartAxis.tokens
    /// Labels under the plot at 0, the middle and the end
    var xLabels: [String] = []
    /// Index into `points` of the highlighted point
    var selected: Int?
    var line: [Color] = [Palette.usage.lit, Accent.indigo.color.lit]
    var area: [Color] = [Palette.usage, Accent.indigo.color]
    /// Per point: the value of that step alone, drawn as faint columns behind the area (scaled to a third of the height)
    var bars: [Double]?
    /// Where the line is heading: dashed from the last point to this one
    var projection: (x: Double, y: Double)?
    /// A dashed horizontal line (a total to compare with) with its label
    var rule: (value: Double, label: String)?
    /// The hovered point's index and where it is on the dashboard; nil when the pointer leaves
    var onHover: ((Int?, CGPoint) -> Void)?

    static let samples = 160
    private var entrance = Entrance()
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    init(points: [(x: Double, y: Double)], comparison: [(x: Double, y: Double)], top: Double, axes: Bool = true,
         format: @escaping (Double) -> String = ChartAxis.tokens, xLabels: [String] = [], selected: Int? = nil,
         line: [Color]? = nil, area: [Color]? = nil, bars: [Double]? = nil, projection: (x: Double, y: Double)? = nil,
         rule: (value: Double, label: String)? = nil, onHover: ((Int?, CGPoint) -> Void)? = nil) {
        self.points = points
        self.comparison = comparison
        self.top = top
        self.axes = axes
        self.format = format
        self.xLabels = xLabels
        self.selected = selected
        if let line { self.line = line }
        if let area { self.area = area }
        self.bars = bars
        self.projection = projection
        self.rule = rule
        self.onHover = onHover
    }

    /// Line and area in one hue: lit at the start, the hue itself at the end
    static func colors(for accent: Color) -> (line: [Color], area: [Color]) {
        ([accent.lit, accent], [accent, accent])
    }

    var body: some View {
        let top = max(top, 1e-9)
        let extent = points.last?.x ?? 0
        let ticks = axes ? ChartAxis.ticks(upTo: top) : []
        let layout = AreaLayout(axes: axes, gutter: ChartAxis.gutter(for: ticks.map(format)))
        let grow = entrance.amount
        // Both lines start from nothing at the left edge
        AreaCanvas(current: AnimatableVector(Self.sample([(0, 0)] + points, upTo: extent).map { $0 * grow }),
                   previous: AnimatableVector(Self.sample(comparison.isEmpty ? [] : [(0, 0)] + comparison, upTo: 1).map { $0 * grow }),
                   columns: AnimatableVector((bars ?? []).map { max(0, $0) * grow }),
                   extent: extent, previousAlpha: comparison.isEmpty ? 0 : 1, top: top,
                   projection: projection.map { AnimatablePair($0.x, $0.y * grow) } ?? AnimatablePair(extent, 0),
                   ticks: ticks, format: format, xLabels: axes ? xLabels : [], layout: layout,
                   selected: selected.flatMap { $0 < points.count ? points[$0] : nil }, line: line, area: area, rule: rule,
                   showProjection: projection != nil)
            .onAppear { entrance.start() }
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            let plot = layout.plot(in: geo.size)
                            guard case .active(let p) = phase, hoverTip?.scrolling != true, !points.isEmpty,
                                  p.x >= plot.minX - 4, p.x <= plot.maxX + 8 else {
                                onHover?(nil, .zero)
                                return
                            }
                            let x = Double((min(max(p.x, plot.minX), plot.maxX) - plot.minX) / plot.width)
                            let i = points.indices.min { abs(points[$0].x - x) < abs(points[$1].x - x) } ?? 0
                            let origin = geo.frame(in: .named(HoverTip.space)).origin
                            onHover?(i, CGPoint(x: origin.x + plot.minX + plot.width * CGFloat(points[i].x),
                                                y: origin.y + plot.maxY - plot.height * CGFloat(min(1, points[i].y / top))))
                        }
                }
            }
    }

    /// The monotone curve through `points` (Fritsch–Carlson), read at evenly spaced x from 0 to `end`.
    /// A monotone curve never dips below a total that only adds up.
    static func sample(_ points: [(x: Double, y: Double)], upTo end: Double, samples: Int = samples) -> [Double] {
        guard points.count > 1, end > 0 else { return Array(repeating: points.first?.y ?? 0, count: samples) }
        let n = points.count
        var slope = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slope[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
        }
        var tangent = [Double](repeating: 0, count: n)
        tangent[0] = slope[0]
        tangent[n - 1] = slope[n - 2]
        if n > 2 { for i in 1..<(n - 1) { tangent[i] = slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2 } }
        for i in 0..<(n - 1) {
            if slope[i] == 0 {
                tangent[i] = 0
                tangent[i + 1] = 0
            } else {
                let a = tangent[i] / slope[i], b = tangent[i + 1] / slope[i]
                let s = a * a + b * b
                if s > 9 {
                    let t = 3 / s.squareRoot()
                    tangent[i] = t * a * slope[i]
                    tangent[i + 1] = t * b * slope[i]
                }
            }
        }
        var out = [Double](repeating: 0, count: samples)
        var k = 0
        for s in 0..<samples {
            let x = end * Double(s) / Double(samples - 1)
            while k < n - 2, points[k + 1].x < x { k += 1 }
            let h = points[k + 1].x - points[k].x
            guard h > 0 else { out[s] = points[k].y; continue }
            let t = min(1, max(0, (x - points[k].x) / h))
            let t2 = t * t, t3 = t2 * t
            out[s] = (2 * t3 - 3 * t2 + 1) * points[k].y + (t3 - 2 * t2 + t) * h * tangent[k]
                + (-2 * t3 + 3 * t2) * points[k + 1].y + (t3 - t2) * h * tangent[k + 1]
        }
        return out
    }
}

struct AreaLayout {
    var axes: Bool
    var gutter: CGFloat = ChartAxis.gutter

    func plot(in size: CGSize) -> CGRect {
        let trailing: CGFloat = axes ? gutter : 8
        let bottom: CGFloat = axes ? ChartAxis.labelHeight : 2
        return CGRect(x: 0, y: 8, width: max(1, size.width - trailing), height: max(1, size.height - 8 - bottom))
    }
}

private struct AreaCanvas: View, Animatable {
    var current: AnimatableVector
    var previous: AnimatableVector
    var columns: AnimatableVector
    var extent: Double
    var previousAlpha: Double
    var top: Double
    var projection: AnimatablePair<Double, Double>

    let ticks: [Double]
    let format: (Double) -> String
    let xLabels: [String]
    let layout: AreaLayout
    let selected: (x: Double, y: Double)?
    let line: [Color]
    let area: [Color]
    let rule: (value: Double, label: String)?
    let showProjection: Bool

    nonisolated var animatableData: AnimatablePair<AnimatablePair<AnimatableVector, AnimatablePair<AnimatableVector, AnimatableVector>>, AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, AnimatablePair<Double, Double>>>> {
        get { AnimatablePair(AnimatablePair(current, AnimatablePair(previous, columns)), AnimatablePair(AnimatablePair(extent, previousAlpha), AnimatablePair(top, projection))) }
        set {
            current = newValue.first.first
            previous = newValue.first.second.first
            columns = newValue.first.second.second
            extent = newValue.second.first.first
            previousAlpha = newValue.second.first.second
            top = newValue.second.second.first
            projection = newValue.second.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let plot = layout.plot(in: size)
            let top = max(top, 1e-9)
            func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(min(1.05, max(0, value) / top)) }
            func path(_ values: AnimatableVector, extent: Double) -> Path {
                var p = Path()
                let n = values.values.count
                guard n > 1 else { return p }
                for i in 0..<n {
                    let point = CGPoint(x: plot.minX + plot.width * CGFloat(extent) * CGFloat(i) / CGFloat(n - 1), y: y(values[i]))
                    if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
                return p
            }

            for tick in ticks {
                let ty = y(tick)
                guard ty >= plot.minY - 2 else { continue }
                ctx.fill(Path(CGRect(x: plot.minX, y: ty - 0.5, width: plot.width, height: 1)), with: .color(Palette.hairline))
                ctx.text(Text(format(tick)).font(.num(Typo.axis, .medium)).foregroundStyle(Ink.tertiary),
                         at: CGPoint(x: plot.maxX + 6, y: ty), anchor: .leading)
            }
            for (i, label) in xLabels.enumerated() where xLabels.count > 1 {
                let fraction = CGFloat(i) / CGFloat(xLabels.count - 1)
                ctx.label(Text(label).font(.app(Typo.axis)).foregroundStyle(Ink.tertiary),
                          at: CGPoint(x: plot.minX + plot.width * fraction, y: plot.maxY + 4), anchor: .top, within: 0...plot.maxX)
            }

            // The steps themselves, as faint columns along the floor (a third of the height at most)
            let n = columns.values.count
            if n > 0, extent > 0 {
                let columnTop = columns.values.max() ?? 0
                if columnTop > 0 {
                    let tone = Depth.Tone(area[0])
                    let slot = plot.width * CGFloat(extent) / CGFloat(n)
                    let w = min(6, max(1.5, slot * 0.5))
                    for i in 0..<n {
                        let h = plot.height * 0.3 * CGFloat(columns[i] / columnTop)
                        guard h > 0.5 else { continue }
                        let x = plot.minX + slot * (CGFloat(i) + 0.5)
                        ctx.column(CGRect(x: x - w / 2, y: plot.maxY - h, width: w, height: h), tone: tone, radius: min(2, w / 2), opacity: 0.38)
                    }
                }
            }

            if let rule, rule.value > 0 {
                let ry = y(rule.value)
                var l = Path()
                l.move(to: CGPoint(x: plot.minX, y: ry))
                l.addLine(to: CGPoint(x: plot.maxX, y: ry))
                ctx.stroke(l, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.text(Text(rule.label).font(.app(Typo.axis)).foregroundStyle(Ink.tertiary), at: CGPoint(x: plot.maxX - 2, y: ry - 3), anchor: .bottomTrailing)
            }

            if previousAlpha > 0.01 {
                ctx.stroke(path(previous, extent: 1), with: .color(.white.opacity(0.34 * previousAlpha)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [4, 4]))
            }

            let curve = path(current, extent: extent)
            guard !curve.isEmpty, extent > 0 else { return }
            let endX = plot.minX + plot.width * CGFloat(extent)
            let endY = y(current.values.last ?? 0)
            var fill = curve
            fill.addLine(to: CGPoint(x: endX, y: plot.maxY))
            fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            fill.closeSubpath()
            // The area is lit along the line and fades into the card
            ctx.fill(fill, with: .linearGradient(Gradient(stops: [
                .init(color: area[0].opacity(0.30), location: 0),
                .init(color: (area.last ?? area[0]).opacity(0.10), location: 0.6),
                .init(color: area[0].opacity(0), location: 1),
            ]), startPoint: CGPoint(x: plot.midX, y: min(endY, plot.maxY - 1)), endPoint: CGPoint(x: plot.midX, y: plot.maxY)))

            // Where the line is heading: dashed on to the range's end
            if showProjection, projection.first > extent + 0.001 {
                var dash = Path()
                dash.move(to: CGPoint(x: endX, y: endY))
                dash.addLine(to: CGPoint(x: plot.minX + plot.width * CGFloat(projection.first), y: y(projection.second)))
                ctx.stroke(dash, with: .color((line.last ?? .white).opacity(0.6)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
                let px = plot.minX + plot.width * CGFloat(projection.first), py = y(projection.second)
                ctx.fill(Path(ellipseIn: CGRect(x: px - 3, y: py - 3, width: 6, height: 6)), with: .color((line.last ?? .white).opacity(0.7)))
            }

            // The line casts a soft shadow on the card
            var lifted = ctx
            lifted.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2))
            lifted.stroke(curve, with: .linearGradient(Gradient(colors: line), startPoint: CGPoint(x: plot.minX, y: 0), endPoint: CGPoint(x: max(endX, plot.minX + 1), y: 0)),
                          style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))

            if let selected {
                let sx = plot.minX + plot.width * CGFloat(selected.x), sy = y(selected.y)
                ctx.fill(Path(CGRect(x: sx - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(.white.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: sx - 6, y: sy - 6, width: 12, height: 12)), with: .color(Palette.ground.opacity(0.9)))
                ctx.fill(Path(ellipseIn: CGRect(x: sx - 4, y: sy - 4, width: 8, height: 8)), with: .color(.white))
            } else {
                // The newest point: white on a ring of the line's colour
                var dot = ctx
                dot.addFilter(.shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1))
                dot.fill(Path(ellipseIn: CGRect(x: endX - 6.5, y: endY - 6.5, width: 13, height: 13)), with: .color(line.last ?? .white))
                ctx.fill(Path(ellipseIn: CGRect(x: endX - 3.8, y: endY - 3.8, width: 7.6, height: 7.6)), with: .color(.white))
            }
        }
    }
}

// MARK: - Donut

/// Donut chart: one sector per slot, in a fixed order, so the same series keeps its place and its colour
/// and the ring morphs when the numbers change. Hovering lifts a sector and dims the others.
struct DonutChart<Center: View>: View {
    /// Every slot, zeros included
    let slots: [(key: String, value: Double, color: Color)]
    var inner: CGFloat = 0.62
    var hovered: String?
    /// The slot in focus: the other sectors turn grey
    var focus: String?
    var onHover: ((String?, CGPoint?) -> Void)?
    var onTap: ((String) -> Void)?
    @ViewBuilder var center: Center
    private var entrance = Entrance()
    @Environment(HoverTip.self) private var hoverTip: HoverTip?

    init(slots: [(key: String, value: Double, color: Color)], inner: CGFloat = 0.62, hovered: String? = nil, focus: String? = nil,
         onHover: ((String?, CGPoint?) -> Void)? = nil, onTap: ((String) -> Void)? = nil, @ViewBuilder center: () -> Center) {
        self.slots = slots
        self.inner = inner
        self.hovered = hovered
        self.focus = focus
        self.onHover = onHover
        self.onTap = onTap
        self.center = center()
    }

    /// The sector under a point
    private func slot(at p: CGPoint, in size: CGSize, total: Double) -> String? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy), outer = min(size.width, size.height) / 2
        guard r > outer * (inner - 0.06), r < outer * 1.02 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        var acc = 0.0
        let target = angle / (2 * .pi) * total
        return slots.first { acc += max(0, $0.value); return $0.value > 0 && target <= acc }?.key
    }

    var body: some View {
        let total = max(1e-9, slots.reduce(0) { $0 + max(0, $1.value) })
        ZStack {
            DonutCanvas(reveal: entrance.amount, values: AnimatableVector(slots.map { max(0, $0.value) }),
                        lift: AnimatableVector(slots.map { $0.key == hovered ? 1 : 0 }),
                        emphasis: AnimatableVector(slots.map { hovered == nil || $0.key == hovered ? 1 : 0.4 }),
                        colour: AnimatableVector(slots.map { focus == nil || $0.key == focus ? 1 : 0 }),
                        tones: slots.map { Depth.Tone($0.color) }, inner: inner)
                .animation(Motion.hover, value: hovered)
                .animation(Motion.data, value: focus)
                .onAppear { entrance.start(.smooth(duration: 0.8)) }
            center
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Circle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard case .active(let p) = phase, hoverTip?.scrolling != true, let hit = slot(at: p, in: geo.size, total: total) else {
                            onHover?(nil, nil)
                            return
                        }
                        let origin = geo.frame(in: .named(HoverTip.space)).origin
                        onHover?(hit, CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                    }
                    .onTapGesture { location in
                        if let hit = slot(at: location, in: geo.size, total: total) { onTap?(hit) }
                    }
            }
        }
    }
}

private struct DonutCanvas: View, Animatable {
    /// How much of the ring is drawn (it unrolls clockwise when it appears)
    var reveal: Double
    var values: AnimatableVector
    var lift: AnimatableVector
    var emphasis: AnimatableVector
    /// Per sector: 1 wears its hue, 0 is muted
    var colour: AnimatableVector
    let tones: [Depth.Tone]
    let inner: CGFloat

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, AnimatableVector>, AnimatablePair<AnimatableVector, AnimatablePair<AnimatableVector, AnimatableVector>>> {
        get { AnimatablePair(AnimatablePair(reveal, values), AnimatablePair(lift, AnimatablePair(emphasis, colour))) }
        set {
            reveal = newValue.first.first
            values = newValue.first.second
            lift = newValue.second.first
            emphasis = newValue.second.second.first
            colour = newValue.second.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let total = values.values.reduce(0) { $0 + max(0, $1) }
            let rIn = side / 2 * inner
            guard total > 1e-9 else {
                var ring = Path()
                ring.addEllipse(in: CGRect(x: c.x - side * 0.47, y: c.y - side * 0.47, width: side * 0.94, height: side * 0.94))
                ring.addEllipse(in: CGRect(x: c.x - rIn, y: c.y - rIn, width: rIn * 2, height: rIn * 2))
                ctx.fill(ring, with: .color(Depth.groove), style: FillStyle(eoFill: true))
                return
            }
            let present = values.values.filter { $0 / total > 0.002 }.count
            let gap = present > 1 ? 1.8 : 0
            var start = -90.0
            for i in 0..<min(values.values.count, tones.count) {
                let sweep = max(0, values[i]) / total * 360 * min(1, max(0, reveal))
                defer { start += sweep }
                guard sweep > 0.25 else { continue }
                let a0 = start + min(gap, sweep * 0.4) / 2, a1 = start + sweep - min(gap, sweep * 0.4) / 2
                let rOut = side / 2 * (0.94 + 0.06 * CGFloat(min(1, max(0, lift[i]))))
                var path = Path()
                path.addArc(center: c, radius: rOut, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                path.addArc(center: c, radius: rIn, startAngle: .degrees(a1), endAngle: .degrees(a0), clockwise: true)
                path.closeSubpath()
                var layer = ctx
                layer.opacity = min(1, max(0, emphasis[i]))
                let hue = min(1, max(0, colour[i]))
                if hue < 0.999 { layer.fill(path, with: .color(Palette.muted)) }
                // Each sector is lit at its start and settles into its hue
                var tinted = layer
                tinted.opacity = layer.opacity * hue
                tinted.fill(path, with: .conicGradient(Gradient(stops: [
                    .init(color: tones[i].light, location: 0),
                    .init(color: tones[i].color, location: min(1, max(0.02, sweep / 360))),
                    .init(color: tones[i].color, location: 1),
                ]), center: c, angle: .degrees(a0)))
                // A hint of roundness: a touch darker towards the hole, a touch brighter along the rim
                layer.fill(path, with: .radialGradient(Gradient(stops: [
                    .init(color: .black.opacity(0.10), location: 0),
                    .init(color: .black.opacity(0), location: 0.42),
                    .init(color: .white.opacity(0), location: 0.7),
                    .init(color: .white.opacity(0.07), location: 1),
                ]), center: c, startRadius: rIn, endRadius: rOut))
            }
        }
    }
}

// MARK: - Rings and dials

/// Concentric rings in grooves: outside in, one fraction per ring
struct ConcentricRings: View {
    let rings: [(fraction: Double, color: Color)]
    var lineWidth: CGFloat = 7
    var spacing: CGFloat = 2.5
    private var entrance = Entrance()

    init(rings: [(fraction: Double, color: Color)], lineWidth: CGFloat = 7, spacing: CGFloat = 2.5) {
        self.rings = rings
        self.lineWidth = lineWidth
        self.spacing = spacing
    }

    var body: some View {
        let grow = entrance.amount
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.offset) { i, ring in
                    let inset = CGFloat(i) * (lineWidth + spacing) + lineWidth / 2
                    let d = max(0, side - inset * 2)
                    Circle().stroke(Depth.groove, lineWidth: lineWidth).frame(width: d, height: d)
                    Circle()
                        .trim(from: 0, to: max(ring.fraction * grow, ring.fraction > 0 ? 0.015 : 0))
                        .stroke(ring.color.fillAcross, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: d, height: d)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.data, value: rings.map(\.fraction))
        .onAppear { entrance.start(.smooth(duration: 0.9)) }
    }
}

/// A limit window as a three-quarter dial: used so far in the window's colour, a small ring where even
/// use would be by now, and a fainter arc to where it is heading by the reset.
struct LimitGauge<Center: View>: View {
    /// Used share, 0…1
    let fraction: Double
    /// Where the window is heading by its reset (0…1); nil draws none
    var projected: Double?
    /// Elapsed share of the window (0…1); nil draws no marker
    var elapsed: Double?
    var accent: Color
    var lineWidth: CGFloat?
    @ViewBuilder var center: Center
    private var entrance = Entrance()

    init(fraction: Double, projected: Double? = nil, elapsed: Double? = nil, accent: Color, lineWidth: CGFloat? = nil, @ViewBuilder center: () -> Center) {
        self.fraction = fraction
        self.projected = projected
        self.elapsed = elapsed
        self.accent = accent
        self.lineWidth = lineWidth
        self.center = center()
    }

    /// The dial covers 270°
    private func trim(_ value: Double) -> CGFloat { 0.75 * CGFloat(min(1, max(0, value))) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = lineWidth ?? max(6, side * 0.11)
            let grow = entrance.amount
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Depth.groove, style: StrokeStyle(lineWidth: line, lineCap: .round))
                if let projected, projected > fraction {
                    Circle().trim(from: 0, to: trim(projected * grow))
                        .stroke(accent.opacity(0.28), style: StrokeStyle(lineWidth: line, lineCap: .round))
                }
                Circle().trim(from: 0, to: max(fraction > 0 ? 0.004 : 0, trim(fraction * grow)))
                    .stroke(AngularGradient(colors: [accent.lit, accent, accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                if let elapsed {
                    Circle().strokeBorder(Color.white, lineWidth: 1.6).background(Circle().fill(Palette.ground.opacity(0.75)))
                        .frame(width: line * 0.62, height: line * 0.62)
                        .offset(y: -(side - line) / 2)
                        .rotationEffect(.degrees(270 * min(1, elapsed) - 270))
                }
            }
            .padding(line / 2)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(135))
            .overlay { center.offset(y: side * 0.04) }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.data, value: fraction)
        .animation(Motion.data, value: projected ?? 0)
        .onAppear { entrance.start(.smooth(duration: 0.9)) }
    }
}

// MARK: - Sankey

/// A flow diagram's nodes and links, before any geometry
struct Sankey {
    struct Node {
        let id: String
        let column: Int
        let name: String
        var value: Double
        let color: Color
        /// A logo drawn beside the name (brand logo name); nil for none
        var logo: String?
    }

    struct Link {
        let from: Int
        let to: Int
        let value: Double
    }

    var nodes: [Node] = []
    var links: [Link] = []
    var columns = 2

    /// Changes when the picture is a different one (not when only amounts move a little)
    var signature: String { nodes.map(\.id).joined(separator: ",") }
}

/// Where the nodes and ribbons are for a given size
struct SankeyLayout {
    static let bar: CGFloat = 9
    /// Every node keeps room for one line of text
    static let pitch: CGFloat = 15
    static let gap: CGFloat = 4

    var nodes: [CGRect] = []
    /// Per link: top edge at the source, top edge at the target, thickness
    var links: [(y0: CGFloat, y1: CGFloat, thickness: CGFloat)] = []
    var scale: CGFloat = 0

    init(_ s: Sankey, in size: CGSize, labelWidth: CGFloat) {
        let columns = (0..<s.columns).map { c in s.nodes.indices.filter { s.nodes[$0].column == c } }
        func height(_ column: [Int], _ scale: CGFloat) -> CGFloat {
            column.reduce(0) { $0 + max(max(2, CGFloat(s.nodes[$1].value) * scale) + Self.gap, Self.pitch) } - Self.gap
        }
        // The largest scale at which the tallest column still fits
        let total = columns.map { $0.reduce(0.0) { $0 + s.nodes[$1].value } }.max() ?? 1
        var low: CGFloat = 0, high = size.height / CGFloat(max(1, total))
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if columns.allSatisfy({ height($0, mid) <= size.height }) { low = mid } else { high = mid }
        }
        scale = low
        nodes = Array(repeating: .zero, count: s.nodes.count)
        let plotWidth = max(Self.bar, size.width - labelWidth)
        for (c, column) in columns.enumerated() {
            let x = s.columns > 1 ? (plotWidth - Self.bar) * CGFloat(c) / CGFloat(s.columns - 1) : 0
            var y = max(0, (size.height - height(column, scale)) / 2)
            for i in column {
                let h = max(2, CGFloat(s.nodes[i].value) * scale)
                let slot = max(h + Self.gap, Self.pitch)
                nodes[i] = CGRect(x: x, y: y + (slot - Self.gap - h) / 2, width: Self.bar, height: h)
                y += slot
            }
        }
        // Ribbons leave and arrive stacked in the order of the node at the other end
        var out = [CGFloat](repeating: 0, count: s.nodes.count), into = [CGFloat](repeating: 0, count: s.nodes.count)
        links = s.links.map { link in
            let thickness = max(0.8, CGFloat(link.value) * scale)
            defer {
                out[link.from] += thickness
                into[link.to] += thickness
            }
            return (nodes[link.from].minY + out[link.from], nodes[link.to].minY + into[link.to], thickness)
        }
    }

    func ribbon(_ i: Int, _ s: Sankey) -> Path {
        let link = s.links[i], g = links[i]
        let x0 = nodes[link.from].maxX + 1, x1 = nodes[link.to].minX - 1
        let mid = (x0 + x1) / 2
        var p = Path()
        p.move(to: CGPoint(x: x0, y: g.y0))
        p.addCurve(to: CGPoint(x: x1, y: g.y1), control1: CGPoint(x: mid, y: g.y0), control2: CGPoint(x: mid, y: g.y1))
        p.addLine(to: CGPoint(x: x1, y: g.y1 + g.thickness))
        p.addCurve(to: CGPoint(x: x0, y: g.y0 + g.thickness), control1: CGPoint(x: mid, y: g.y1 + g.thickness), control2: CGPoint(x: mid, y: g.y0 + g.thickness))
        p.closeSubpath()
        return p
    }
}

/// One flow diagram: draws itself in when it appears, highlights what the pointer is on
struct SankeyPlot: View {
    enum Hit: Equatable {
        case node(Int)
        case link(Int)
    }

    let diagram: Sankey
    /// Amount formatter for the labels beside the bars
    var format: (Double) -> String = ChartAxis.tokens
    var tipID = "flow"
    var labelWidth: CGFloat = 120
    var nodeTip: ((Int) -> AnyView)?
    var linkTip: ((Int) -> AnyView)?
    @Environment(HoverTip.self) private var tip: HoverTip?
    @Environment(\.chartEntrance) private var entrance
    @State private var hovered: Hit?
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            let layout = SankeyLayout(diagram, in: geo.size, labelWidth: labelWidth)
            SankeyCanvas(progress: shown || !entrance ? 1 : 0, focus: hovered == nil ? 0 : 1, diagram: diagram, layout: layout, hovered: hovered, format: format)
                .animation(Motion.hover, value: hovered == nil)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, tip?.scrolling != true, let hit = hit(p, layout) else {
                        hovered = nil
                        tip?.hide(tipID)
                        return
                    }
                    hovered = hit
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    switch hit {
                    case .node(let i):
                        let rect = layout.nodes[i]
                        if let nodeTip { tip?.show(tipID, key: "n\(i)", at: CGPoint(x: origin.x + rect.midX, y: origin.y + rect.minY), glide: true) { nodeTip(i) } }
                    case .link(let i):
                        if let linkTip { tip?.show(tipID, key: "l\(i)", at: CGPoint(x: origin.x + p.x, y: origin.y + p.y)) { linkTip(i) } }
                    }
                }
        }
        .onAppear { withAnimation(Motion.reduced ? nil : .smooth(duration: 1.0).delay(0.1)) { shown = true } }
    }

    /// A node (its bar and its label), else the ribbon under the pointer
    private func hit(_ p: CGPoint, _ layout: SankeyLayout) -> Hit? {
        for (i, rect) in layout.nodes.enumerated() {
            let last = diagram.nodes[i].column == diagram.columns - 1
            let area = CGRect(x: rect.minX - 3, y: rect.midY - max(rect.height, SankeyLayout.pitch) / 2, width: last ? labelWidth + 12 : 16, height: max(rect.height, SankeyLayout.pitch))
            if area.contains(p) { return .node(i) }
        }
        // Thin ribbons are checked first: they lie on top of the wide ones where they cross
        let order = diagram.links.indices.sorted { layout.links[$0].thickness < layout.links[$1].thickness }
        for i in order where layout.ribbon(i, diagram).contains(p) || (layout.links[i].thickness < 4 && layout.ribbon(i, diagram).strokedPath(StrokeStyle(lineWidth: 5)).contains(p)) {
            return .link(i)
        }
        return nil
    }
}

private struct SankeyCanvas: View, Animatable {
    /// 0…1: the ribbons run in from the left
    var progress: Double
    /// 0…1: how far everything that is not hovered has stepped back
    var focus: Double
    let diagram: Sankey
    let layout: SankeyLayout
    let hovered: SankeyPlot.Hit?
    let format: (Double) -> String

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, focus) }
        set {
            progress = newValue.first
            focus = newValue.second
        }
    }

    private func lit(_ i: Int) -> Bool {
        switch hovered {
        case .none: true
        case .link(let j): i == j
        case .node(let n): diagram.links[i].from == n || diagram.links[i].to == n
        }
    }

    private func lit(node n: Int) -> Bool {
        switch hovered {
        case .none: true
        case .node(let m): m == n || diagram.links.contains { ($0.from == m && $0.to == n) || ($0.to == m && $0.from == n) }
        case .link(let j): diagram.links[j].from == n || diagram.links[j].to == n
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let plotRight = layout.nodes.map(\.maxX).max() ?? size.width
            // The ribbons are revealed left to right; nodes fade in as the front passes them
            var ribbons = ctx
            ribbons.clip(to: Path(CGRect(x: 0, y: -4, width: plotRight * CGFloat(progress) + 1, height: size.height + 8)))
            for i in diagram.links.indices {
                let link = diagram.links[i]
                let from = diagram.nodes[link.from], to = diagram.nodes[link.to]
                let path = layout.ribbon(i, diagram)
                let strength = lit(i) ? 0.46 + 0.22 * focus : 0.46 - 0.36 * focus
                let x0 = layout.nodes[link.from].maxX, x1 = layout.nodes[link.to].minX
                ribbons.fill(path, with: .linearGradient(Gradient(colors: [from.color.opacity(strength), to.color.opacity(strength)]),
                                                         startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                // A faint upper edge keeps stacked ribbons apart
                if layout.links[i].thickness > 3 {
                    var edge = Path()
                    let g = layout.links[i], mid = (x0 + x1) / 2
                    edge.move(to: CGPoint(x: x0 + 1, y: g.y0 + 0.5))
                    edge.addCurve(to: CGPoint(x: x1 - 1, y: g.y1 + 0.5), control1: CGPoint(x: mid, y: g.y0 + 0.5), control2: CGPoint(x: mid, y: g.y1 + 0.5))
                    ribbons.stroke(edge, with: .color(.white.opacity(0.07 * strength / 0.46)), lineWidth: 1)
                }
            }

            for (i, node) in diagram.nodes.enumerated() {
                let rect = layout.nodes[i]
                let arrived = min(1, max(0, (progress * Double(plotRight) - Double(rect.minX) + 30) / 40))
                guard arrived > 0.01 else { continue }
                let strength = (lit(node: i) ? 1 : 1 - 0.55 * focus) * arrived
                ctx.column(rect, tone: Depth.Tone(node.color), radius: 3, opacity: strength)

                // Name and amount beside the bar
                var text = ctx
                text.opacity = strength
                let isHovered = hovered == .node(i)
                let name = text.resolve(Text(node.name).font(.app(Typo.small, isHovered ? .semibold : .medium)).foregroundStyle(Ink.primary))
                let amount = text.resolve(Text(format(node.value)).font(.num(Typo.small, .medium)).foregroundStyle(Ink.secondary))
                let at = CGPoint(x: rect.maxX + 6, y: rect.midY)
                if node.column < diagram.columns - 1 {
                    // Over the ribbons: a soft shadow keeps the text readable
                    text.addFilter(.shadow(color: .black.opacity(0.75), radius: 2.5, x: 0, y: 0.5))
                }
                text.text(name, at: at, anchor: .leading)
                text.text(amount, at: CGPoint(x: at.x + name.measure(in: size).width + 5, y: at.y), anchor: .leading)
            }
        }
    }
}
