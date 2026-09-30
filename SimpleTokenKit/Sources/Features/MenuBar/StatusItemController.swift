import AppKit
import SwiftUI
import Core
import DesignSystem

/// Menu bar item: the whole content is drawn as one image (mark + number segments; single line / two-line / ring / bar).
/// Content, style, labels and icon are configured in Settings → Menu Bar.
@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panel: DashboardPanel
    private let state: AppState
    public var onOpenMainWindow: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = DashboardPanel(state: state)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(didClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Data-driven: redraw when content or settings change (identical content is not redrawn)
        observeContinuously { [weak self] in self?.render() }
        // Countdown content ticks every 30 seconds
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if SettingsStore.shared.menuBarEntries.contains(.sessionReset) { self.render() }
            }
        }
    }

    private var ticker: Task<Void, Never>?
    private var lastKey: String?

    private func render() {
        let settings = SettingsStore.shared
        let segments = MenuBarContent.segments(state: state)
        let style = MenuBarRenderer.Style(rawValue: settings.menuBarStyle) ?? .text
        let key = "\(segments)|\(style)|\(settings.menuBarShowIcon)|\(settings.menuBarShowLabels)"
        guard key != lastKey, let button = statusItem.button else { return }
        lastKey = key
        button.image = MenuBarRenderer.image(segments, style: style, showIcon: settings.menuBarShowIcon,
                                             showLabels: settings.menuBarShowLabels)
        button.setAccessibilityLabel(MenuBarContent.accessibilityText(segments))
    }

    @objc private func didClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let wantsPanel = SettingsStore.shared.clickOpensPanel != optionHeld
        if wantsPanel {
            togglePanel()
        } else {
            panel.hide()
            onOpenMainWindow?()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Open Main Window"), action: #selector(menuOpenMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Settings…"), action: #selector(menuOpenSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Refresh Now"), action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit SimpleToken"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil    // detach after use so left-click behaviour is unaffected
    }

    @objc private func menuOpenMain() { onOpenMainWindow?() }
    @objc private func menuOpenSettings() { onOpenSettings?() }
    @objc private func menuRefresh() { state.refreshAll() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else if let button = statusItem.button {
            panel.show(under: button)
        }
    }

    public func hidePanel() {
        panel.hide()
    }
}
