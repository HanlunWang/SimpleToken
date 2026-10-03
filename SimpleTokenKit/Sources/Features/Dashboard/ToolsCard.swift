import SwiftUI
import Core
import DesignSystem

// MARK: - Tool share

/// Which tools the tokens went through: a share bar, the ranked tools with their logos, and at the large
/// size the range's days stacked by tool.
struct ToolsCard: View {
    let report: RangeReport
    let catalog: [DailyHistoryArchive.CatalogEntry]
    let colors: ModelColors
    let exact: Bool
    @Bindable var settings: SettingsStore
    @Environment(HoverTip.self) private var tip: HoverTip?
    @State private var flipped = false
    @State private var hovered: String?
    @Environment(\.cardSize) private var cardSize

    var body: some View {
        FlipCard(flipped: flipped) {
            front
        } back: {
            CardBack(title: L("\(SettingsStore.Card.tools.localizedName) · Settings"), onHide: { settings.setVisible(.tools, false) }, done: { flipped = false }) {
                Text("Tools turned off are left out of every stat.").font(.app(Typo.small)).foregroundStyle(.tertiary)
                ForEach(catalog) { entry in
                    OptionRow(ModelPalette.toolLabel(entry.key)) {
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(
                                get: { colors.toolColor(entry.key) },
                                set: { settings.toolColorOverrides[entry.key] = $0.hexString }
                            ), supportsOpacity: false).labelsHidden().controlSize(.mini)
                            MiniToggle(isOn: Binding(
                                get: { !settings.excludedClients.contains(entry.key) },
                                set: { if $0 { settings.excludedClients.remove(entry.key) } else { settings.excludedClients.insert(entry.key) } }
                            ))
                        }
                    }
                }
            }
        }
    }

    private var front: some View {
        let all = max(1, report.clients.reduce(0) { $0 + $1.tokens })
        let shown = report.clients.filter { Double($0.tokens) / Double(all) >= 0.0005 }
        let total = max(1, shown.reduce(0) { $0 + $1.tokens })
        let bar = SegmentBar(parts: shown.map { (key: $0.key, value: Double($0.tokens), color: colors.toolColor($0.key)) },
                             height: cardSize == .large ? 8 : 6, tipID: "tools.bar") { key in
            AnyView(Group {
                if let s = shown.first(where: { $0.key == key }) { toolTip(s, total: total) }
            })
        }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(SettingsStore.Card.tools.localizedName, icon: SettingsStore.Card.tools.icon, onSettings: { flipped = true }) {
                if cardSize != .small { Text("\(report.range.localizedLabel) · \(shown.count) tools") }
            }
            switch cardSize {
            case .small:
                // 1×1: the most used tool + its share, with a share bar of all tools at the bottom
                if let top = shown.first {
                    HStack(spacing: 6) {
                        EntityMark(logo: BrandLogos.tool(top.key), color: colors.toolColor(top.key), size: 15)
                        Text(ModelPalette.toolLabel(top.key)).font(.app(Typo.body, .medium)).lineLimit(1)
                    }
                    BigNumber(percent(Double(top.tokens) / Double(total)), size: WidgetStyle.number(.small))
                    Spacer(minLength: 0)
                    bar
                    Text(shown.count > 1 ? L("+\(shown.count - 1) more tools") : L("The only tool used"))
                        .font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    Text("No usage in this range").font(.app(Typo.small)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            case .medium:
                bar
                rows(shown.prefix(3), total: total)
                Spacer(minLength: 0)
            default:
                // 2×2: total, the ranked tools, the range's days stacked by tool, facts
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(Fmt.tokens(Double(all), exact: exact), size: WidgetStyle.number(.large) - 2, value: Double(all))
                    Text("\(shown.count) tools with usage").font(.app(Typo.small)).foregroundStyle(.tertiary)
                }
                rows(shown.prefix(3), total: total)
                chart(shown).frame(maxHeight: .infinity)
                FactsRow(facts(shown, total: total))
            }
        }
        .glassCard(padding: WidgetStyle.padding + (cardSize == .large ? 2 : 0))
    }

    /// Ranked rows: logo, name, a bar against the biggest tool, tokens and share
    private func rows(_ list: ArraySlice<RangeReport.Share>, total: Int) -> some View {
        let top = Double(max(1, list.first?.tokens ?? 1))
        return VStack(spacing: 0) {
            ForEach(Array(list)) { s in
                HStack(spacing: 8) {
                    EntityMark(logo: BrandLogos.tool(s.key), color: colors.toolColor(s.key), size: 13)
                    Text(ModelPalette.toolLabel(s.key)).font(.app(Typo.body)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 72, alignment: .leading)
                    DepthBar(fraction: Double(s.tokens) / top, tint: colors.toolColor(s.key), height: 5)
                        .frame(maxWidth: .infinity)
                    Text(Fmt.tokens(Double(s.tokens), exact: exact)).font(.num(Typo.small, .medium)).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                    Text(percent(Double(s.tokens) / Double(total))).font(.num(Typo.body, .semibold)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .monospacedDigit()
                .frame(height: 22)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered == s.key ? 0.06 : 0)))
                .contentShape(Rectangle())
                .dashboardHover { p in hover(p == nil ? nil : s, total: total, at: p) }
            }
        }
        .animation(Motion.hover, value: hovered)
    }

    /// The range's days (weeks for long ranges) stacked by tool
    private func chart(_ shown: [RangeReport.Share]) -> some View {
        let keys = shown.map(\.key)
        let size = report.weeklyBuckets ? 7 : 1
        let groups = stride(from: 0, to: report.days.count, by: size).map { Array(report.days[$0..<min(report.days.count, $0 + size)]) }
        let labelled = BarLabels.keep(count: groups.count, limit: 4)
        let bars = groups.enumerated().map { i, g in
            BarChart.Bar(id: g[0].date, segments: keys.map { k in g.reduce(0.0) { $0 + Double($1.byClient[k] ?? 0) } },
                         label: labelled(i) ? (i == groups.count - 1 && !report.weeklyBuckets ? L("Today") : Fmt.shortDate(g[0].date)) : nil)
        }
        return BarChart(bars: bars, colors: keys.map(colors.toolColor), tipID: "tools.bars", tip: { i in AnyView(bucketTip(groups[i], keys: keys)) })
            .animation(Motion.data, value: "\(report.range.rawValue)|\(keys.joined(separator: ","))")
    }

    /// One column of the chart: the day's full breakdown, or a week's tools
    @ViewBuilder
    private func bucketTip(_ days: [DailyHistoryArchive.DaySummary], keys: [String]) -> some View {
        if days.count == 1 {
            DayDetailTip(day: days[0], colors: colors, exact: exact)
        } else {
            let parts = keys.map { k in (k, days.reduce(0.0) { $0 + Double($1.byClient[k] ?? 0) }) }.filter { $0.1 > 0 }
            let total = parts.reduce(0) { $0 + $1.1 }
            TipCard(title: L("Week of \(Fmt.shortDate(days[0].date))"), value: Fmt.tokens(total, exact: exact)) {
                if parts.isEmpty {
                    Text("No usage this week").font(.app(Typo.small)).foregroundStyle(.tertiary)
                } else {
                    TipBar(parts: parts.map { (colors.toolColor($0.0), $0.1) })
                    ForEach(parts, id: \.0) { k, v in
                        TipRow(color: colors.toolColor(k), label: ModelPalette.toolLabel(k), value: Fmt.tokens(v, exact: false),
                               secondary: percent(v / max(1e-9, total)))
                    }
                }
            }
        }
    }

    private func facts(_ shown: [RangeReport.Share], total: Int) -> [(String, String)] {
        let active = report.days.filter { d in d.byClient.values.contains { $0 > 0 } }.count
        var out: [(String, String)] = []
        if let top = shown.first {
            out.append((L("Top tool"), ModelPalette.toolLabel(top.key)))
            out.append((L("Share"), percent(Double(top.tokens) / Double(total))))
        }
        out.append((L("Days with usage"), "\(active) / \(report.days.count)"))
        return out
    }

    /// A tool's readout: tokens and share, how often it was used, its models (by vendor)
    private func toolTip(_ s: RangeReport.Share, total: Int) -> some View {
        let days = report.days.filter { ($0.byClient[s.key] ?? 0) > 0 }
        let models = report.days.reduce(into: [String: Int]()) { acc, d in
            // Daily summaries have no tool × model split: approximate by the model's vendor (Claude → Claude Code, OpenAI → Codex)
            for (m, t) in d.byModel where Self.belongs(model: m, to: s.key) { acc[m, default: 0] += t }
        }.sorted { $0.value > $1.value }
        let entry = catalog.first { $0.key == s.key }
        return TipCard(title: ModelPalette.toolLabel(s.key), subtitle: report.range.localizedLabel,
                       value: Fmt.tokens(Double(s.tokens), exact: exact)) {
            TipRow(color: colors.toolColor(s.key), label: L("Share"), value: percent(Double(s.tokens) / Double(total)))
            TipRow(label: L("Days with usage"), value: "\(days.count) / \(report.days.count)")
            if let last = days.last { TipRow(label: L("Last used"), value: Fmt.shortDate(last.date)) }
            if let entry { TipRow(label: L("All-time total"), value: Fmt.tokens(Double(entry.tokens), exact: false)) }
            if !models.isEmpty {
                Divider().overlay(Palette.hairline)
                ForEach(models.prefix(4), id: \.key) { m, t in
                    TipRow(color: colors.color(m), label: colors.name(m), value: Fmt.tokens(Double(t), exact: false))
                }
            }
        }
    }

    private func hover(_ s: RangeReport.Share?, total: Int, at p: CGPoint?) {
        let tipID = "tools"
        guard let s, let p else { hovered = nil; tip?.hide(tipID); return }
        hovered = s.key
        tip?.show(tipID, key: s.key, at: p) { toolTip(s, total: total) }
    }

    static func belongs(model: String, to client: String) -> Bool {
        switch client {
        case "claude": ModelPalette.vendor(model) == .anthropic
        case "codex": ModelPalette.vendor(model) == .openai
        default: false
        }
    }
}
