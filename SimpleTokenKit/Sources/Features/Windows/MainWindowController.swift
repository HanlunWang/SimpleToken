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
    /// The size the user dragged the window to while macOS still had it in a tile (see `windowDidResize`)
    private var resizedInTile: NSRect?
    private var restoringSize = false

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
        Self.dropSavedTile(Self.frameName)
        let saved = Self.savedFrame(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
        // AppKit's restore moves a window saved on another display onto the main one: put it back on its display
        if let saved, window.frame != saved { window.setFrame(saved, display: false) }
        super.init()
        window.delegate = self
        applyFloating()
    }

    private static let frameName = "SimpleTokenMainWindow"

    /// AppKit saves a tiled window's tile (Fill, a half, a quarter) along with its frame and restores it at launch.
    /// A restored tile survives resizing the window by hand, so macOS puts the window back into the tile after
    /// Show Desktop, Stage Manager or Mission Control. Keep the saved size and position; drop the tile.
    private static func dropSavedTile(_ name: String) {
        let key = "NSWindow Frame \(name)"
        guard let saved = UserDefaults.standard.string(forKey: key), let brace = saved.firstIndex(of: "{") else { return }
        UserDefaults.standard.set(saved[..<brace].trimmingCharacters(in: .whitespaces), forKey: key)
    }

    /// The saved frame, when the display it was on is still connected (kept inside that display's visible area)
    private static func savedFrame(_ name: String) -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") else { return nil }
        let n = saved.split(separator: " ").prefix(8).compactMap { Double($0) }
        guard n.count == 8 else { return nil }
        let frame = NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
        let visible = NSRect(x: n[4], y: n[5], width: n[6], height: n[7])
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame == visible }), frame.width > 0, frame.height > 0 else { return nil }
        let area = screen.visibleFrame
        let size = NSSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let origin = NSPoint(x: min(max(frame.minX, area.minX), area.maxX - size.width),
                             y: min(max(frame.minY, area.minY), area.maxY - size.height))
        return NSRect(origin: origin, size: size)
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

    // MARK: Sizes inside a tile
    //
    // macOS keeps a tiled window (Fill, a half…) in its tile even after the user resizes it by hand, and puts it
    // back into the tile after Show Desktop or Stage Manager; no public API takes a window out of its tile.
    // So the size the user dragged to is remembered and restored when the system snaps the window back without
    // anyone asking. Moving the window takes it out of the tile, so a move forgets that size.

    public func windowDidEndLiveResize(_ notification: Notification) {
        resizedInTile = Self.isTiled(window) ? window.frame : nil
    }

    public func windowWillMove(_ notification: Notification) {
        resizedInTile = nil
    }

    public func windowDidResize(_ notification: Notification) {
        guard let target = resizedInTile, !restoringSize, !window.inLiveResize, window.frame != target else { return }
        // A change made in this app (the green button's tile menu) has a click or key press right before it
        if let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 {
            resizedInTile = nil
            return
        }
        // Wait for the system to finish placing the window (Show Desktop moves it off screen and back)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let target = self.resizedInTile, self.window.isVisible, Self.isTiled(self.window),
                  self.window.frame != target, let area = self.window.screen?.visibleFrame,
                  area.contains(self.window.frame), area.contains(target) else { return }
            self.restoringSize = true
            self.window.setFrame(target, display: true, animate: true)
            self.restoringSize = false
        }
    }

    /// Whether macOS has the window in a tile; AppKit records the tile in the window's frame descriptor
    private static func isTiled(_ window: NSWindow) -> Bool {
        window.frameDescriptor.contains("tilingState")
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
