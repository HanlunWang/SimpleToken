import SwiftUI
import Core
import DesignSystem

// MARK: - Widget grid

/// Grid metrics: cell size is roughly fixed; wider windows get more columns
enum WidgetMetrics {
    static let spacing: CGFloat = 12
    static let rowHeight: CGFloat = 150
    static let minColumn: CGFloat = 160
    static let maxColumns = 8

    /// Even column counts only: most widgets are two cells wide, so an odd count leaves a gap on the right
    static func columns(width: CGFloat) -> Int {
        let fit = Int((width + spacing) / (minColumn + spacing))
        return max(2, min(maxColumns, fit - fit % 2))
    }

    /// Effective size: with only two columns, "wide" lays out as "large"
    static func effective(_ size: SettingsStore.CardSize, columns: Int) -> SettingsStore.CardSize {
        size == .wide && columns < 3 ? .large : size
    }

    static func span(_ size: SettingsStore.CardSize, columns: Int) -> GridSpan {
        let s = effective(size, columns: columns).span
        return GridSpan(columns: min(s.columns, columns), rows: s.rows)
    }
}

struct GridSpan: Equatable {
    var columns: Int
    var rows: Int
}

private struct GridSpanKey: LayoutValueKey {
    static let defaultValue = GridSpan(columns: 1, rows: 1)
}

extension View {
    func gridSpan(_ span: GridSpan) -> some View { layoutValue(key: GridSpanKey.self, value: span) }
}

/// Widget grid: places each widget in order at the topmost, leftmost spot that fits (fills gaps like desktop widgets)
struct WidgetGrid: Layout {
    var columns: Int
    var rowHeight: CGFloat = WidgetMetrics.rowHeight
    var spacing: CGFloat = WidgetMetrics.spacing

    /// Each widget's top-left cell (column, row) and the total row count
    static func pack(_ spans: [GridSpan], columns: Int) -> (origins: [(column: Int, row: Int)], rows: Int) {
        var taken: [[Bool]] = []
        func fits(_ r: Int, _ c: Int, _ s: GridSpan) -> Bool {
            for rr in r..<(r + s.rows) where rr < taken.count {
                for cc in c..<(c + s.columns) where taken[rr][cc] { return false }
            }
            return true
        }
        var origins: [(column: Int, row: Int)] = []
        for span in spans {
            let s = GridSpan(columns: min(span.columns, columns), rows: span.rows)
            var r = 0
            search: while true {
                for c in 0...(columns - s.columns) where fits(r, c, s) {
                    while taken.count < r + s.rows { taken.append(Array(repeating: false, count: columns)) }
                    for rr in r..<(r + s.rows) { for cc in c..<(c + s.columns) { taken[rr][cc] = true } }
                    origins.append((c, r))
                    break search
                }
                r += 1
            }
        }
        return (origins, taken.count)
    }

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.pack(subviews.map { $0[GridSpanKey.self] }, columns: columns).rows
        let height = rows > 0 ? CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing : 0
        return CGSize(width: proposal.width ?? CGFloat(columns) * (WidgetMetrics.minColumn + spacing), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spans = subviews.map { $0[GridSpanKey.self] }
        let origins = Self.pack(spans, columns: columns).origins
        let col = columnWidth(bounds.width)
        for (i, view) in subviews.enumerated() {
            let s = GridSpan(columns: min(spans[i].columns, columns), rows: spans[i].rows)
            let x = bounds.minX + CGFloat(origins[i].column) * (col + spacing)
            let y = bounds.minY + CGFloat(origins[i].row) * (rowHeight + spacing)
            let w = CGFloat(s.columns) * col + CGFloat(s.columns - 1) * spacing
            let h = CGFloat(s.rows) * rowHeight + CGFloat(s.rows - 1) * spacing
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: h))
        }
    }
}

// MARK: - Drag to rearrange

/// Drag state. Only the floating copy reads `location` (changes on every mouse move); cards themselves read only `card`.
@Observable
@MainActor
final class CardDrag {
    /// Coordinate space of the scroll view (viewport); card frames are stored in content coordinates (HoverTip.space)
    static let viewport = "simpletoken.viewport"

    private(set) var card: SettingsStore.Card?
    private(set) var location: CGPoint = .zero
    private(set) var size: CGSize = .zero
    @ObservationIgnored private(set) var grab: CGSize = .zero
    @ObservationIgnored var frames: [SettingsStore.Card: CGRect] = [:]
    /// Content origin within the viewport (changes with scrolling)
    @ObservationIgnored var contentOrigin: CGPoint = .zero
    @ObservationIgnored var viewportHeight: CGFloat = 0
    @ObservationIgnored var scrollY: CGFloat = 0
    @ObservationIgnored var maxScrollY: CGFloat = 0
    @ObservationIgnored var topInset: CGFloat = 0
    @ObservationIgnored var scrollTo: ((CGFloat) -> Void)?
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored private var lastTarget: SettingsStore.Card?
    @ObservationIgnored private var autoScroll: Task<Void, Never>?

    func changed(_ card: SettingsStore.Card, _ value: DragGesture.Value) {
        if self.card == nil {
            guard let frame = frames[card] else { return }
            let start = CGPoint(x: value.startLocation.x - contentOrigin.x, y: value.startLocation.y - contentOrigin.y)
            grab = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
            size = frame.size
            location = value.location
            lastTarget = nil
            onActiveChange?(true)
            withAnimation(.snappy(duration: 0.2)) { self.card = card }
        }
        location = value.location
        reorder()
        updateAutoScroll()
    }

    func ended() {
        autoScroll?.cancel()
        autoScroll = nil
        guard card != nil else { return }
        onActiveChange?(false)
        withAnimation(.snappy(duration: 0.25)) { card = nil }
    }

    /// Moving the pointer into another card swaps to its position. The card just swapped with waits until the pointer leaves, so cards of different sizes do not bounce back and forth
    private func reorder() {
        guard let dragging = card else { return }
        let settings = SettingsStore.shared
        let point = CGPoint(x: location.x - contentOrigin.x, y: location.y - contentOrigin.y)
        let target = frames.first { other, frame in
            other != dragging && settings.isVisible(other) && frame.contains(point)
        }?.key
        guard let target else { lastTarget = nil; return }
        guard target != lastTarget else { return }
        lastTarget = target
        withAnimation(.snappy(duration: 0.32)) { settings.moveCard(dragging, to: target) }
    }

    /// Auto-scrolls near the viewport's top and bottom edges, faster the deeper the pointer goes
    private func updateAutoScroll() {
        let edge: CGFloat = 64
        let top = topInset + edge
        let y = location.y
        let speed: CGFloat
        if y < top { speed = -min(1, (top - y) / edge) * 16 }
        else if y > viewportHeight - edge { speed = min(1, (y - (viewportHeight - edge)) / edge) * 16 }
        else { speed = 0 }
        autoScroll?.cancel()
        guard speed != 0 else { autoScroll = nil; return }
        autoScroll = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                let next = min(max(-self.topInset, self.scrollY + speed), self.maxScrollY)
                if abs(next - self.scrollY) < 0.5 { break }
                self.scrollTo?(next)
                try? await Task.sleep(for: .milliseconds(16))
                self.reorder()
            }
        }
    }
}

/// Draggable card: press anywhere on the card and drag to move it (buttons and segmented controls inside still work).
/// While lifted, a dashed slot stays in place and a floating copy on the top layer follows the pointer.
struct DraggableCard<Content: View>: View {
    let card: SettingsStore.Card
    let drag: CardDrag
    @ViewBuilder var content: Content

    var body: some View {
        let lifted = drag.card == card
        content
            .opacity(lifted ? 0 : 1)
            .background {
                if lifted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.025)))
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(HoverTip.space)) }) { drag.frames[card] = $0 }
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .named(CardDrag.viewport))
                    .onChanged { drag.changed(card, $0) }
                    .onEnded { _ in drag.ended() }
            )
    }
}

/// Floating copy: sized like the card at the moment it was lifted, positioned at the pointer
struct FloatingCard<Content: View>: View {
    let drag: CardDrag
    @ViewBuilder var content: (SettingsStore.Card) -> Content

    var body: some View {
        if let card = drag.card {
            content(card)
                .frame(width: drag.size.width, height: drag.size.height)
                .scaleEffect(1.015)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .modifier(FollowPointer(drag: drag))
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
        }
    }
}

/// Only this layer recomputes as the pointer moves; the card content is not rebuilt
private struct FollowPointer: ViewModifier {
    let drag: CardDrag

    func body(content: Content) -> some View {
        content.offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
    }
}

// MARK: - Card environment

private struct DashboardCardKey: EnvironmentKey {
    static let defaultValue: SettingsStore.Card? = nil
}

private struct CardSizeKey: EnvironmentKey {
    static let defaultValue: SettingsStore.CardSize = .large
}

extension EnvironmentValues {
    /// The dashboard card the current view belongs to (used by the back face's Size row)
    var dashboardCard: SettingsStore.Card? {
        get { self[DashboardCardKey.self] }
        set { self[DashboardCardKey.self] = newValue }
    }

    /// The card's size class: small cards drop secondary content
    var cardSize: SettingsStore.CardSize {
        get { self[CardSizeKey.self] }
        set { self[CardSizeKey.self] = newValue }
    }
}

/// Size picker: lists only the sizes this widget supports
struct CardSizePicker: View {
    let card: SettingsStore.Card
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        GlassSegmented(card.sizes.map { ($0, $0.localizedName) }, selection: Binding(
            get: { settings.size(card) },
            set: { value in withAnimation(.smooth(duration: 0.4)) { settings.setSize(card, value) } }
        ))
    }
}

extension SettingsStore.CardSize {
    /// Menu label: "Medium · 2×1"
    var menuLabel: String {
        let s = span
        return "\(localizedName) · \(s.columns)×\(s.rows)"
    }
}

/// Widget context menu: size / move / hide
struct CardContextMenu: ViewModifier {
    let card: SettingsStore.Card

    func body(content: Content) -> some View {
        content.contextMenu {
            let settings = SettingsStore.shared
            Picker("Size", selection: Binding(
                get: { settings.size(card) },
                set: { value in withAnimation(.smooth(duration: 0.4)) { settings.setSize(card, value) } }
            )) {
                ForEach(card.sizes) { Text($0.menuLabel).tag($0) }
            }
            .pickerStyle(.inline)
            Button("Move Earlier", systemImage: "arrow.backward") {
                withAnimation(.smooth(duration: 0.4)) { settings.moveCard(card, by: -1) }
            }
            Button("Move Later", systemImage: "arrow.forward") {
                withAnimation(.smooth(duration: 0.4)) { settings.moveCard(card, by: 1) }
            }
            Divider()
            Button("Hide “\(card.localizedName)”", systemImage: "eye.slash") {
                withAnimation(.smooth(duration: 0.4)) { settings.setVisible(card, false) }
            }
        }
    }
}

// MARK: - Widget management in the top bar

/// Widget list in the top bar's ▦ popover: show / hide, size, reset. Positions are dragged on the dashboard itself.
struct CardsPopover: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Widgets").font(.app(Typo.title + 1, .semibold))
                Spacer()
                Button("Reset to Default") { withAnimation(.smooth(duration: 0.4)) { settings.resetLayout() } }
                    .controlSize(.small)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    group(L("Charts"), settings.orderedCards.filter { !$0.isStat })
                    group(L("Stats"), settings.orderedCards.filter(\.isStat))
                        .padding(.top, 8)
                }
            }
            .frame(maxHeight: 460)
            Text("Drag a widget to move it. Sizes: small 1×1, medium 2×1, large 2×2, wide 4×2. Wider windows add columns.")
                .font(.app(Typo.small)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
        .preferredColorScheme(.dark)
        .environment(\.locale, Fmt.uiLocale)
    }

    private func group(_ title: String, _ cards: [SettingsStore.Card]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.app(Typo.small, .semibold)).foregroundStyle(.tertiary).padding(.bottom, 2)
            ForEach(cards) { card in
                let visible = settings.isVisible(card)
                HStack(spacing: 9) {
                    Image(systemName: card.icon)
                        .font(.app(Typo.body, .medium)).foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(card.localizedName).font(.app(Typo.body + 1)).lineLimit(1)
                    Spacer(minLength: 10)
                    CardSizePicker(card: card)
                        .disabled(!visible)
                        .opacity(visible ? 1 : 0.35)
                    MiniToggle(isOn: Binding(get: { visible }, set: { value in
                        withAnimation(.smooth(duration: 0.4)) { settings.setVisible(card, value) }
                    }))
                }
                .frame(height: 32)
            }
        }
    }
}
