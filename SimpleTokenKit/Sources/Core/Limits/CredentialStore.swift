import Foundation

/// Credential store: local plain-text JSON with 0600 permissions (the same trade-off as the old code — no keychain
/// prompts, no defence against processes already running as the same user). LimitsStore writes rotated cookies back.
public struct CredentialFile: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var claudeWebCookie: String?
}

public enum CredentialStore {
    public static var fileURL: URL { AppPaths.appSupport.appendingPathComponent("credentials.json") }

    /// The old Token Monitor's credential file (migration source; read once, then the two are independent)
    public static var legacyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Monitor/credentials.json")
    }

    public static func load() -> CredentialFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(CredentialFile.self, from: data)
        else { return CredentialFile() }
        return file
    }

    public static func save(_ file: CredentialFile) {
        guard let data = try? JSONEncoder.iso.encode(file) else { return }
        let url = fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// First-launch migration (approved by the user): reads webCookie from the old app. Runs only when we have no cookie.
    @discardableResult
    public static func importFromTokenMonitorIfMissing() -> Bool {
        var current = load()
        guard current.claudeWebCookie == nil || current.claudeWebCookie?.isEmpty == true else { return false }
        guard let data = try? Data(contentsOf: legacyURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = root["credentials"] as? [String: Any],
              let providers = creds["providers"] as? [String: Any],
              let claude = providers["claude"] as? [String: Any],
              let cookie = claude["webCookie"] as? String,
              !cookie.isEmpty
        else { return false }
        current.claudeWebCookie = cookie
        save(current)
        return true
    }
}
