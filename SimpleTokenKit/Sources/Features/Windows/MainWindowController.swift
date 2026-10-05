import AppKit
import SwiftUI
import Core

/// Main window: the full dashboard. Closing hides it (the app stays in the menu bar); can optionally float on top.
/// The window is opaque: content extends under the title bar and the desktop never shows through at the top.
/// Closing drops the SwiftUI view tree (frees memory, no redraws on data changes while hidden); reopening rebuilds it.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow
    private let state: AppState
    /// The tile and frame the window had when a live resize began
    private var resizeStart: (tile: String?, frame: NSRect)?

    public init(state: AppState) {
        self.state = state
        window = Self.makeWindow()
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

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 900, height: 780)),
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
        return window
    }

    private static let frameName = "SimpleTokenMainWindow"

    /// AppKit saves a tiled window's tile (Fill, a half, a quarter) along with its frame and restores it at launch,
    /// also when the saved frame is no longer the tile's size. Keep the saved size and position; drop the tile.
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

    // MARK: Leaving a tile
    //
    // macOS keeps a tiled window (Fill, a half…) in its tile after the user resizes it by hand, and snaps it back to
    // the tile's size after Show Desktop, Stage Manager or Mission Control; every app's windows do this. No public
    // API takes a window out of its tile, but a new window is in none. So when a resize ends inside a tile, the
    // content moves to a fresh window with the same frame, and the size the user chose is simply the window's size.

    public func windowWillStartLiveResize(_ notification: Notification) {
        resizeStart = (Self.tile(of: window), window.frame)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        defer { resizeStart = nil }
        // Entering a tile, or changing to another one, also ends a "live resize". Only a resize that began and ended
        // in the same tile, with a different frame, is the user dragging an edge.
        guard let tile = Self.tile(of: window), let start = resizeStart, start.tile == tile, start.frame != window.frame else { return }
        // Once the resize has finished handling its own events
        DispatchQueue.main.async { [weak self] in self?.leaveTile() }
    }

    private func leaveTile() {
        let old = window
        guard Self.tile(of: old) != nil, old.isVisible, !old.inLiveResize else { return }
        let fresh = Self.makeWindow()
        fresh.setFrame(old.frame, display: false)
        // One window at a time owns the saved frame; the fresh one saves it without the tile
        old.setFrameAutosaveName("")
        old.delegate = nil
        fresh.saveFrame(usingName: Self.frameName)
        fresh.setFrameAutosaveName(Self.frameName)
        fresh.delegate = self
        // The hosting view moves over as it is: the dashboard keeps its state and scroll position
        let content = old.contentView
        old.contentView = NSView()
        fresh.contentView = content
        window = fresh
        applyFloating()
        // Swap in place, without the open and close animations
        fresh.animationBehavior = .none
        old.animationBehavior = .none
        fresh.order(.above, relativeTo: old.windowNumber)
        if old.isKeyWindow { fresh.makeKey() }
        old.orderOut(nil)
        fresh.animationBehavior = .default
    }

    /// The tile macOS has the window in (the tile part of its frame descriptor, which AppKit also saves), nil in none
    private static func tile(of window: NSWindow) -> String? {
        let descriptor = window.frameDescriptor
        return descriptor.firstIndex(of: "{").map { String(descriptor[$0...]) }
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
