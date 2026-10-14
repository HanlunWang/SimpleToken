import Foundation

/// Cursor and Grok Bot keep no usage logs on this Mac: their usage lives in the Cursor account. tokscale fetches it
/// from Cursor's usage API into its cache (`~/.config/tokscale/cursor-cache`), which its scans then read like any
/// other client. This runs that sync before each full scan, and signs tokscale in from the Cursor desktop app's
/// session the first time. Nothing happens unless Cursor is signed in on this Mac.
public struct CursorSync: Sendable {
    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
    }

    /// Whether there is a Cursor sign-in to sync from
    public static var isAvailable: Bool { CursorProbe.locateToken() != nil }

    /// Syncs the cache; signs tokscale in first when it has no Cursor account yet. Errors are reported, not thrown:
    /// the scans go on with whatever the cache holds.
    public func sync() async -> String? {
        guard Self.isAvailable else { return nil }
        if !FileManager.default.fileExists(atPath: CursorProbe.tokscaleCredentials.path) {
            let login = try? await ProcessRunner.run(binary, arguments: ["cursor", "login", "--name", "simpletoken"], timeout: 60)
            guard login?.exitCode == 0 else { return L("tokscale could not sign in to Cursor") }
        }
        guard let out = try? await ProcessRunner.run(binary, arguments: ["cursor", "sync", "--json"], timeout: 240) else {
            return L("tokscale cursor sync did not finish")
        }
        guard let json = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else {
            return out.exitCode == 0 ? nil : L("tokscale cursor sync failed")
        }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}
