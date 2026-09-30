import SwiftUI
import Core
import DesignSystem

// Shared widget layout. Every widget has the same structure:
//   a header row (accent icon + grey title + trailing note + settings button)
//   the main number right below the header, top-aligned
//   the visualisation fills the remaining space; large sizes add a row of facts at the bottom
// Font sizes follow one table per size; padding is uniform.

enum WidgetStyle {
    static let padding: CGFloat = 14

    /// Font size of the main number
    static func number(_ size: SettingsStore.CardSize) -> CGFloat {
        switch size {
        case .small: 25
        case .medium: 28
        case .large: 32
        case .wide: 36
        }
    }
}

/// Widget header row
struct WidgetHeader<Trailing: View>: View {
    let title: String
    var icon: String?
    var tint: Color = .secondary
    var onSettings: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, icon: String? = nil, tint: Color = .secondary, onSettings: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.onSettings = onSettings
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.app(Typo.small + 1, .semibold)).foregroundStyle(tint)
                    .frame(width: 14)
            }
            Text(title).font(.app(Typo.title, .semibold)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize().layoutPriority(2)
            Spacer(minLength: 6)
            trailing
                .font(.app(Typo.small)).foregroundStyle(.tertiary).monospacedDigit()
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
            if let onSettings {
                CardSettingsButton(help: L("\(title) settings"), action: onSettings)
            }
        }
        .frame(height: 20)
    }
}

extension WidgetHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, tint: Color = .secondary, onSettings: (() -> Void)? = nil) {
        self.init(title, icon: icon, tint: tint, onSettings: onSettings) { EmptyView() }
    }
}

/// Main number: large digits with a small grey unit ("52.14 B" → 52.14 + B)
struct BigNumber: View {
    let text: String
    let size: CGFloat
    var color: Color = .primary
    var value: Double?

    init(_ text: String, size: CGFloat, color: Color = .primary, value: Double? = nil) {
        self.text = text
        self.size = size
        self.color = color
        self.value = value
    }

    var body: some View {
        let parts = Self.split(text)
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(parts.0)
                .font(.app(size, .semibold))
                .kerning(size > 30 ? -0.8 : -0.4)
                .foregroundStyle(color)
                .contentTransition(value.map { .numericText(value: $0) } ?? .numericText())
            if !parts.1.isEmpty {
                Text(parts.1).font(.app(max(Typo.body, size * 0.42), .medium)).foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.55)
    }

    /// Splits number and unit: "52.14 B", "23.4 M", "12.3 K" (and the Chinese 100M / 10K / day units);
    /// text without a space is returned as is
    static func split(_ text: String) -> (String, String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        let unit = String(text[text.index(after: space)...])
        guard unit.count <= 3, !unit.contains(where: \.isNumber) else { return (text, "") }
        return (String(text[..<space]), unit)
    }
}

/// One fact: value on top, small label below
struct Fact: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.app(Typo.title + 1, .semibold)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

/// Bottom facts row: equal-width columns with thin dividers
struct FactsRow: View {
    let facts: [(String, String, Color)]

    init(_ facts: [(String, String)]) {
        self.facts = facts.map { ($0.0, $0.1, Color.primary) }
    }

    init(colored facts: [(String, String, Color)]) {
        self.facts = facts
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                if i > 0 {
                    Rectangle().fill(Palette.hairline).frame(width: 1, height: 26).padding(.horizontal, 12)
                }
                Fact(label: f.0, value: f.1, color: f.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Concentric rings (small limits widget): outside in, one fraction per ring
struct ConcentricRings: View {
    let rings: [(fraction: Double, color: Color)]
    var lineWidth: CGFloat = 7
    var spacing: CGFloat = 2.5
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.offset) { i, ring in
                    let inset = CGFloat(i) * (lineWidth + spacing) + lineWidth / 2
                    let d = max(0, side - inset * 2)
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth).frame(width: d, height: d)
                    Circle()
                        .trim(from: 0, to: appeared ? max(ring.fraction, ring.fraction > 0 ? 0.015 : 0) : 0)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: d, height: d)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { withAnimation(.smooth(duration: 1.0)) { appeared = true } }
        .animation(.smooth(duration: 0.6), value: rings.map(\.fraction))
    }
}

/// Donut chart (models, token composition): sectors + centre content, hover by angle
struct DonutChart<Center: View>: View {
    let parts: [(key: String, value: Double, color: Color)]
    var inner: CGFloat = 0.68
    var hovered: String?
    var onHover: ((String?, CGPoint?) -> Void)?
    @ViewBuilder var center: Center

    var body: some View {
        let total = max(1e-9, parts.reduce(0) { $0 + $1.value })
        ZStack {
            Canvas { ctx, size in
                let side = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var start = -90.0
                let gap = parts.count > 1 ? 1.6 : 0
                for p in parts where p.value > 0 {
                    let sweep = p.value / total * 360
                    let hot = hovered == nil || hovered == p.key
                    let outer = side / 2 * (hovered == p.key ? 1 : 0.94)
                    var path = Path()
                    path.addArc(center: c, radius: outer, startAngle: .degrees(start + gap / 2),
                                endAngle: .degrees(start + max(gap / 2 + 0.5, sweep - gap / 2)), clockwise: false)
                    path.addArc(center: c, radius: side / 2 * inner, startAngle: .degrees(start + max(gap / 2 + 0.5, sweep - gap / 2)),
                                endAngle: .degrees(start + gap / 2), clockwise: true)
                    path.closeSubpath()
                    ctx.fill(path, with: .color(p.color.opacity(hot ? 1 : 0.4)))
                    start += sweep
                }
            }
            center
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Circle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard case .active(let p) = phase else { onHover?(nil, nil); return }
                        let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let dx = p.x - c.x, dy = p.y - c.y
                        let r = hypot(dx, dy), outer = min(geo.size.width, geo.size.height) / 2
                        guard r > outer * (inner - 0.06), r < outer * 1.02 else { onHover?(nil, nil); return }
                        var angle = atan2(dx, -dy)
                        if angle < 0 { angle += 2 * .pi }
                        var acc = 0.0
                        let target = angle / (2 * .pi) * total
                        let hit = parts.first { acc += $0.value; return target <= acc }
                        let origin = geo.frame(in: .named(HoverTip.space)).origin
                        onHover?(hit?.key, CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                    }
            }
        }
    }
}
