import AppKit
import Core
import DesignSystem

/// One segment in the menu bar: a limit / today / this month…
struct MenuBarSegment: Equatable {
    var label: String
    var value: String
    /// Fill fraction for limits (0…1, already converted for the used / left setting); nil for non-limits
    var fraction: Double?
    /// The limit has reached the highest alert threshold
    var alert = false
}

/// What the menu bar shows (shared by the status item and the settings preview)
@MainActor
enum MenuBarContent {
    static func segments(state: AppState, now: Date = Date()) -> [MenuBarSegment] {
        let settings = SettingsStore.shared
        let items = settings.menuBarEntries
        // When limits from both providers are shown, labels include the provider name
        let bothProviders = Set(items.compactMap(\.provider)).count > 1
        let threshold = settings.alertThresholds.max() ?? 80
        return items.map { item in
            var label = item.shortLabel
            if bothProviders, let provider = item.provider {
                label = (provider == "codex" ? "Codex " : "Claude ") + label
            }
            switch item {
            case .claudeSession, .claudeWeekly, .claudeFable, .codexSession, .codexWeekly:
                let snapshot = item.provider == "codex" ? state.limits.codex : state.limits.claude
                let window: LimitWindow? = switch item {
                case .claudeSession, .codexSession: snapshot?.window(.session) ?? snapshot?.primaryWindow
                case .claudeFable: snapshot?.window(.fable)
                default: snapshot?.window(.weekly)
                }
                guard let window else { return MenuBarSegment(label: label, value: "–", fraction: 0) }
                let shown = settings.limitShowUsed ? window.usedPercent : window.remainingPercent
                return MenuBarSegment(label: label, value: "\(Int(shown.rounded()))%", fraction: shown / 100,
                                      alert: settings.menuBarAlertColor && window.usedPercent >= threshold)
            case .todayTokens:
                return MenuBarSegment(label: label, value: state.period(\.today).map { Fmt.compact($0.totalTokens) } ?? "–")
            case .todayCost:
                return MenuBarSegment(label: label, value: state.period(\.today).map { Fmt.money($0.costUsd) } ?? "–")
            case .monthCost:
                return MenuBarSegment(label: label, value: state.period(\.month).map { Fmt.money($0.costUsd) } ?? "–")
            case .sessionReset:
                let reset = state.limits.claude?.window(.session)?.resetsAt
                return MenuBarSegment(label: label, value: reset.map { countdown(to: $0, now: now) } ?? "–")
            }
        }
    }

    /// 2h13m / 45m / 3d4h
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m" }
        return "\(minutes / 1440)d\(minutes % 1440 / 60)h"
    }

    static func accessibilityText(_ segments: [MenuBarSegment]) -> String {
        let parts = segments.map { "\($0.label) \($0.value)" }
        return parts.isEmpty ? "SimpleToken" : "SimpleToken: " + parts.joined(separator: ", ")
    }
}

/// Draws the menu bar content as one image: single line / two-line / ring / bar.
/// Without any alert values it is a template image (the system adapts it to light / dark menu bars and highlighting);
/// with alerts it uses semantic colours (labelColor etc. resolve against the menu bar appearance when drawing).
enum MenuBarRenderer {
    enum Style: String, CaseIterable {
        case text, stacked, ring, bar
        var localizedName: String {
            switch self {
            case .text: L("Single line")
            case .stacked: L("Two lines")
            case .ring: L("Ring")
            case .bar: L("Bar")
            }
        }
    }

    static let alertColor = NSColor(srgbRed: 0.94, green: 0.45, blue: 0.40, alpha: 1)

    private enum Piece {
        case mark
        case text(label: String?, value: String, alert: Bool)
        case stacked(label: String, value: String, alert: Bool)
        case ring(label: String?, value: String, fraction: Double, alert: Bool)
        case bar(label: String?, value: String, fraction: Double, alert: Bool)
        case dot
    }

    // Fonts
    nonisolated(unsafe) private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    nonisolated(unsafe) private static let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    nonisolated(unsafe) private static let stackLabelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
    nonisolated(unsafe) private static let stackValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) private static let barValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private static let markSize: CGFloat = 16
    private static let ringSize: CGFloat = 13
    private static let gap: CGFloat = 8

    static func image(_ segments: [MenuBarSegment], style: Style, showIcon: Bool, showLabels: Bool,
                      height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        var pieces: [Piece] = []
        if showIcon || segments.isEmpty { pieces.append(.mark) }
        for (i, s) in segments.enumerated() {
            let label = showLabels ? s.label : nil
            switch style {
            case .text:
                if i > 0, !showLabels { pieces.append(.dot) }
                pieces.append(.text(label: label, value: s.value, alert: s.alert))
            case .stacked:
                pieces.append(.stacked(label: s.label, value: s.value, alert: s.alert))
            case .ring:
                if let f = s.fraction { pieces.append(.ring(label: label, value: s.value, fraction: f, alert: s.alert)) }
                else { pieces.append(.text(label: label, value: s.value, alert: false)) }
            case .bar:
                if let f = s.fraction { pieces.append(.bar(label: label, value: s.value, fraction: f, alert: s.alert)) }
                else { pieces.append(.text(label: label, value: s.value, alert: false)) }
            }
        }
        let widths = pieces.map(width)
        var total = widths.reduce(0, +)
        for i in pieces.indices.dropFirst() { total += spacing(pieces[i - 1], pieces[i]) }
        let size = NSSize(width: ceil(max(total, 1)) + 2, height: height)
        let template = !segments.contains { $0.alert }

        let image = NSImage(size: size, flipped: true) { rect in
            let palette = Colors(template: template)
            var x: CGFloat = 1
            for (i, piece) in pieces.enumerated() {
                if i > 0 { x += spacing(pieces[i - 1], piece) }
                draw(piece, x: x, width: widths[i], height: rect.height, palette)
                x += widths[i]
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    // MARK: - Layout

    private static func measure(_ s: String, _ font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    private static func width(_ piece: Piece) -> CGFloat {
        switch piece {
        case .mark: return markSize
        case .dot: return 3
        case let .text(label, value, _):
            return (label.map { measure($0, labelFont).width + 3 } ?? 0) + measure(value, valueFont).width
        case let .stacked(label, value, _):
            return max(measure(label, stackLabelFont).width, measure(value, stackValueFont).width)
        case let .ring(label, value, _, _):
            return (label.map { measure($0, labelFont).width + 4 } ?? 0) + ringSize + 4 + measure(value, valueFont).width
        case let .bar(label, value, _, _):
            return (label.map { measure($0, labelFont).width + 4 } ?? 0) + max(22, measure(value, barValueFont).width)
        }
    }

    private static func spacing(_ a: Piece, _ b: Piece) -> CGFloat {
        if case .mark = a { return 5 }
        if case .dot = a { return 5 }
        if case .dot = b { return 5 }
        if case .stacked = a { return 7 }
        return gap
    }

    private struct Colors {
        let primary: NSColor
        let secondary: NSColor
        let track: NSColor

        init(template: Bool) {
            if template {
                primary = .black
                secondary = NSColor.black.withAlphaComponent(0.55)
                track = NSColor.black.withAlphaComponent(0.22)
            } else {
                primary = .labelColor
                secondary = .secondaryLabelColor
                track = .quaternaryLabelColor
            }
        }
    }

    // MARK: - Drawing (flipped coordinates: y points down)

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, centerY: CGFloat) {
        let size = measure(s, font)
        (s as NSString).draw(at: NSPoint(x: x, y: centerY - size.height / 2),
                             withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func draw(_ piece: Piece, x: CGFloat, width: CGFloat, height h: CGFloat, _ c: Colors) {
        let mid = h / 2
        switch piece {
        case .mark:
            drawMark(in: NSRect(x: x, y: mid - markSize / 2, width: markSize, height: markSize), color: c.primary)

        case .dot:
            c.secondary.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: mid - 1.5, width: 3, height: 3)).fill()

        case let .text(label, value, alert):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 3
            }
            text(value, valueFont, alert ? alertColor : c.primary, x: cursor, centerY: mid)

        case let .stacked(label, value, alert):
            let labelW = measure(label, stackLabelFont).width
            let valueW = measure(value, stackValueFont).width
            text(label, stackLabelFont, c.secondary, x: x + (width - labelW) / 2, centerY: mid - 5.2)
            text(value, stackValueFont, alert ? alertColor : c.primary, x: x + (width - valueW) / 2, centerY: mid + 4.6)

        case let .ring(label, value, fraction, alert):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 4
            }
            let line: CGFloat = 2.2
            let r = ringSize / 2 - line / 2
            let center = NSPoint(x: cursor + ringSize / 2, y: mid)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = line
            c.track.setStroke()
            track.stroke()
            let f = min(1, max(0, fraction))
            if f > 0 {
                // In flipped coordinates increasing angle = visually clockwise; -90° is straight up
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: r, startAngle: -90, endAngle: -90 + 360 * max(f, 0.03), clockwise: false)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                (alert ? alertColor : c.primary).setStroke()
                arc.stroke()
            }
            cursor += ringSize + 4
            text(value, valueFont, alert ? alertColor : c.primary, x: cursor, centerY: mid)

        case let .bar(label, value, fraction, alert):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 4
            }
            let column = width - (cursor - x)
            let valueW = measure(value, barValueFont).width
            text(value, barValueFont, alert ? alertColor : c.primary, x: cursor + (column - valueW) / 2, centerY: mid - 2.6)
            let barRect = NSRect(x: cursor, y: mid + 5.2, width: column, height: 2.5)
            c.track.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            let f = min(1, max(0, fraction))
            if f > 0 {
                (alert ? alertColor : c.primary).setFill()
                NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY, width: max(2.5, column * f), height: barRect.height),
                             xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }

    /// SimpleToken mark: a faint thin outer ring + a thick arc from 6 o'clock to 3 o'clock (flipped coordinates: increasing angle = visually clockwise)
    static func drawMark(in rect: NSRect, color: NSColor) {
        let g = BrandMarkGeometry(size: rect.width)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - g.radius, y: center.y - g.radius, width: g.radius * 2, height: g.radius * 2))
        ring.lineWidth = g.ringWidth
        color.withAlphaComponent(0.55).setStroke()
        ring.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: g.arcRadius,
                      startAngle: BrandMarkGeometry.arcStart, endAngle: BrandMarkGeometry.arcEnd, clockwise: false)
        arc.lineWidth = g.arcWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

/// Renders the menu-bar item for the current settings (screenshots and previews outside the status bar).
@MainActor
public enum MenuBarSnapshot {
    public static func image(state: AppState, style: String, showLabels: Bool, height: CGFloat = 24) -> NSImage {
        let settings = SettingsStore.shared
        return MenuBarRenderer.image(MenuBarContent.segments(state: state),
                                     style: MenuBarRenderer.Style(rawValue: style) ?? .text,
                                     showIcon: settings.menuBarShowIcon, showLabels: showLabels, height: height)
    }
}
