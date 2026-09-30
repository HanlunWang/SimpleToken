import AppKit
import Core
import DesignSystem
import Features

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.migrateFromLumenIfNeeded()   // data and settings from before the rename (before any store reads)
        try? AppPaths.ensureDirectories()
        // The UI is designed for dark only: force the dark appearance so system controls and glass follow
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let state = AppState()
        let mainWindow = MainWindowController(state: state)
        let statusItem = StatusItemController(state: state)
        statusItem.onOpenMainWindow = { [weak mainWindow] in mainWindow?.show() }
        statusItem.onOpenSettings = { [weak state] in state?.openSettings() }
        state.applyWindowSettings = { [weak mainWindow] in mainWindow?.applyFloating() }
        state.openMainWindow = { [weak mainWindow, weak statusItem] in
            statusItem?.hidePanel()
            mainWindow?.show()
        }
        self.appState = state
        self.mainWindow = mainWindow
        self.statusItem = statusItem

        state.start()
        // Show the main window at launch; afterwards the app lives in the menu bar
        mainWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu bar app
    }
}
