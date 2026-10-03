import SwiftUI
import AppKit

// MARK: - Colours
//
// Only three categorical colours; every pair stays distinguishable under colour-blind simulation
// (dataviz validator --pairs all). Everything else is grey "Other". Single-series charts (hero,
// calendar, time of day, stat tiles, cost) use black, white and grey only.
// No yellow family; Claude keeps its terracotta.

public enum Palette {
    public static let claude = Color(red: 0xC1 / 255, green: 0x77 / 255, blue: 0x55 / 255)   // #c17755
    public static let indigo = Color(red: 0x50 / 255, green: 0x5B / 255, blue: 0xA7 / 255)   // #505ba7
    public static let teal = Color(red: 0x20 / 255, green: 0x99 / 255, blue: 0x93 / 255)     // #209993
    public static let other = Color(white: 0.29)                                             // "Other"

    /// Model colour slots (assigned in order; stacks follow the same order)
    public static let slots: [Color] = [claude, indigo, teal]

    /// Monochrome ramp from light to dark (composition, calendar, etc.)
    public static func mono(_ opacity: Double) -> Color { Color(white: 0.95).opacity(opacity) }

    // Purpose accents for single-series charts (one per chart, never compared with each other):
    // usage = sky blue, activity = green, cost = rose. Separate from the model / tool colours.
    public static let usage = Color(red: 0x6F / 255, green: 0x9F / 255, blue: 0xD8 / 255)      // #6f9fd8
    public static let activity = Color(red: 0x5F / 255, green: 0xB0 / 255, blue: 0x7F / 255)   // #5fb07f
    public static let rose = Color(red: 0xC4 / 255, green: 0x7F / 255, blue: 0x9F / 255)       // #c47f9f
    public static let cost = usage

    /// Token composition colours: cache = two blues, fresh = two warms (dataviz validator --pairs all: CVD ΔE ≥ 16)
    public static let composition: [Color] = [
        Color(hex: "#5497d9"),   // cache read
        Color(hex: "#3862a7"),   // cache write
        Color(hex: "#d07758"),   // input
        Color(hex: "#9c4438"),   // output
    ]

    public static let up = Color(red: 0.50, green: 0.69, blue: 0.54)      // status: increase (with an arrow)
    public static let down = Color(red: 0.79, green: 0.54, blue: 0.48)    // status: decrease (with an arrow)

    /// What a mark turns into when it steps back behind a focused one
    public static let muted = Color(white: 0.36)

    // Status colours: reserved for state, always shown with an icon and a label
    public static let good = Color(hex: "#72cf8e")
    public static let warning = Color(hex: "#e8b45e")
    public static let critical = Color(hex: "#ea6a66")

    public static let ground = Color(red: 0.051, green: 0.051, blue: 0.059)   // #0d0d0f
    public static let track = Color.white.opacity(0.08)
    public static let hairline = Color.white.opacity(0.07)
}

// MARK: - Colour utilities

public extension Color {
    /// "#rrggbb" → Color (grey if parsing fails)
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        let v = UInt32(h, radix: 16) ?? 0x808080
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Color → "#rrggbb" (sRGB)
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Lighter / darker variants of the same hue: step 0 = base, 1 = light, 2 = dark, 3 = lighter, 4 = darker
    func shade(_ step: Int) -> Color {
        guard step > 0, let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let table: [(CGFloat, CGFloat)] = [(0, 0), (-0.14, 0.17), (0.02, -0.2), (-0.26, 0.28), (0.05, -0.32)]
        let (ds, db) = table[min(step, table.count - 1)]
        return Color(hue: h, saturation: min(1, max(0.08, s + ds)), brightness: min(1, max(0.25, b + db)))
    }
}

/// Card accent presets (for single-series charts; no yellow family)
public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, teal, green, rose, claude, white
    public var id: String { rawValue }

    public var hex: String {
        switch self {
        case .blue: "#6f9fd8"
        case .indigo: "#8a8fe0"
        case .teal: "#3fb0a6"
        case .green: "#5fb07f"
        case .rose: "#c47f9f"
        case .claude: "#c17755"
        case .white: "#e4e4e7"
        }
    }

    public var color: Color { Color(hex: hex) }

    public var localizedName: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .teal: String(localized: "Teal")
        case .green: String(localized: "Green")
        case .rose: String(localized: "Rose")
        case .claude: String(localized: "Terracotta")
        case .white: String(localized: "White")
        }
    }

    /// Stored value (preset name or "#rrggbb") → colour
    public static func resolve(_ stored: String?, fallback: Accent) -> Color {
        guard let stored, !stored.isEmpty else { return fallback.color }
        if let preset = Accent(rawValue: stored) { return preset.color }
        return stored.hasPrefix("#") ? Color(hex: stored) : fallback.color
    }
}

// MARK: - Background: opaque near-black with a soft white light (the desktop never shows through at the top)

public struct AmbientBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            Palette.ground
            RadialGradient(colors: [.white.opacity(0.085), .clear],
                           center: UnitPoint(x: 0.1, y: -0.08), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [.white.opacity(0.035), .clear],
                           center: UnitPoint(x: 0.75, y: 1.08), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Type scale (tune sizes here; views do not hard-code their own)

public enum Typo {
    public static let hero: CGFloat = 38        // hero number
    public static let heroUnit: CGFloat = 14
    public static let value: CGFloat = 17       // stat tile value
    public static let title: CGFloat = 12       // card title
    public static let body: CGFloat = 11        // inline body text
    public static let small: CGFloat = 10       // captions, legends
    public static let axis: CGFloat = 9.5       // axis ticks
}

public extension Font {
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Numbers: the rounded face, set against the plain face of labels
    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

public extension Color {
    /// A clearly lighter step of the same hue: icons and lines that must stand out on a chip or a card
    var lighter: Color { shade(1) }

    /// A slightly lighter step of the same hue: the lit end of a fill. Fills are nearly flat.
    var lit: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: max(0.05, s - 0.035), brightness: min(1, b + 0.055))
    }

    /// Top-to-bottom fill for a bar or area in this hue: a touch lighter at the top
    var fill: LinearGradient {
        LinearGradient(colors: [lit, self], startPoint: .top, endPoint: .bottom)
    }

    /// Left-to-right fill for a horizontal bar
    var fillAcross: LinearGradient {
        LinearGradient(colors: [self, lit], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Glass card (native Liquid Glass; optionally with a faint purpose tint)

public struct GlassCard: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var tint: Color?

    /// Layout audits set SIMPLETOKEN_LAYOUT_DEBUG=1 to see overflowing content instead of clipping it
    private static let showOverflow = ProcessInfo.processInfo.environment["SIMPLETOKEN_LAYOUT_DEBUG"] == "1"

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            // minWidth / minHeight 0: the card always takes exactly the size it is given, never its content's
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            // Widgets have a fixed height: never let content spill onto the next widget
            .clipShape(RoundedRectangle(cornerRadius: Self.showOverflow ? 0 : radius, style: .continuous).inset(by: Self.showOverflow ? -2000 : 0))
            .glassEffect(tint.map { .regular.tint($0.opacity(0.10)) } ?? .regular, in: .rect(cornerRadius: radius))
    }
}

public extension View {
    func glassCard(padding: CGFloat = 16, radius: CGFloat = 18, tint: Color? = nil) -> some View {
        modifier(GlassCard(padding: padding, radius: radius, tint: tint))
    }

    /// Card title
    func cardTitle() -> some View {
        font(.app(Typo.title, .semibold)).foregroundStyle(.primary)
    }
}

/// Card header: title + trailing note + settings button (flips the card to show its options on the back)
public struct CardHeader<Trailing: View>: View {
    let title: String
    let onSettings: (() -> Void)?
    let trailing: Trailing

    public init(_ title: String, onSettings: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.onSettings = onSettings
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).cardTitle().lineLimit(1).fixedSize().layoutPriority(2)
            Spacer(minLength: 6)
            // Trailing note: shrinks, then truncates when it does not fit; never pushes the title out
            trailing
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
            if let onSettings {
                CardSettingsButton(help: String(localized: "\(title) settings"), action: onSettings)
            }
        }
    }
}

public extension CardHeader where Trailing == EmptyView {
    init(_ title: String, onSettings: (() -> Void)? = nil) {
        self.init(title, onSettings: onSettings) { EmptyView() }
    }
}

/// Settings button in the card's top-right corner: a faint icon that lifts into a glass circle on hover
public struct CardSettingsButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(help: String, action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.app(Typo.small, .semibold))
                .foregroundStyle(hovering ? .primary : .tertiary)
                .frame(width: 22, height: 22)
                .background {
                    if hovering { Circle().fill(Color.white.opacity(0.08)).glassEffect(.regular.interactive(), in: .circle) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

// MARK: - Glass segmented control: the selection is a flowing glass pill (glassEffectID morph)

public struct GlassSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var fontSize: CGFloat
    @Namespace private var namespace

    public init(_ options: [(Value, String)], selection: Binding<Value>, fontSize: CGFloat = Typo.small) {
        self.options = options
        self._selection = selection
        self.fontSize = fontSize
    }

    public var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { value, label in
                    let selected = value == selection
                    Text(label)
                        .font(.system(size: fontSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, fontSize > 11 ? 10 : 8)
                        .padding(.vertical, fontSize > 11 ? 4 : 3)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.10))
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .glassEffectID("selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = value }
                        }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .fixedSize()
    }
}

// MARK: - Legend swatch

public struct Swatch: View {
    var color: Color
    var size: CGFloat
    public init(_ color: Color, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }
    public var body: some View {
        // Lit from the top like the mark it stands for
        RoundedRectangle(cornerRadius: 2.2, style: .continuous).fill(color.fill).frame(width: size, height: size)
    }
}

// MARK: - Icon chip

/// The small rounded square an icon sits on: a wash of its colour, a little stronger at the top, with a
/// hairline rim. Grey when there is no colour.
public struct ChipBackground: View {
    var color: Color?
    var radius: CGFloat

    public init(_ color: Color?, radius: CGFloat) {
        self.color = color
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if let color {
            shape.fill(LinearGradient(colors: [color.opacity(0.34), color.opacity(0.17)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [color.lighter.opacity(0.35), color.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
        } else {
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
        }
    }
}

// MARK: - Wrapping layout (legends, tag groups: wraps to the next line instead of overflowing the card)

public struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment

    public init(spacing: CGFloat = 10, lineSpacing: CGFloat = 6, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var lines: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((i, size))
            x += size.width + spacing
        }
        return lines
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        let height = rows.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { row in row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width.map { min($0, used) } ?? used, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map(\.1.height).max() ?? 0
            var x = alignment == .trailing ? bounds.maxX - rowWidth : alignment == .center ? bounds.midX - rowWidth / 2 : bounds.minX
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
