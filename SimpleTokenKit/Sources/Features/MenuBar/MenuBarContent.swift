import AppKit
import Core
import DesignSystem

/// One segment in the menu bar: a limit / today / this month / a small chart…
struct MenuBarSegment: Equatable {
    var label: String
    /// The number shown; for a chart, what VoiceOver reads (the chart itself carries no number)
    var value: String
    /// Fill fraction for limits (0…1, already converted for the used / left setting); nil for non-limits
    var fraction: Double?
    /// Where even use would be by now (0…1, same direction as `fraction`); nil when hidden or unknown
    var pace: Double?
    /// Where the window is heading by its reset at the current pace (0…1); nil when hidden, unknown or in Left mode
    var projected: Double?
    /// A small bar chart (0…1 per bar); nil for numbers
    var series: [Double]?
    /// The bar drawn in full strength while the others step back (today in the last 7 days)
    var highlight: Int?
    /// Bars after this one have not happened yet (later hours of today)
    var upTo: Int?
    /// The limit has reached the highest alert threshold
    var alert = false

    var isLimit: Bool { fraction != nil }
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
                let used = settings.limitShowUsed
                let shown = used ? window.usedPercent : window.remainingPercent
                var segment = MenuBarSegment(label: label, value: "\(Int(shown.rounded()))%", fraction: shown / 100,
                                             alert: settings.menuBarAlertColor && window.usedPercent >= threshold)
                if settings.menuBarShowPace, let elapsed = window.elapsedFraction(now: now) {
                    segment.pace = used ? elapsed : 1 - elapsed
                    if used, let projected = window.projectedPercent(now: now) { segment.projected = min(1, projected / 100) }
                }
                return segment
            case .todayTokens:
                return MenuBarSegment(label: label, value: state.period(\.today).map { Fmt.compact($0.totalTokens) } ?? "–")
            case .todayCost:
                return MenuBarSegment(label: label, value: state.period(\.today).map { Fmt.money($0.costUsd) } ?? "–")
            case .monthCost:
                return MenuBarSegment(label: label, value: state.period(\.month).map { Fmt.money($0.costUsd) } ?? "–")
            case .sessionReset:
                let reset = state.limits.claude?.window(.session)?.resetsAt
                return MenuBarSegment(label: label, value: reset.map { countdown(to: $0, now: now) } ?? "–")
            case .todayHours:
                // Half hours paired into hours; hours still to come are drawn as dots on the baseline
                let halves = state.todayHalfHours
                let hours = (0..<24).map { h in Double(halves.indices.contains(2 * h + 1) ? halves[2 * h] + halves[2 * h + 1] : 0) }
                let top = max(1, hours.max() ?? 0)
                let total = hours.reduce(0, +)
                return MenuBarSegment(label: label, value: Fmt.compact(Int(total)), series: hours.map { $0 / top },
                                      upTo: Calendar.current.component(.hour, from: now))
            case .lastWeek:
                let days = state.report(range: .week, metric: .tokens).days.suffix(7).map { Double($0.tokens) }
                let top = max(1, days.max() ?? 0)
                return MenuBarSegment(label: label, value: Fmt.compact(Int(days.reduce(0, +))), series: days.map { $0 / top },
                                      highlight: days.isEmpty ? nil : days.count - 1)
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

/// Draws the menu bar content as one image. Styles: single line, two lines (label over value), compact (two items
/// per column), ring (each limit as a small ring), nested rings (all limits in one set of rings, like Activity),
/// bar (a progress bar under each limit). Rings and bars can mark even pace (a notch or tick) and the projection
/// to the reset (a fainter extension). Chart items (today by hour, last 7 days) draw small bars in every style.
/// Without any alert values it is a template image (the system adapts it to light / dark menu bars and highlighting);
/// with alerts it uses semantic colours (labelColor etc. resolve against the menu bar appearance when drawing).
enum MenuBarRenderer {
    enum Style: String, CaseIterable {
        case text, stacked, dense, ring, rings, bar
        var localizedName: String {
            switch self {
            case .text: L("Single line")
            case .stacked: L("Two lines")
            case .dense: L("Compact")
            case .ring: L("Ring")
            case .rings: L("Nested rings")
            case .bar: L("Bar")
            }
        }
    }

    static let alertColor = NSColor(srgbRed: 0.94, green: 0.45, blue: 0.40, alpha: 1)

    /// A limit as drawn in a ring or a bar
    private struct Gauge {
        var fraction: Double
        var pace: Double?
        var projected: Double?
        var alert: Bool

        init(_ s: MenuBarSegment) {
            fraction = min(1, max(0, s.fraction ?? 0))
            pace = s.pace.map { min(1, max(0, $0)) }
            projected = s.projected.map { min(1, max(0, $0)) }
            alert = s.alert
        }
    }

    private struct Chart {
        var series: [Double]
        var highlight: Int?
        var upTo: Int?

        init(_ s: MenuBarSegment) {
            series = s.series ?? []
            highlight = s.highlight
            upTo = s.upTo
        }
    }

    /// One row of the compact style
    private enum Cell {
        case text(label: String?, value: String, alert: Bool)
        case chart(label: String?, Chart)
    }

    private enum Piece {
        case mark
        case text(label: String?, value: String, alert: Bool)
        case stacked(label: String, value: String, alert: Bool)
        case stackedChart(label: String, Chart)
        case ring(label: String?, value: String, Gauge)
        case rings([Gauge], values: [(label: String?, value: String, alert: Bool)])
        case bar(label: String?, value: String, Gauge)
        case chart(label: String?, Chart)
        case column(Cell, Cell?)
        case dot
    }

    // Fonts
    nonisolated(unsafe) private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    nonisolated(unsafe) private static let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    nonisolated(unsafe) private static let stackLabelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
    nonisolated(unsafe) private static let stackValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) private static let barValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) private static let cellLabelFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
    nonisolated(unsafe) private static let cellValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    private static let markSize: CGFloat = 16
    private static let ringSize: CGFloat = 13
    private static let gap: CGFloat = 8
    /// Rows of the two-line and compact styles, from the middle of the bar
    private static let rowOffset: CGFloat = 5.2

    static func image(_ segments: [MenuBarSegment], style: Style, showIcon: Bool, showLabels: Bool,
                      height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        var pieces: [Piece] = []
        if showIcon || segments.isEmpty { pieces.append(.mark) }
        switch style {
        case .rings:
            // Up to three limits nest in one set of rings (the first outermost); the rest follow as usual
            let limits = Array(segments.filter(\.isLimit).prefix(3))
            var placed = false
            for (i, s) in segments.enumerated() {
                if s.isLimit, limits.contains(s), !placed {
                    placed = true
                    let values = limits.prefix(2).map { (label: showLabels ? $0.label : nil, value: $0.value, alert: $0.alert) }
                    pieces.append(.rings(limits.map(Gauge.init), values: values))
                } else if s.isLimit, limits.contains(s) {
                    continue
                } else {
                    pieces.append(contentsOf: plain(s, index: i, showLabels: showLabels, separate: false))
                }
            }
        case .dense:
            var i = 0
            while i < segments.count {
                let top = cell(segments[i], showLabels: showLabels)
                let bottom = i + 1 < segments.count ? cell(segments[i + 1], showLabels: showLabels) : nil
                pieces.append(.column(top, bottom))
                i += 2
            }
        default:
            for (i, s) in segments.enumerated() {
                let label = showLabels ? s.label : nil
                if s.series != nil {
                    pieces.append(style == .stacked ? .stackedChart(label: s.label, Chart(s)) : .chart(label: label, Chart(s)))
                    continue
                }
                switch style {
                case .stacked:
                    pieces.append(.stacked(label: s.label, value: s.value, alert: s.alert))
                case .ring where s.isLimit:
                    pieces.append(.ring(label: label, value: s.value, Gauge(s)))
                case .bar where s.isLimit:
                    pieces.append(.bar(label: label, value: s.value, Gauge(s)))
                default:
                    pieces.append(contentsOf: plain(s, index: i, showLabels: showLabels, separate: style == .text))
                }
            }
        }

        let widths = pieces.map { width($0, height: height) }
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

    /// A segment as a number (with a separator dot between unlabelled numbers in the single-line style) or a chart
    private static func plain(_ s: MenuBarSegment, index: Int, showLabels: Bool, separate: Bool) -> [Piece] {
        let label = showLabels ? s.label : nil
        if s.series != nil { return [.chart(label: label, Chart(s))] }
        var out: [Piece] = []
        if separate, index > 0, !showLabels { out.append(.dot) }
        out.append(.text(label: label, value: s.value, alert: s.alert))
        return out
    }

    private static func cell(_ s: MenuBarSegment, showLabels: Bool) -> Cell {
        let label = showLabels ? s.label : nil
        return s.series != nil ? .chart(label: label, Chart(s)) : .text(label: label, value: s.value, alert: s.alert)
    }

    // MARK: - Layout

    private static func measure(_ s: String, _ font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    /// Bar width and gap of a chart: a week reads as a few chunky bars, a day as fine ones
    private static func chartMetrics(_ count: Int) -> (bar: CGFloat, gap: CGFloat) {
        count <= 12 ? (3, 1.5) : (1.25, 0.5)
    }

    private static func chartWidth(_ chart: Chart) -> CGFloat {
        let n = CGFloat(max(1, chart.series.count))
        let m = chartMetrics(chart.series.count)
        return n * m.bar + (n - 1) * m.gap
    }

    /// Diameter of the nested rings
    private static func ringsSize(_ height: CGFloat) -> CGFloat { min(20, height - 4) }

    private static func cellWidth(_ cell: Cell) -> CGFloat {
        switch cell {
        case let .text(label, value, _):
            return (label.map { measure($0, cellLabelFont).width + 3 } ?? 0) + measure(value, cellValueFont).width
        case let .chart(label, chart):
            return (label.map { measure($0, cellLabelFont).width + 3 } ?? 0) + chartWidth(chart)
        }
    }

    private static func width(_ piece: Piece, height: CGFloat) -> CGFloat {
        switch piece {
        case .mark: return markSize
        case .dot: return 3
        case let .text(label, value, _):
            return (label.map { measure($0, labelFont).width + 3 } ?? 0) + measure(value, valueFont).width
        case let .stacked(label, value, _):
            return max(measure(label, stackLabelFont).width, measure(value, stackValueFont).width)
        case let .stackedChart(label, chart):
            return max(measure(label, stackLabelFont).width, chartWidth(chart))
        case let .ring(label, value, _):
            return (label.map { measure($0, labelFont).width + 4 } ?? 0) + ringSize + 4 + measure(value, valueFont).width
        case let .rings(_, values):
            let size = ringsSize(height)
            guard !values.isEmpty else { return size }
            let font = values.count > 1 ? cellValueFont : valueFont
            let labelFontUsed = values.count > 1 ? cellLabelFont : labelFont
            let column = values.map { v in (v.label.map { measure($0, labelFontUsed).width + 3 } ?? 0) + measure(v.value, font).width }.max() ?? 0
            return size + 5 + column
        case let .bar(label, value, _):
            return (label.map { measure($0, labelFont).width + 4 } ?? 0) + max(22, measure(value, barValueFont).width)
        case let .chart(label, chart):
            return (label.map { measure($0, labelFont).width + 4 } ?? 0) + chartWidth(chart)
        case let .column(top, bottom):
            return max(cellWidth(top), bottom.map(cellWidth) ?? 0)
        }
    }

    private static func spacing(_ a: Piece, _ b: Piece) -> CGFloat {
        if case .mark = a { return 5 }
        if case .dot = a { return 5 }
        if case .dot = b { return 5 }
        if case .stacked = a { return 7 }
        if case .column = a { return 9 }
        return gap
    }

    private struct Colors {
        let primary: NSColor
        let secondary: NSColor
        /// Projections and context bars
        let faint: NSColor
        let track: NSColor

        init(template: Bool) {
            if template {
                primary = .black
                secondary = NSColor.black.withAlphaComponent(0.55)
                faint = NSColor.black.withAlphaComponent(0.42)
                track = NSColor.black.withAlphaComponent(0.22)
            } else {
                primary = .labelColor
                secondary = .secondaryLabelColor
                faint = .tertiaryLabelColor
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
            text(label, stackLabelFont, c.secondary, x: x + (width - labelW) / 2, centerY: mid - rowOffset)
            text(value, stackValueFont, alert ? alertColor : c.primary, x: x + (width - valueW) / 2, centerY: mid + 4.6)

        case let .stackedChart(label, chart):
            let labelW = measure(label, stackLabelFont).width
            text(label, stackLabelFont, c.secondary, x: x + (width - labelW) / 2, centerY: mid - rowOffset)
            let w = chartWidth(chart)
            drawChart(chart, in: NSRect(x: x + (width - w) / 2, y: mid + 0.8, width: w, height: 8.5), c)

        case let .ring(label, value, gauge):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 4
            }
            let line: CGFloat = 2.2
            drawRing(gauge, center: NSPoint(x: cursor + ringSize / 2, y: mid), radius: ringSize / 2 - line / 2, line: line, c)
            cursor += ringSize + 4
            text(value, valueFont, gauge.alert ? alertColor : c.primary, x: cursor, centerY: mid)

        case let .rings(gauges, values):
            let size = ringsSize(h)
            let center = NSPoint(x: x + size / 2, y: mid)
            // Thicker rings when there are fewer of them; each sits in its own lane with a small gap
            let (line, lane): (CGFloat, CGFloat) = switch gauges.count {
            case 1: (2.6, 0)
            case 2: (2.5, 3.4)
            default: (2.1, 2.9)
            }
            for (i, gauge) in gauges.enumerated() {
                let radius = size / 2 - line / 2 - CGFloat(i) * lane
                guard radius > line / 2 else { break }
                drawRing(gauge, center: center, radius: radius, line: line, c)
            }
            var cursor = x + size + 5
            if values.count == 1, let v = values.first {
                if let label = v.label {
                    text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                    cursor += measure(label, labelFont).width + 3
                }
                text(v.value, valueFont, v.alert ? alertColor : c.primary, x: cursor, centerY: mid)
            } else {
                for (row, v) in values.enumerated() {
                    let y = row == 0 ? mid - rowOffset : mid + rowOffset
                    var rowX = cursor
                    if let label = v.label {
                        text(label, cellLabelFont, c.secondary, x: rowX, centerY: y + 0.3)
                        rowX += measure(label, cellLabelFont).width + 3
                    }
                    text(v.value, cellValueFont, v.alert ? alertColor : c.primary, x: rowX, centerY: y)
                }
                cursor = x
            }

        case let .bar(label, value, gauge):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 4
            }
            let column = width - (cursor - x)
            let valueW = measure(value, barValueFont).width
            text(value, barValueFont, gauge.alert ? alertColor : c.primary, x: cursor + (column - valueW) / 2, centerY: mid - 2.6)
            drawBar(gauge, in: NSRect(x: cursor, y: mid + 5.2, width: column, height: 2.5), c)

        case let .chart(label, chart):
            var cursor = x
            if let label {
                text(label, labelFont, c.secondary, x: cursor, centerY: mid + 0.5)
                cursor += measure(label, labelFont).width + 4
            }
            drawChart(chart, in: NSRect(x: cursor, y: mid - 6.5, width: chartWidth(chart), height: 13), c)

        case let .column(top, bottom):
            drawCell(top, x: x, centerY: bottom == nil ? mid : mid - rowOffset, c)
            if let bottom { drawCell(bottom, x: x, centerY: mid + rowOffset, c) }
        }
    }

    private static func drawCell(_ cell: Cell, x: CGFloat, centerY: CGFloat, _ c: Colors) {
        switch cell {
        case let .text(label, value, alert):
            var cursor = x
            if let label {
                text(label, cellLabelFont, c.secondary, x: cursor, centerY: centerY + 0.3)
                cursor += measure(label, cellLabelFont).width + 3
            }
            text(value, cellValueFont, alert ? alertColor : c.primary, x: cursor, centerY: centerY)
        case let .chart(label, chart):
            var cursor = x
            if let label {
                text(label, cellLabelFont, c.secondary, x: cursor, centerY: centerY + 0.3)
                cursor += measure(label, cellLabelFont).width + 3
            }
            drawChart(chart, in: NSRect(x: cursor, y: centerY - 4, width: chartWidth(chart), height: 8), c)
        }
    }

    /// A limit as a ring: the track, a fainter arc to the projection, the used arc, and a pace marker
    /// (a gap where it crosses the used arc, a tick where it crosses the track)
    private static func drawRing(_ g: Gauge, center: NSPoint, radius r: CGFloat, line: CGFloat, _ c: Colors) {
        func arc(from a: Double, to b: Double) -> NSBezierPath {
            // In flipped coordinates increasing angle = visually clockwise; -90° is straight up
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: r, startAngle: -90 + 360 * a, endAngle: -90 + 360 * b, clockwise: false)
            path.lineWidth = line
            path.lineCapStyle = .round
            return path
        }
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        c.track.setStroke()
        track.stroke()
        if let projected = g.projected, projected > g.fraction + 0.01 {
            c.faint.setStroke()
            arc(from: g.fraction, to: projected).stroke()
        }
        if g.fraction > 0 {
            (g.alert ? alertColor : c.primary).setStroke()
            arc(from: 0, to: max(g.fraction, 0.03)).stroke()
        }
        guard let pace = g.pace else { return }
        let angle = (-90 + 360 * pace) * .pi / 180
        let inner = r - line / 2 - 0.6, outer = r + line / 2 + 0.6
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
        tick.line(to: NSPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        tick.lineWidth = 1
        if pace <= g.fraction {
            NSGraphicsContext.current?.compositingOperation = .clear
            tick.lineWidth = 1.2
            tick.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            c.primary.setStroke()
            tick.stroke()
        }
    }

    /// A limit as a bar: the track, a fainter extension to the projection, the used part, and a pace marker
    private static func drawBar(_ g: Gauge, in rect: NSRect, _ c: Colors) {
        let radius = rect.height / 2
        c.track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let projected = g.projected, projected > g.fraction + 0.01 {
            c.faint.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * projected), height: rect.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        if g.fraction > 0 {
            (g.alert ? alertColor : c.primary).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * g.fraction), height: rect.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        guard let pace = g.pace else { return }
        let x = (rect.minX + rect.width * pace).rounded() - 0.5
        if pace <= g.fraction {
            NSGraphicsContext.current?.compositingOperation = .clear
            NSRect(x: x, y: rect.minY - 0.5, width: 1, height: rect.height + 1).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        c.primary.setFill()
        NSRect(x: x, y: rect.minY - 2, width: 1, height: 1.5).fill()
        NSRect(x: x, y: rect.maxY + 0.5, width: 1, height: 1.5).fill()
    }

    /// Small bars from the baseline; the highlighted bar is full strength, bars still to come are dots
    private static func drawChart(_ chart: Chart, in rect: NSRect, _ c: Colors) {
        let m = chartMetrics(chart.series.count)
        for (i, v) in chart.series.enumerated() {
            let x = rect.minX + CGFloat(i) * (m.bar + m.gap)
            if let upTo = chart.upTo, i > upTo {
                c.track.setFill()
                NSRect(x: x, y: rect.maxY - 1, width: m.bar, height: 1).fill()
                continue
            }
            let h = v > 0 ? max(1.5, rect.height * CGFloat(min(1, v))) : 1
            let color: NSColor = v <= 0 ? c.track : chart.highlight == nil || chart.highlight == i ? c.primary : c.faint
            color.setFill()
            let bar = NSRect(x: x, y: rect.maxY - h, width: m.bar, height: h)
            if m.bar >= 2.5 {
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            } else {
                bar.fill()
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
