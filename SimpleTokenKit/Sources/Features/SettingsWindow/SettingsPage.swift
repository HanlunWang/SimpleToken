import SwiftUI
import AppKit
import ServiceManagement
import Core
import DesignSystem

/// Settings tabs (switched in the top bar)
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, menubar, panel, cards, models, limits, data
    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .general: L("General")
        case .menubar: L("Menu Bar")
        case .panel: L("Panel")
        case .cards: L("Widgets")
        case .models: L("Models & Tools")
        case .limits: L("Limits & Alerts")
        case .data: L("Data")
        }
    }
}

/// Settings page: replaces the dashboard inside the main window (no separate window); the top bar switches tabs, one kind of setting at a time.
/// Sections are glass cards with the same look as the dashboard.
struct SettingsPage: View {
    let state: AppState
    let compact: Bool
    let scroll: ScrollTracker
    @Bindable private var settings = SettingsStore.shared
    @State private var showAllModels = false

    var body: some View {
        let colors = state.modelColors
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                switch SettingsTab(rawValue: state.settingsTabKey) ?? .general {
                case .general: general
                case .menubar: menuBar
                case .panel: panel
                case .cards: cards
                case .models:
                    models(colors)
                    tools(colors)
                case .limits:
                    limits
                    alerts
                case .data: data
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, compact ? 12 : 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            scroll.settingsTop = y
        }
    }

    // MARK: General

    private var general: some View {
        SettingsSection(L("General"), icon: "gearshape") {
            SettingsRow(L("Token numbers"), detail: L("Axis ticks are always short")) {
                GlassSegmented([(false, L("Short \(Fmt.short(4_959_084_551))")), (true, L("Exact \(Fmt.exact(4_959_084_551))"))],
                               selection: $settings.exactNumbers)
            }
            SettingsRow(L("Main metric"), detail: L("Used by the main chart, bar charts and stat tiles")) {
                GlassSegmented(UsageMetric.allCases.map { ($0, $0.localizedLabel) }, selection: $settings.metric)
            }
            SettingsRow(L("Keep main window on top")) {
                MiniToggle(isOn: Binding(get: { settings.floatingWindow },
                                         set: { settings.floatingWindow = $0; state.applyWindowSettings?() }))
            }
            LaunchAtLoginRow()
            SettingsRow(L("Quit"), detail: L("The menu bar icon goes away and usage is no longer collected")) {
                Button("Quit SimpleToken") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }

    // MARK: Menu bar

    private var menuBar: some View {
        SettingsSection(L("Menu Bar"), icon: "menubar.rectangle", footer: L("With nothing selected, only the icon is shown. ⌥-click the menu bar icon to open the other view; right-click to refresh or quit.")) {
            SettingsRow(L("Preview")) { MenuBarPreview(state: state) }
            SettingsRow(L("Items"), detail: L("Shown left to right; use the arrows to reorder"), vertical: true) {
                OrderedListEditor(options: SettingsStore.MenuBarItem.allCases.map { ($0.rawValue, $0.localizedName) },
                                  selected: $settings.menuBarItems, emptyText: L("Icon only"))
            }
            SettingsRow(L("Style"), detail: L("Each style drawn with your current items"), vertical: true) {
                MenuBarStyleGallery(state: state)
            }
            SettingsRow(L("Show labels"), detail: settings.menuBarStyle == "stacked" ? L("The two-line style always shows labels") : L("e.g. “5h” or “Today” before the value")) {
                MiniToggle(isOn: $settings.menuBarShowLabels).disabled(settings.menuBarStyle == "stacked")
            }
            SettingsRow(L("Pace and projection"), detail: L("Rings and bars mark where even use would be by now, and fade on to where the window is heading by its reset")) {
                MiniToggle(isOn: $settings.menuBarShowPace)
                    .disabled(!["ring", "rings", "bar"].contains(settings.menuBarStyle))
            }
            SettingsRow(L("Show SimpleToken icon")) {
                MiniToggle(isOn: $settings.menuBarShowIcon).disabled(settings.menuBarItems.isEmpty)
            }
            SettingsRow(L("Limit numbers")) {
                GlassSegmented([(true, L("Used")), (false, L("Left"))], selection: $settings.limitShowUsed)
            }
            SettingsRow(L("Turn red near the limit"), detail: L("Numbers and rings turn red at \(Int(settings.alertThresholds.max() ?? 80))% used (set the threshold in Limits & Alerts)")) {
                MiniToggle(isOn: $settings.menuBarAlertColor)
            }
            SettingsRow(L("Clicking the icon opens")) {
                GlassSegmented([(true, L("Panel")), (false, L("Main window"))], selection: $settings.clickOpensPanel)
            }
        }
    }

    // MARK: Quick panel

    private var panel: some View {
        SettingsSection(L("Panel"), icon: "rectangle.topthird.inset.filled",
                        footer: L("The panel that drops down from the menu bar icon. It scrolls when the content is taller than the screen.")) {
            SettingsRow(L("Sections"), detail: L("Shown top to bottom; use the arrows to reorder"), vertical: true) {
                OrderedListEditor(options: SettingsStore.PanelSection.allCases.map { ($0.rawValue, $0.localizedName) },
                                  selected: $settings.panelSections, emptyText: L("Only the header row is shown"))
            }
            SettingsRow(L("Panel width")) {
                GlassSegmented([(320, L("Compact")), (340, L("Standard")), (380, L("Wide"))], selection: $settings.panelWidth)
            }
            SettingsRow(L("Limit style")) {
                GlassSegmented([("rings", L("Rings")), ("bars", L("Bars"))], selection: $settings.panelLimitStyle)
            }
            SettingsRow(L("Show reset times")) { MiniToggle(isOn: $settings.panelShowResets) }
            SettingsRow(L("Today’s trend")) {
                GlassSegmented([("cumulative", L("Cumulative line")), ("bars", L("Hourly bars"))], selection: $settings.panelTodayStyle)
            }
            SettingsRow(L("Models / tools shown")) {
                GlassSegmented([(3, L("3 rows")), (4, L("4 rows")), (6, L("6 rows"))], selection: $settings.panelListCount)
            }
        }
    }

    // MARK: Models

    private func models(_ colors: ModelColors) -> some View {
        SettingsSection(L("Models"), icon: "cpu",
                        footer: L("With vendor colors, models from the same vendor use shades of one hue (Claude terracotta, OpenAI teal, Google indigo); the color-blind safe scheme colors only the top three models by usage. Click a swatch to change its color; models switched off are left out of every statistic.")) {
            SettingsRow(L("Color scheme")) {
                GlassSegmented([("vendor", L("By vendor")), ("ranked", L("Color-blind safe"))], selection: $settings.modelColorMode)
            }
            SettingsRow(L("Models shown separately"), detail: L("The rest are grouped as “Other” in charts")) {
                Stepper("\(settings.separateModels) models", value: $settings.separateModels, in: 2...8)
                    .font(.app(Typo.body)).controlSize(.small)
                    .disabled(settings.modelColorMode == "ranked")
            }
            let all = state.history.catalog.models.filter { !$0.key.lowercased().contains("synthetic") }
            // By default list only the top 8 by usage plus excluded / recoloured / aliased ones; the rest are collapsed
            let pinned = all.filter { settings.excludedModels.contains($0.key) || settings.modelColorOverrides[$0.key] != nil || settings.modelAliases[$0.key] != nil }
            let shown = showAllModels ? all : all.filter { e in all.prefix(8).contains(e) || pinned.contains(e) }
            ForEach(shown) { entry in
                ModelRow(entry: entry, colors: colors, settings: settings)
            }
            HStack {
                if all.count > shown.count || showAllModels {
                    Button(showAllModels ? L("Show Fewer") : L("Show All \(all.count) Models")) {
                        withAnimation(.smooth) { showAllModels.toggle() }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.app(Typo.body))
                }
                Spacer()
                Button("Reset Colors") { withAnimation(.smooth) { settings.modelColorOverrides = [:] } }
                    .disabled(settings.modelColorOverrides.isEmpty)
                Button("Clear All Aliases") { settings.modelAliases = [:] }
                    .disabled(settings.modelAliases.isEmpty)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    // MARK: Tools

    private func tools(_ colors: ModelColors) -> some View {
        SettingsSection(L("Tools"), icon: "hammer", footer: L("Tools switched off are left out of all statistics along with their models (limits are unaffected).")) {
            ForEach(state.history.catalog.clients) { entry in
                SettingsRow(ModelPalette.toolLabel(entry.key),
                            detail: L("\(Fmt.tokens(Double(entry.tokens), exact: false)) all time · last used \(Fmt.shortDate(entry.lastSeen))")) {
                    HStack(spacing: 10) {
                        EntityMark(logo: BrandLogos.tool(entry.key), color: colors.toolColor(entry.key), size: 15)
                        ColorPicker("", selection: Binding(
                            get: { colors.toolColor(entry.key) },
                            set: { settings.toolColorOverrides[entry.key] = $0.hexString }
                        ), supportsOpacity: false).labelsHidden()
                        if settings.toolColorOverrides[entry.key] != nil {
                            Button { settings.toolColorOverrides.removeValue(forKey: entry.key) } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Restore default color")
                        }
                        MiniToggle(isOn: Binding(
                            get: { !settings.excludedClients.contains(entry.key) },
                            set: { if $0 { settings.excludedClients.remove(entry.key) } else { settings.excludedClients.insert(entry.key) } }
                        ))
                    }
                }
            }
        }
    }

    // MARK: Widgets

    private var cards: some View {
        SettingsSection(L("Widgets"), icon: "square.grid.2x2",
                        footer: L("Position: drag a widget on the dashboard, or use the arrows here. Size: small 1×1, medium 2×1, large 2×2, wide 4×2; wider windows gain columns while widgets keep roughly the same size. The settings button at a widget’s top right flips it over to its own options.")) {
            ForEach(settings.orderedCards) { card in
                let list = settings.orderedCards
                let visible = settings.isVisible(card)
                SettingsRow(card.localizedName) {
                    HStack(spacing: 8) {
                        CardSizePicker(card: card)
                            .disabled(!visible).opacity(visible ? 1 : 0.35)
                        ReorderButtons(canUp: list.first != card, canDown: list.last != card) { delta in
                            withAnimation(.smooth) { settings.moveCard(card, by: delta) }
                        }
                        MiniToggle(isOn: Binding(get: { visible }, set: { settings.setVisible(card, $0) }))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Reset Layout Only") { withAnimation(.smooth) { settings.resetLayout() } }
                    .controlSize(.small)
                Button("Reset All Widget Settings") { withAnimation(.smooth) { settings.resetCardOptions() } }
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Limits

    private var limits: some View {
        SettingsSection(L("Limits"), icon: "gauge.with.dots.needle.33percent") {
            SettingsRow(L("Numbers show")) {
                GlassSegmented([(true, L("Used")), (false, L("Left"))], selection: $settings.limitShowUsed)
            }
            ForEach(LimitProvider.allCases, id: \.self) { p in
                SettingsRow(L("Show \(p.displayName)"), detail: statusText(p)) {
                    MiniToggle(isOn: Binding(
                        get: { !settings.hiddenLimitProviders.contains(p.rawValue) },
                        set: { if $0 { settings.hiddenLimitProviders.remove(p.rawValue) } else { settings.hiddenLimitProviders.insert(p.rawValue) } }
                    ))
                }
            }
            ClaudeCredentialRow(limits: state.limits)
            SettingsRow(L("Per-model extra limits")) { MiniToggle(isOn: $settings.limitShowModelBuckets) }
            SettingsRow(L("Even-pace line")) { MiniToggle(isOn: $settings.limitShowPace) }
            SettingsRow(L("Limit data"), detail: L("Refreshes automatically every 5 minutes")) {
                Button("Refresh Now") { state.limits.refreshNow() }.controlSize(.small)
            }
        }
    }

    // MARK: Alerts

    private var alerts: some View {
        SettingsSection(L("Alerts"), icon: "bell", footer: L("Each limit window (session, weekly…) notifies once per threshold per period. The menu bar turns red at the highest threshold.")) {
            SettingsRow(L("Thresholds"), detail: L("Alert when usage reaches these values"), vertical: true) {
                ThresholdChips(selected: $settings.alertThresholds)
            }
            NotificationToggleRow()
        }
    }

    private func statusText(_ p: LimitProvider) -> String {
        let snapshot = p == .claude ? state.limits.claude : state.limits.codex
        guard let snapshot else { return L("Not read yet") }
        return "\(snapshot.accountLabel) · \(LimitsCard.ago(snapshot.updatedAt))"
    }

    // MARK: Data

    private var data: some View {
        let daily = state.history.daily
        return SettingsSection(L("Data"), icon: "externaldrive", footer: L("All data stays on this Mac: usage comes from tokscale scanning local logs, and intraday data is read directly from Claude Code session logs (timestamps, models and token counts only, never conversation content).")) {
            SettingsRow(L("Today’s usage refresh"), detail: L("Refreshes when logs change; this is the minimum interval between scans. Shorter is more current but uses more power (each scan takes about 1 s of CPU).")) {
                GlassSegmented([15, 30, 60, 120].map { ($0, Fmt.seconds($0)) }, selection: $settings.liveRefreshSeconds)
            }
            SettingsRow(L("Full rescan"), detail: L("Rescans this month and all time to correct numbers other than today’s")) {
                GlassSegmented([10, 15, 30].map { ($0, Fmt.seconds($0 * 60)) }, selection: $settings.fullRefreshMinutes)
            }
            SettingsRow(L("Other data"), detail: L("Limits every 5 minutes (plus a refresh 30 s after a window resets) · intraday every minute · daily history every 15 minutes; live refresh pauses while both the window and the panel are closed")) {
                Button("Refresh All Now") { state.refreshAll() }.controlSize(.small)
            }
            SettingsRow(L("History"), detail: daily.first.map { L("Since \($0.date), \(daily.count) days") } ?? L("No records yet")) {
                Text("\(daily.count) days").font(.app(Typo.body)).foregroundStyle(.secondary)
            }
            SettingsRow(L("Intraday data"), detail: L("Claude Code session logs, kept for 90 days")) {
                Text("\(state.intraday.snapshot.days.count) days").font(.app(Typo.body)).foregroundStyle(.secondary)
            }
            SettingsRow(L("Data folder"), detail: AppPaths.appSupport.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.appSupport]) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Components

/// Settings section: glass card + title + rows + footer
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.app(Typo.body, .semibold)).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title).font(.app(Typo.title + 1, .semibold))
            }
            .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Divider().overlay(Palette.hairline) }
                        row.padding(.vertical, 6)
                    }
                }
            }
            if let footer {
                Text(footer).font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .glassCard(padding: 16, radius: 18)
    }
}

/// Settings row: title on the left (with optional detail), control on the right
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    /// Control always below the title (for wrapping chip groups: on one line their wrapped height can’t be measured)
    var vertical = false
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, vertical: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.vertical = vertical
        self.control = control()
    }

    var body: some View {
        if vertical {
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            row
        }
    }

    private var row: some View {
        // Side by side when wide; when the control is too wide (narrow window / long segments) it moves below the title; the detail text may wrap
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                titleBlock
                Spacer(minLength: 8)
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                titleBlock
                control
            }
        }
        .frame(minHeight: 26)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.app(Typo.body + 1)).lineLimit(1)
            if let detail {
                Text(detail).font(.app(Typo.small)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
    }
}

/// Move up / down
struct ReorderButtons: View {
    let canUp: Bool
    let canDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 18) }
                .disabled(!canUp)
            Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 18) }
                .disabled(!canDown)
        }
        .buttonStyle(.plain)
        .font(.app(Typo.small, .semibold))
        .foregroundStyle(.secondary)
    }
}

/// Multi-select chips (selection order is display order; at least one stays selected by default)
struct FlowChips: View {
    let options: [(String, String)]
    @Binding var selected: [String]
    var allowsEmpty = false

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(options, id: \.0) { key, label in
                let index = selected.firstIndex(of: key)
                Button {
                    withAnimation(.smooth) {
                        if let index { if selected.count > 1 || allowsEmpty { selected.remove(at: index) } } else { selected.append(key) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(index.map { "\($0 + 1)" } ?? "+")
                            .font(.app(Typo.axis, .bold)).monospacedDigit()
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color.white.opacity(index == nil ? 0.06 : 0.2)))
                        Text(label).font(.app(Typo.small)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .foregroundStyle(index == nil ? .secondary : .primary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(index == nil ? 0.03 : 0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Model row: swatch (editable) + alias field + vendor / usage + include in statistics
struct ModelRow: View {
    let entry: DailyHistoryArchive.CatalogEntry
    let colors: ModelColors
    @Bindable var settings: SettingsStore

    var body: some View {
        let included = !settings.excludedModels.contains(entry.key)
        HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { colors.color(entry.key) },
                set: { settings.modelColorOverrides[entry.key] = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            EntityMark(logo: BrandLogos.model(entry.key), color: colors.color(entry.key), size: 15)
            VStack(alignment: .leading, spacing: 1) {
                TextField(ModelPalette.shortName(entry.key), text: Binding(
                    get: { settings.modelAliases[entry.key] ?? "" },
                    set: { settings.modelAliases[entry.key] = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: Typo.body + 1, design: .monospaced))
                Text("\(entry.key) · \(ModelPalette.vendor(entry.key).localizedName) · \(Fmt.tokens(Double(entry.tokens), exact: false)) · last used \(Fmt.shortDate(entry.lastSeen))")
                    .font(.app(Typo.small)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .opacity(included ? 1 : 0.5)
            Spacer(minLength: 8)
            if settings.modelColorOverrides[entry.key] != nil {
                Button { settings.modelColorOverrides.removeValue(forKey: entry.key) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Restore automatic color")
            }
            MiniToggle(isOn: Binding(
                get: { included },
                set: { if $0 { settings.excludedModels.remove(entry.key) } else { settings.excludedModels.insert(entry.key) } }
            ))
            .help("Include in statistics")
        }
        .frame(minHeight: 30)
    }
}

/// Launch at login (SMAppService: the login item is managed by the system and users can also turn it off in System Settings)
struct LaunchAtLoginRow: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        SettingsRow(L("Open at login"), detail: error ?? (SMAppService.mainApp.status == .requiresApproval ? L("Needs approval in System Settings → Login Items") : nil)) {
            MiniToggle(isOn: Binding(get: { enabled }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    self.error = L("Couldn’t change: \(error.localizedDescription)")
                }
                enabled = SMAppService.mainApp.status == .enabled
            }))
        }
    }
}

/// Menu bar preview: drawn once on a dark and once on a light menu bar (same renderer as the status item)
struct MenuBarPreview: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let segments = MenuBarContent.segments(state: state)
        let image = MenuBarRenderer.image(segments, style: MenuBarRenderer.Style(rawValue: settings.menuBarStyle) ?? .text,
                                          showIcon: settings.menuBarShowIcon, showLabels: settings.menuBarShowLabels, height: 24)
        HStack(spacing: 6) {
            strip(image, dark: true)
            strip(image, dark: false)
        }
    }

    private func strip(_ image: NSImage, dark: Bool) -> some View {
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(dark ? Color(white: 0.16) : Color(white: 0.9)))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Every menu bar style drawn with the current items on a dark menu bar strip; a click picks one
struct MenuBarStyleGallery: View {
    let state: AppState
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let segments = MenuBarContent.segments(state: state)
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(MenuBarRenderer.Style.allCases, id: \.self) { style in
                let image = MenuBarRenderer.image(segments, style: style, showIcon: settings.menuBarShowIcon,
                                                  showLabels: settings.menuBarShowLabels, height: 24)
                let selected = settings.menuBarStyle == style.rawValue
                Button {
                    settings.menuBarStyle = style.rawValue
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(nsImage: image)
                            .renderingMode(image.isTemplate ? .template : .original)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.16)))
                            .environment(\.colorScheme, .dark)
                        Text(style.localizedName)
                            .font(.app(Typo.small, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.white.opacity(0.35) : Palette.hairline, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.localizedName)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Ordered multi-select: selected items are listed in order (move up / down, remove); the rest are picked from “Add”
struct OrderedListEditor: View {
    let options: [(String, String)]
    @Binding var selected: [String]
    var emptyText = L("Nothing selected")

    var body: some View {
        let names = Dictionary(options, uniquingKeysWith: { a, _ in a })
        let rest = options.filter { !selected.contains($0.0) }
        VStack(alignment: .leading, spacing: 4) {
            if selected.isEmpty {
                Text(emptyText).font(.app(Typo.body)).foregroundStyle(.tertiary).frame(height: 26)
            }
            ForEach(Array(selected.enumerated()), id: \.element) { i, key in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.app(Typo.axis, .bold)).monospacedDigit()
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                    Text(names[key] ?? key).font(.app(Typo.body + 1)).lineLimit(1)
                    Spacer(minLength: 8)
                    ReorderButtons(canUp: i > 0, canDown: i < selected.count - 1) { delta in
                        withAnimation(.smooth(duration: 0.25)) { selected.swapAt(i, i + delta) }
                    }
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { selected.removeAll { $0 == key } }
                    } label: {
                        Image(systemName: "minus.circle").font(.app(Typo.body)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest, id: \.0) { key, name in
                        Button(name) { withAnimation(.smooth(duration: 0.25)) { selected.append(key) } }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// Alert thresholds: a few common values, click to toggle
struct ThresholdChips: View {
    @Binding var selected: [Double]
    private static let choices: [Double] = [50, 60, 70, 80, 90, 95]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Self.choices, id: \.self) { value in
                let on = selected.contains(value)
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        if on { selected.removeAll { $0 == value } } else { selected = (selected + [value]).sorted() }
                    }
                } label: {
                    Text("\(Int(value))%")
                        .font(.app(Typo.body, .medium)).monospacedDigit()
                        .padding(.horizontal, 10).frame(height: 24)
                        .foregroundStyle(on ? .primary : .secondary)
                        .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.05)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// System notification toggle: asks for permission when turned on; if denied, switches back off and explains
struct NotificationToggleRow: View {
    @Bindable private var settings = SettingsStore.shared
    @State private var note: String?

    var body: some View {
        SettingsRow(L("System notifications"), detail: note ?? (LimitNotifier.available ? L("Posts a notification when a limit crosses a threshold") : L("Notifications aren’t supported when running this way"))) {
            MiniToggle(isOn: Binding(get: { settings.limitNotifications }, set: { on in
                settings.limitNotifications = on
                note = nil
                guard on else { return }
                Task {
                    if await !LimitNotifier.requestAuthorization() {
                        settings.limitNotifications = false
                        note = L("Notifications weren’t allowed. Turn them on in System Settings → Notifications → SimpleToken.")
                    }
                }
            }))
            .disabled(!LimitNotifier.available)
        }
    }
}

/// Claude credential: paste the claude.ai sessionKey. It is written only to the local credentials file; the saved value is never shown in the UI.
struct ClaudeCredentialRow: View {
    let limits: LimitsStore
    @State private var input = ""
    @State private var configured = !(CredentialStore.load().claudeWebCookie ?? "").isEmpty
    @State private var message: String?

    var body: some View {
        SettingsRow(L("Claude credential"), detail: detail, vertical: true) {
            HStack(spacing: 8) {
                SecureField("Paste sessionKey (sk-ant-…)", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(save)
                Button(configured ? L("Replace") : L("Save"), action: save)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if configured {
                    Button("Clear") {
                        var file = CredentialStore.load()
                        file.claudeWebCookie = nil
                        CredentialStore.save(file)
                        configured = false
                        message = L("Cleared")
                        limits.refreshNow()
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var detail: String {
        if let message { return message }
        let how = L("Sign in to claude.ai in a browser → Developer Tools → Application → Cookies → sessionKey. Stored only on this Mac.")
        return configured ? L("Saved (\(status)). Paste a new one to switch accounts or when it expires.") : L("Not set up, so Claude limits can’t be read.") + " " + how
    }

    private var status: String {
        switch limits.claudeStatus {
        case .ok: L("working")
        case .probing: L("reading")
        case .failed: L("last read failed, it may have expired")
        default: L("waiting to read")
        }
    }

    private func save() {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("sessionKey=") { value.removeFirst("sessionKey=".count) }
        guard value.hasPrefix("sk-ant-") else {
            message = L("That doesn’t look like a sessionKey (it should start with sk-ant-), so it wasn’t saved.")
            return
        }
        var file = CredentialStore.load()
        file.claudeWebCookie = value
        CredentialStore.save(file)
        input = ""
        configured = true
        message = nil
        limits.refreshNow()
    }
}
