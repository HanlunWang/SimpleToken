import AppKit
import SwiftUI

/// Drop-down panel: a borderless, transparent NSPanel that opens below the menu bar item; a click outside or Esc closes it.
/// The panel ground is a dark translucent wash (a hint of desktop colour shows through) with small glass cards on top.
/// Content is mounted only while open and dropped when closed (no redraws on data changes, no view memory while hidden).
/// When the content height changes (limits arrive, sections toggle) the window follows, its top edge pinned to the menu bar.
@MainActor
public final class DashboardPanel {
    private let panel: NSPanel
    private let state: AppState
    private var host: NSHostingView<QuickPanelView>?
    private var clickMonitors: [Any] = []
    private var keyMonitor: Any?
    /// Panel top edge (screen coordinates) and horizontal centre: stay put as the content grows or shrinks
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    private var screenFrame: NSRect = .zero

    public var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    public init(state: AppState) {
        self.state = state
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 300, height: 400)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    public func show(under button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorTop = buttonFrame.minY - 6
        anchorMidX = buttonFrame.midX
        screenFrame = screen.visibleFrame
        let maxHeight = anchorTop - screen.visibleFrame.minY - 12
        let host = NSHostingView(rootView: QuickPanelView(state: state, maxHeight: maxHeight) { [weak self] size in
            self?.fit(size)
        })
        host.sizingOptions = []
        self.host = host
        panel.contentView = host
        state.panelVisible = true
        fit(host.fittingSize)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// Positions by content size: top edge at the menu bar, centred on the icon, kept on screen horizontally
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var x = anchorMidX - size.width / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        let frame = NSRect(x: x.rounded(), y: (anchorTop - size.height).rounded(), width: size.width.rounded(), height: size.height.rounded())
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    public func hide() {
        removeMonitors()
        guard panel.isVisible else { return }
        state.panelVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.state.panelVisible else { return }
                self.panel.orderOut(nil)
                self.panel.contentView = nil
                self.host = nil
                MemoryRelief.soon()
            }
        })
    }

    // MARK: - Dismiss on outside click

    private func installMonitors() {
        removeMonitors()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.hide() }
            return event
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.hide()
                return nil
            }
            return event
        }
        clickMonitors = [global as Any, local as Any]
        keyMonitor = key
    }

    private func removeMonitors() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
