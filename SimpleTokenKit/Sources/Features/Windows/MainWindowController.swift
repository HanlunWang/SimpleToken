import AppKit
import SwiftUI
import Core

/// Main window: the full dashboard. Closing hides it (the app stays in the menu bar); can optionally float on top.
/// The window is opaque: content extends under the title bar and the desktop never shows through at the top.
/// Closing drops the SwiftUI view tree (frees memory, no redraws on data changes while hidden); reopening rebuilds it.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let state: AppState

    public init(state: AppState) {
        self.state = state
        let size = NSSize(width: 900, height: 780)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none   // no hard separator under the top bar's soft scroll fade
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.051, green: 0.051, blue: 0.059, alpha: 1)
        window.isOpaque = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 420)   // the layout adapts to width, so the window can shrink small
        window.title = "SimpleToken"
        window.contentView = NSView()
        window.center()
        window.setFrameAutosaveName("SimpleTokenMainWindow")
        super.init()
        window.delegate = self
        applyFloating()
    }

    public func show() {
        applyFloating()
        if !(window.contentView is NSHostingView<DashboardView>) {
            window.contentView = NSHostingView(rootView: DashboardView(state: state))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        state.mainWindowVisible = true
    }

    public func applyFloating() {
        window.level = SettingsStore.shared.floatingWindow ? .floating : .normal
    }

    // Close = hide and drop the view tree, don't quit (stays in the menu bar)
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        sender.contentView = NSView()
        state.mainWindowVisible = false
        MemoryRelief.soon()
        return false
    }

    // Minimised to the Dock also counts as not visible (the view tree is kept for a faster restore)
    public func windowDidMiniaturize(_ notification: Notification) { state.mainWindowVisible = false }
    public func windowDidDeminiaturize(_ notification: Notification) { state.mainWindowVisible = true }
}

/// After dropping a large view tree, return freed-but-held malloc pages to the system (otherwise resident memory doesn't drop)
enum MemoryRelief {
    @MainActor static func soon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))    // let SwiftUI / Core Animation release things first
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
