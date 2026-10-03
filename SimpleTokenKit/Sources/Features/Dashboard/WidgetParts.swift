import SwiftUI
import Core
import DesignSystem

// Shared widget layout. Every widget has the same structure:
//   a header row (icon in a tinted chip + grey title + trailing note + settings button)
//   the main number right below the header, top-aligned, in rounded numerals
//   the visualisation fills the remaining space; large sizes add a row of facts at the bottom
// Font sizes follow one table per size; padding is uniform. Charts come from ChartKit.

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
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.app(Typo.small, .semibold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(ChipBackground(tint == .secondary ? nil : tint, radius: 6))
            }
            // The title may shrink a little, then truncate, so the settings button always stays inside the card
            Text(title).font(.app(Typo.title, .semibold)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).layoutPriority(2)
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
                .font(.num(size, .semibold))
                .kerning(size > 30 ? -0.8 : -0.4)
                .foregroundStyle(color)
                .contentTransition(value.map { .numericText(value: $0) } ?? .numericText())
            if !parts.1.isEmpty {
                Text(parts.1).font(.num(max(Typo.body, size * 0.42), .medium)).foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
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
            Text(value).font(.num(Typo.title + 1, .semibold)).foregroundStyle(color).monospacedDigit()
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

/// A dollar amount as the main number: a small raised sign, large dollars, small cents
struct MoneyNumber: View {
    let amount: Double
    let size: CGFloat
    var color: Color = .primary

    init(_ amount: Double, size: CGFloat, color: Color = .primary) {
        self.amount = amount
        self.size = size
        self.color = color
    }

    var body: some View {
        let text = Fmt.money(amount)
        // "$1,234.56" → sign, whole, fraction; anything else (other currencies, "—") is drawn as is
        let parts = Self.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if let parts {
                Text(parts.sign).font(.num(size * 0.55, .semibold)).foregroundStyle(.secondary)
                    .baselineOffset(size * 0.32)
                Text(parts.whole).font(.num(size, .semibold)).kerning(size > 30 ? -0.8 : -0.4).foregroundStyle(color)
                    .contentTransition(.numericText(value: amount))
                if !parts.fraction.isEmpty {
                    Text(parts.fraction).font(.num(size * 0.5, .medium)).foregroundStyle(.tertiary)
                }
            } else {
                Text(text).font(.num(size, .semibold)).foregroundStyle(color).contentTransition(.numericText(value: amount))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }

    static func split(_ text: String) -> (sign: String, whole: String, fraction: String)? {
        guard let first = text.first, !first.isNumber else { return nil }
        let rest = text.dropFirst()
        guard let digit = rest.first, digit.isNumber else { return nil }
        // Under a dollar the cents are the number: keep every digit large
        if rest.hasPrefix("0"), rest.count > 1 { return (String(first), String(rest), "") }
        if let dot = rest.lastIndex(where: { $0 == "." || $0 == "," }), rest[rest.index(after: dot)...].allSatisfy(\.isNumber),
           rest.distance(from: rest.index(after: dot), to: rest.endIndex) == 2 {
            return (String(first), String(rest[..<dot]), String(rest[dot...]))
        }
        return (String(first), String(rest), "")
    }
}

/// Change against the previous period, as a small tinted chip ("▲ 12.3%")
struct DeltaChip: View {
    let percent: Double
    /// Whether a rise is good news (usage: neutral; cost: a rise is bad)
    var invert = false

    var body: some View {
        let flat = abs(percent) < 0.5
        let up = percent > 0
        let color: Color = flat ? Palette.mono(0.6) : ((up != invert) ? Palette.up : Palette.down)
        HStack(spacing: 3) {
            Image(systemName: flat ? "minus" : up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: Typo.axis - 1.5, weight: .bold))
            Text(String(format: "%.1f%%", abs(percent))).font(.num(Typo.small, .semibold))
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(ChipBackground(flat ? nil : color, radius: 7))
        .lineLimit(1).fixedSize()
    }
}

/// A fraction as a whole-number percentage ("12%"); under 1% keeps one decimal
func percent(_ fraction: Double) -> String {
    let p = fraction * 100
    if p > 0, p < 1 { return String(format: "%.1f%%", p) }
    return String(format: "%.0f%%", p)
}
