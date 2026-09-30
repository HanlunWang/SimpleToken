import SwiftUI
import Charts
import Core
import DesignSystem

/// Shared hover tip: cards hand it their content and the pointer position; the dashboard draws it on top.
/// Drawing it on top rather than inside the card lets it cross card edges without being covered by the next card.
@Observable
@MainActor
final class HoverTip {
    static let space = "simpletoken.dashboard"

    private(set) var id: String?
    private(set) var point: CGPoint = .zero
    private(set) var content: AnyView?
    /// Scrolling: hover callbacks are treated as "exit" (read in event callbacks, not observed by views)
    @ObservationIgnored var scrolling = false

    func hideAll() {
        guard id != nil else { return }
        id = nil
        content = nil
    }

    func show<V: View>(_ id: String, at point: CGPoint, @ViewBuilder _ content: () -> V) {
        self.id = id
        self.point = point
        self.content = AnyView(content())
    }

    /// Same content, new position only (moving within one cell does not rebuild the tip content)
    func move(_ id: String, to point: CGPoint) {
        guard self.id == id, self.point != point else { return }
        self.point = point
    }

    func hide(_ id: String) {
        guard self.id == id else { return }
        self.id = nil
        content = nil
    }
}

/// Tip layer: centered above the pointer by default; flips below when the top bar is in the way; clamped horizontally to the container
struct HoverTipLayer: View {
    let tip: HoverTip
    /// Top of the visible area (content coordinates, below the top bar). Read only while a tip shows, so scrolling does not redraw this layer
    let scroll: ScrollTracker
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let content = tip.content {
                let above = tip.point.y - size.height - 14
                let y = above < scroll.dashboardTop + 6 ? tip.point.y + 20 : above
                let x = min(max(8, tip.point.x - size.width / 2), max(8, geo.size.width - size.width - 8))
                content
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                    .offset(x: x, y: y)
                    .opacity(size == .zero ? 0 : 1)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tip card layout

/// Tip card: title + rows + optional footnote
struct TipCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.app(Typo.body, .semibold)).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.app(Typo.small)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .monospacedDigit()
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(minWidth: 150, maxWidth: 300, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

/// One tip row: swatch + name + value (+ secondary value)
struct TipRow: View {
    var color: Color?
    let label: String
    let value: String
    var secondary: String?

    var body: some View {
        HStack(spacing: 6) {
            if let color { Swatch(color, size: 7) }
            Text(label).font(.app(Typo.small)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Text(value).font(.app(Typo.small, .medium)).lineLimit(1).fixedSize()
            if let secondary {
                Text(secondary).font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
    }
}

/// Distribution bar in a tip: proportional segments with 1px gaps
struct TipBar: View {
    let parts: [(Color, Double)]

    var body: some View {
        let total = max(1e-9, parts.reduce(0) { $0 + $1.1 })
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(parts[i].0)
                        .frame(width: max(1, (geo.size.width - CGFloat(parts.count - 1)) * parts[i].1 / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .padding(.vertical, 2)
    }
}

/// One day's breakdown (shared by the calendar, stat tiles and bar charts): usage / cost / messages + models + tools
struct DayDetailTip: View {
    let day: DailyHistoryArchive.DaySummary
    let colors: ModelColors
    let exact: Bool
    var title: String?
    var note: String?

    var body: some View {
        let models = day.byModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let tools = day.byClient.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let total = Double(max(1, day.tokens))
        TipCard(title: title ?? DayDetailTip.dateTitle(day.date), subtitle: note) {
            if day.tokens == 0 {
                Text("No usage this day").font(.app(Typo.small)).foregroundStyle(.tertiary)
            } else {
                TipRow(label: "Tokens", value: Fmt.tokens(Double(day.tokens), exact: exact))
                TipRow(label: L("Cost"), value: Fmt.money(day.cost))
                TipRow(label: L("Messages"), value: Fmt.metric(Double(day.messages), .messages, exact: true))
                if !models.isEmpty {
                    Divider().overlay(Palette.hairline).padding(.vertical, 1)
                    TipBar(parts: models.map { (colors.color($0.key), Double($0.value)) })
                    ForEach(models.prefix(5), id: \.key) { m, t in
                        TipRow(color: colors.color(m), label: colors.name(m),
                               value: Fmt.tokens(Double(t), exact: false),
                               secondary: percent(Double(t) / total))
                    }
                    if models.count > 5 {
                        Text("+\(models.count - 5) more models").font(.app(Typo.axis)).foregroundStyle(.tertiary)
                    }
                }
                if tools.count > 1 {
                    Divider().overlay(Palette.hairline).padding(.vertical, 1)
                    ForEach(tools.prefix(4), id: \.key) { c, t in
                        TipRow(color: colors.toolColor(c), label: ModelPalette.toolLabel(c),
                               value: Fmt.tokens(Double(t), exact: false), secondary: percent(Double(t) / total))
                    }
                }
            }
        }
    }

    static func dateTitle(_ key: String) -> String {
        let date = Fmt.longDate(key)
        return key == Fmt.dayKey() ? L("Today · \(date)") : date
    }
}

// MARK: - Chart hover

/// Hover layer over Swift Charts: reports the x value and pointer position (dashboard coordinates) as the mouse moves.
/// On macOS chartXSelection only fires while dragging, so hover readouts need their own handling.
struct ChartHoverArea<X: Plottable>: View {
    let proxy: ChartProxy
    let onHover: (X?, CGPoint) -> Void
    @Environment(HoverTip.self) private var tip: HoverTip?

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if tip?.scrolling == true { onHover(nil, .zero); return }
                    switch phase {
                    case .active(let p):
                        guard let anchor = proxy.plotFrame else { return }
                        let plot = geo[anchor]
                        guard p.x >= plot.minX - 4, p.x <= plot.maxX + 4 else { onHover(nil, .zero); return }
                        let x: X? = proxy.value(atX: min(max(p.x, plot.minX), plot.maxX) - plot.minX)
                        let origin = geo.frame(in: .named(HoverTip.space)).origin
                        onHover(x, CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                    case .ended:
                        onHover(nil, .zero)
                    }
                }
        }
    }
}

extension View {
    /// Hover readout: x value + pointer position in the dashboard; nil on exit
    func chartHover<X: Plottable>(_ type: X.Type, _ onHover: @escaping (X?, CGPoint) -> Void) -> some View {
        chartOverlay { proxy in ChartHoverArea<X>(proxy: proxy, onHover: onHover) }
    }

    /// Hover for plain views: pointer position in the dashboard; nil on exit
    func dashboardHover(_ onHover: @escaping (CGPoint?) -> Void) -> some View {
        modifier(DashboardHover(onHover: onHover))
    }
}

private struct DashboardHover: ViewModifier {
    let onHover: (CGPoint?) -> Void
    @Environment(HoverTip.self) private var tip: HoverTip?

    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .named(HoverTip.space)) { phase in
            if tip?.scrolling == true { onHover(nil); return }
            switch phase {
            case .active(let p): onHover(p)
            case .ended: onHover(nil)
            }
        }
    }
}
