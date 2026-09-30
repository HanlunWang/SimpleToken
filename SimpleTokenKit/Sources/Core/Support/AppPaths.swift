import Foundation

/// App data directory. Everything lives under ~/Library/Application Support/SimpleToken/,
/// separate from token-monitor (the Electron version), so both can coexist.
public enum AppPaths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SimpleToken", isDirectory: true)
    }

    public static var dailyHistoryArchive: URL { appSupport.appendingPathComponent("daily-history-archive.json") }
    public static var collectorAnchor: URL { appSupport.appendingPathComponent("collector-anchor.json") }
    public static var agentEvents: URL { appSupport.appendingPathComponent("agent-events.jsonl") }
    public static var hookScriptDir: URL { appSupport.appendingPathComponent("bin", isDirectory: true) }

    /// History archive of the old app (the Electron Token Monitor) — first-launch import source
    public static var legacyHistoryArchive: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Token Monitor/daily-history-archive.json")
    }

    /// Data directory and defaults domain from before the rename (Lumen) — first-launch migration source
    public static var lumenAppSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lumen", isDirectory: true)
    }
    public static let lumenDefaultsDomain = "dev.hanlun.lumen"

    /// Migrates from Lumen (once, copy only, nothing deleted): the data directory (history archive, anchors,
    /// credentials) + settings. Does nothing if the new directory exists, so repeated calls are harmless.
    /// Must be called before SettingsStore is read.
    public static func migrateFromLumenIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path), fm.fileExists(atPath: lumenAppSupport.path) {
            try? fm.copyItem(at: lumenAppSupport, to: appSupport)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLumen") else { return }
        if let old = defaults.persistentDomain(forName: lumenDefaultsDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                let renamed = key == "NSWindow Frame LumenMainWindow" ? "NSWindow Frame SimpleTokenMainWindow" : key
                defaults.set(value, forKey: renamed)
            }
        }
        defaults.set(true, forKey: "migratedFromLumen")
    }

    /// Ensures the directory exists (idempotent)
    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookScriptDir, withIntermediateDirectories: true)
    }
}
