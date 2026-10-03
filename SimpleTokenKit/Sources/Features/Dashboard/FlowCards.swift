import SwiftUI
import AppKit
import Core
import DesignSystem

/// A model's colour on the map and in the flow: its own colour, except in the colour-blind-safe scheme,
/// where only the models with a slot are coloured and the rest are grey like everywhere else
@MainActor
private func modelTint(_ model: String, colors: ModelColors, settings: SettingsStore) -> Color {
    settings.modelColorMode == "ranked" ? colors.groupColor(model) : colors.color(model)
}

// MARK: - Usage map: a treemap of models grouped by vendor

/// Where the tokens went as a map: every model is a tile whose area is its tokens, grouped by vendor
/// (vendors biggest first, models biggest first inside each) and coloured like the model everywhere else.
struct MapCard: View {
    let state: AppState
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @Environment(\.cardSize) private var cardSize
    @State private var flipped = false
    @State private var hovered: String?
    private var entrance = Entrance()

    init(state: AppState, report: RangeReport, colors: ModelColors, exact: Bool, settings: SettingsStore) {
        self.state = state
        self.report = report
        self.colors = colors
        self.exact = exact
        self.settings = settings
    }

    fileprivate struct Tile: Identifiable {
        let id: String
        let name: String
        let vendor: ModelPalette.Vendor
        let tokens: Double
        let cost: Double
        let color: Color
        /// Light tiles take dark text
        let darkInk: Bool
    }

    /// Tiles in drawing order, and the run of tiles each vendor owns
    private var content: (tiles: [Tile], runs: [Range<Int>]) {
        let shares = report.models.filter { $0.tokens > 0 }
        let vendors = Dictionary(grouping: shares) { ModelPalette.vendor($0.key) }
            .map { (vendor: $0.key, shares: $0.value.sorted { $0.tokens > $1.tokens }, total: $0.value.reduce(0) { $0 + $1.tokens }) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.vendor.rawValue < $1.vendor.rawValue }
        var tiles: [Tile] = [], runs: [Range<Int>] = []
        for vendor in vendors {
            let start = tiles.count
            for share in vendor.shares {
                let color = modelTint(share.key, colors: colors, settings: settings)
                tiles.append(Tile(id: share.key, name: colors.name(share.key), vendor: vendor.vendor, tokens: Double(share.tokens),
                                  cost: share.cost, color: color, darkInk: MapLayout.isLight(color)))
            }
            runs.append(start..<tiles.count)
        }
        return (tiles, runs)
    }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.map.localizedName) · Settings"), onHide: { settings.setVisible(.map, false) }, done: { flipped = false }) {
                Text("Each tile is a model, as large as its tokens, next to the other models of its vendor.")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var front: some View {
        let (tiles, runs) = content
        let total = tiles.reduce(0) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.map.localizedName, icon: SettingsStore.Card.map.icon, onSettings: { flipped = true }) {
                if !tiles.isEmpty { Text(verbatim: "\(report.range.localizedLabel) · \(Fmt.tokens(total, exact: exact))") }
            }
            if tiles.isEmpty {
                Spacer(minLength: 0)
                Text("No usage in this range").font(.app(Typo.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                map(tiles, runs: runs, total: total)
                    .frame(maxHeight: .infinity)
                if cardSize != .medium { FactsRow(facts(tiles, runs: runs, total: total)) }
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    private func map(_ tiles: [Tile], runs: [Range<Int>], total: Double) -> some View {
        let values = tiles.map(\.tokens)
        return GeometryReader { geo in
            // Hit-testing uses the settled layout; the canvas draws the one on its way there
            let rects = MapLayout.rects(runs: runs, values: values, in: CGRect(origin: .zero, size: geo.size))
            MapCanvas(values: AnimatableVector(values), reveal: entrance.amount, tiles: tiles, runs: runs,
                      hovered: tiles.firstIndex { $0.id == hovered }, exact: exact)
                .animation(Motion.data, value: values)
                .animation(Motion.hover, value: hovered)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let p) = phase, tip?.scrolling != true, let i = rects.firstIndex(where: { $0.contains(p) }) else {
                        if hovered != nil { hovered = nil }
                        tip?.hide("map")
                        return
                    }
                    let tile = tiles[i]
                    if hovered != tile.id { hovered = tile.id }
                    let origin = geo.frame(in: .named(HoverTip.space)).origin
                    tip?.show("map", key: tile.id, at: CGPoint(x: origin.x + rects[i].midX, y: origin.y + rects[i].minY + 4), glide: true) {
                        tileTip(tile, total: total)
                    }
                }
        }
        .onAppear { entrance.start() }
    }

    /// Models, vendors, and the biggest tile's share (named by its model)
    private func facts(_ tiles: [Tile], runs: [Range<Int>], total: Double) -> [(String, String)] {
        var out = [(L("Models"), String(tiles.count)), (L("Vendors"), String(runs.count))]
        if let top = tiles.max(by: { $0.tokens < $1.tokens }) {
            out.append((top.name, percent(top.tokens / max(1e-9, total))))
        }
        return out
    }

    /// The model, its share and cost, and the tools that used it
    private func tileTip(_ tile: Tile, total: Double) -> some View {
        let tools = state.pairs(for: report).filter { $0.model == tile.id }
        return TipCard(title: tile.name, subtitle: tile.vendor.localizedName, icon: nil, tint: tile.color,
                       value: Fmt.tokens(tile.tokens, exact: exact)) {
            TipRow(color: tile.color, label: L("Share"), value: percent(tile.tokens / max(1e-9, total)))
            TipRow(label: L("Cost"), value: Fmt.money(tile.cost))
            if tile.tokens > 0 {
                TipRow(label: L("Per million tokens"), value: Fmt.money(tile.cost / (tile.tokens / 1e6)))
            }
            if !tools.isEmpty {
                Divider().overlay(Palette.hairline)
                ForEach(tools.prefix(5), id: \.client) { pair in
                    TipRow(color: colors.toolColor(pair.client), label: ModelPalette.toolLabel(pair.client),
                           value: Fmt.tokens(Double(pair.tokens), exact: false),
                           secondary: percent(min(1, Double(pair.tokens) / max(1, tile.tokens))))
                }
            }
        }
    }
}

/// Treemap geometry shared by the canvas (animated values) and the hit-testing (settled values)
private enum MapLayout {
    /// One rectangle per tile: vendors are laid out by their totals, then each vendor's models inside its block.
    /// Tiles of one vendor sit 1.5 pt apart; vendor blocks a little further.
    static func rects(runs: [Range<Int>], values: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: values.count)
        let totals = runs.map { run in run.reduce(0.0) { $0 + max(0, $1 < values.count ? values[$1] : 0) } }
        let blocks = Treemap.layout(totals, in: rect)
        for (run, block) in zip(runs, blocks) where block.width > 3 && block.height > 3 {
            let inner = Treemap.layout(run.map { $0 < values.count ? values[$0] : 0 }, in: block.insetBy(dx: 0.75, dy: 0.75))
            for (i, tile) in zip(run, inner) where i < out.count && tile.width > 1.5 && tile.height > 1.5 {
                out[i] = tile.insetBy(dx: 0.75, dy: 0.75)
            }
        }
        return out
    }

    /// A label cut to the width it has ("gpt-5.3-co…"); nil when not even a few characters fit
    static func fitted(_ string: String, font: Font, color: Color, width: CGFloat, in ctx: GraphicsContext) -> Text? {
        let text = Text(string).font(font).foregroundStyle(color)
        let full = ctx.resolve(text).measure(in: CGSize(width: 2000, height: 100)).width
        guard full > width else { return text }
        let keep = Int(Double(string.count) * Double(width / max(1, full))) - 2
        guard keep >= 3 else { return nil }
        return Text(trimmed(string.prefix(keep)) + "…").font(font).foregroundStyle(color)
    }

    /// A cut-off piece of a name without the separator it would end on ("gpt-5." → "gpt-5")
    static func trimmed(_ piece: Substring) -> String {
        var piece = piece
        while let last = piece.last, "-._ ".contains(last) { piece.removeLast() }
        return String(piece)
    }

    /// Whether a fill is light enough to need dark text (relative luminance of the sRGB components)
    static func isLight(_ color: Color) -> Bool {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.65
    }
}

/// The map itself: tiles morph when the numbers change (the values travel in an `AnimatableVector`)
private struct MapCanvas: View, Animatable {
    var values: AnimatableVector
    /// 0…1: the map fades in when it appears
    var reveal: Double
    let tiles: [MapCard.Tile]
    let runs: [Range<Int>]
    let hovered: Int?
    let exact: Bool

    nonisolated var animatableData: AnimatablePair<AnimatableVector, Double> {
        get { AnimatablePair(values, reveal) }
        set {
            values = newValue.first
            reveal = newValue.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let current = tiles.indices.map { max(0, values[$0]) }
            let rects = MapLayout.rects(runs: runs, values: current, in: CGRect(origin: .zero, size: size))
            let reveal = min(1, max(0, reveal))
            for (i, tile) in tiles.enumerated() {
                let rect = rects[i]
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                let radius = min(4, min(rect.width, rect.height) / 3)
                ctx.cell(rect, tone: Depth.Tone(tile.color), radius: radius, opacity: (hovered == nil || hovered == i ? 1 : 0.62) * reveal)
                if hovered == i {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5), style: .continuous),
                               with: .color(.white), lineWidth: 1)
                }
                // Name and amount, only where a tile has room for them
                guard rect.width >= 54, rect.height >= 30 else { continue }
                var text = ctx
                text.opacity = (hovered == nil || hovered == i ? 1 : 0.7) * reveal
                text.clip(to: Path(rect.insetBy(dx: 3, dy: 2)))
                let primary = tile.darkInk ? Color.black.opacity(0.80) : Ink.primary
                let secondary = tile.darkInk ? Color.black.opacity(0.56) : Ink.secondary
                let roomy = rect.width >= 110 && rect.height >= 48
                let bounds = (rect.minX + 6)...max(rect.minX + 6, rect.maxX - 5)
                let width = rect.width - 11
                if let name = MapLayout.fitted(tile.name, font: .app(roomy ? Typo.body : Typo.small, .semibold), color: primary, width: width, in: text) {
                    text.label(name, at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: .topLeading, within: bounds)
                }
                if let amount = MapLayout.fitted(Fmt.tokens(current[i], exact: exact && rect.width >= 110), font: .num(roomy ? Typo.title : Typo.small, .semibold),
                                                 color: secondary, width: width, in: text) {
                    text.label(amount, at: CGPoint(x: rect.minX + 6, y: rect.minY + (roomy ? 19 : 16)), anchor: .topLeading, within: bounds)
                }
            }
        }
    }
}

// MARK: - Flow: tools into models

/// Which tool used which model: a ribbon from every tool to each model it ran, as thick as the tokens it carried
struct FlowCard: View {
    let state: AppState
    let report: RangeReport
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(\.cardSize) private var cardSize
    @State private var flipped = false

    /// The diagram and what it was built from
    private struct Flow {
        var diagram = Sankey()
        var tools = 0
        var models = 0
        /// Models folded into "Other"
        var folded = 0
        var total = 0.0
        /// The biggest tool → model pair
        var biggest: (tool: String, model: String, tokens: Double)?
        /// Node id → full name (the labels beside the bars are cut to the label column)
        var names: [String: String] = [:]

        func name(_ node: Sankey.Node) -> String { names[node.id] ?? node.name }
    }

    /// Room for the names beside the model bars; the amount follows the name
    private var labelWidth: CGFloat { cardSize == .medium ? 124 : 150 }

    /// A name cut in the middle to the characters the label column has room for
    private func clipped(_ name: String) -> String {
        let limit = max(8, Int((labelWidth - 52) / 5.6))
        guard name.count > limit else { return name }
        let head = (limit - 1) / 2 + (limit - 1) % 2, tail = (limit - 1) / 2
        var end = name.suffix(tail)
        while let first = end.first, "-._ ".contains(first) { end.removeFirst() }
        return MapLayout.trimmed(name.prefix(head)) + "…" + String(end)
    }

    /// Tools on the left (biggest first), the top models on the right with the rest as "Other"
    private func flow(models limit: Int) -> Flow {
        let pairs = state.pairs(for: report)
        var flow = Flow()
        guard !pairs.isEmpty else { return flow }
        var toolTotals: [String: Int] = [:], modelTotals: [String: Int] = [:]
        for pair in pairs {
            toolTotals[pair.client, default: 0] += pair.tokens
            modelTotals[pair.model, default: 0] += pair.tokens
        }
        func ranked(_ totals: [String: Int]) -> [(key: String, value: Int)] {
            totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        }
        let tools = ranked(toolTotals), models = ranked(modelTotals)
        flow.tools = tools.count
        flow.models = models.count
        flow.total = Double(tools.reduce(0) { $0 + $1.value })
        if let top = pairs.first {
            flow.biggest = (ModelPalette.toolLabel(top.client), colors.name(top.model), Double(top.tokens))
        }

        var s = Sankey()
        var toolIndex: [String: Int] = [:], modelIndex: [String: Int] = [:]
        for tool in tools {
            toolIndex[tool.key] = s.nodes.count
            s.nodes.append(Sankey.Node(id: "t:\(tool.key)", column: 0, name: ModelPalette.toolLabel(tool.key), value: Double(tool.value),
                                       color: colors.toolColor(tool.key), logo: BrandLogos.tool(tool.key)))
        }
        // One model past the limit is shown as itself: "Other" would take the same row
        let limit = models.count == limit + 1 ? limit + 1 : limit
        for model in models.prefix(limit) {
            modelIndex[model.key] = s.nodes.count
            let name = colors.name(model.key)
            flow.names["m:\(model.key)"] = name
            s.nodes.append(Sankey.Node(id: "m:\(model.key)", column: 1, name: clipped(name), value: Double(model.value),
                                       color: modelTint(model.key, colors: colors, settings: settings), logo: BrandLogos.model(model.key)))
        }
        let rest = models.dropFirst(limit)
        flow.folded = rest.count
        let other = rest.isEmpty ? nil : s.nodes.count
        if !rest.isEmpty {
            s.nodes.append(Sankey.Node(id: "m:other", column: 1, name: L("Other"), value: Double(rest.reduce(0) { $0 + $1.value }),
                                       color: Palette.other))
        }
        // One ribbon per tool and model; the folded models share one ribbon per tool
        var folded: [Int: Double] = [:]
        for pair in pairs {
            guard let from = toolIndex[pair.client] else { continue }
            if let to = modelIndex[pair.model] {
                s.links.append(Sankey.Link(from: from, to: to, value: Double(pair.tokens)))
            } else {
                folded[from, default: 0] += Double(pair.tokens)
            }
        }
        if let other {
            for (from, value) in folded { s.links.append(Sankey.Link(from: from, to: other, value: value)) }
        }
        s.links.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        flow.diagram = s
        return flow
    }

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.flow.localizedName) · Settings"), onHide: { settings.setVisible(.flow, false) }, done: { flipped = false }) {
                Text("A ribbon runs from each tool to every model it used, as thick as the tokens it carried.")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var front: some View {
        let medium = cardSize == .medium
        // The 2×1 size has room for six rows of labels: five models and "Other"
        let flow = flow(models: medium ? 5 : 6)
        let diagram = flow.diagram
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.flow.localizedName, icon: SettingsStore.Card.flow.icon, onSettings: { flipped = true }) {
                if flow.tools > 0 { Text("\(report.range.localizedLabel) · \(flow.tools) tools") }
            }
            if diagram.links.isEmpty {
                Spacer(minLength: 0)
                Text("No tool and model breakdown in this range").font(.app(Typo.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                SankeyPlot(diagram: diagram, format: ChartAxis.tokens, tipID: "flow", labelWidth: labelWidth,
                           nodeTip: { i in AnyView(nodeTip(flow, i)) }, linkTip: { i in AnyView(linkTip(flow, i)) })
                    // Another range is another diagram: let the ribbons run in again
                    .id(diagram.signature)
                    .transition(.opacity)
                    .frame(maxHeight: .infinity)
                if !medium { facts(flow) }
            }
        }
        .glassCard(padding: WidgetStyle.padding)
    }

    /// Tools, models, and the biggest pair's share of everything. Laid out like `FactsRow`, but the two
    /// counts keep to narrow columns so the pair's names have room.
    private func facts(_ flow: Flow) -> some View {
        let rule = Rectangle().fill(Palette.hairline).frame(width: 1, height: 26).padding(.horizontal, 12)
        return HStack(alignment: .top, spacing: 0) {
            Fact(label: L("Tools"), value: String(flow.tools)).frame(width: 46, alignment: .leading)
            rule
            Fact(label: L("Models"), value: String(flow.models)).frame(width: 46, alignment: .leading)
            if let biggest = flow.biggest {
                rule
                Fact(label: "\(biggest.tool) → \(biggest.model)", value: percent(biggest.tokens / max(1e-9, flow.total)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A tool or a model: its total, its share, and what is at the other end of its ribbons
    @ViewBuilder private func nodeTip(_ flow: Flow, _ i: Int) -> some View {
        let s = flow.diagram
        if s.nodes.indices.contains(i) {
            let node = s.nodes[i]
            let isTool = node.column == 0
            let partners = s.links.filter { isTool ? $0.from == i : $0.to == i }
                .map { (node: s.nodes[isTool ? $0.to : $0.from], value: $0.value) }
                .sorted { $0.value > $1.value }
            let subtitle = node.id == "m:other" ? L("\(flow.folded) models combined") : isTool ? L("Tool") : L("Model")
            TipCard(title: flow.name(node), subtitle: subtitle, icon: nil, tint: node.color, value: Fmt.tokens(node.value, exact: exact)) {
                TipRow(color: node.color, label: L("Share"), value: percent(node.value / max(1e-9, flow.total)))
                if !partners.isEmpty {
                    Divider().overlay(Palette.hairline)
                    ForEach(partners.prefix(7), id: \.node.id) { partner in
                        TipRow(color: partner.node.color, label: flow.name(partner.node), value: Fmt.tokens(partner.value, exact: false),
                               secondary: percent(partner.value / max(1e-9, node.value)))
                    }
                }
            }
        }
    }

    /// One ribbon: tool → model, its tokens and its share of each end
    @ViewBuilder private func linkTip(_ flow: Flow, _ i: Int) -> some View {
        let s = flow.diagram
        if s.links.indices.contains(i) {
            let link = s.links[i]
            let from = s.nodes[link.from], to = s.nodes[link.to]
            let tool = flow.name(from), model = flow.name(to)
            TipCard(title: "\(tool) → \(model)", icon: nil, tint: to.color, value: Fmt.tokens(link.value, exact: exact)) {
                TipRow(color: from.color, label: L("Share of \(tool)"), value: percent(link.value / max(1e-9, from.value)))
                TipRow(color: to.color, label: L("Share of \(model)"), value: percent(link.value / max(1e-9, to.value)))
            }
        }
    }
}
