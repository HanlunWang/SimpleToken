import Foundation

/// Codex limit probe: starts the local codex CLI's app-server and reads limits and account over JSON-RPC.
/// Flow ported from token-monitor (providers/codex/limits.js):
///   initialize → initialized → account/rateLimits/read → account/read {refreshToken:false}
/// Notes: approval policy is `-a never` (newer CLIs removed untrusted); the child gets a clean environment;
/// on this machine codex only lives inside ChatGPT.app (not on PATH), so the app bundle is checked first.
public struct CodexProbe: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public func probe(timeout: TimeInterval = 20) async throws -> ProviderLimits {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = ProcessRunner.cleanEnvironment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LimitsError.unavailable(L("Couldn't start codex: \(error.localizedDescription)")) }
        defer { if process.isRunning { process.terminate() } }

        let session = RPCSession(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        return try await withThrowingTaskGroup(of: ProviderLimits.self) { group in
            group.addTask {
                _ = try await session.request(id: 1, method: "initialize",
                                              params: ["clientInfo": ["name": "simpletoken", "title": "SimpleToken", "version": "0.1"]])
                session.notify(method: "initialized", params: [:])
                let limits = try await session.request(id: 2, method: "account/rateLimits/read", params: nil)
                let account = try? await session.request(id: 3, method: "account/read", params: ["refreshToken": false])
                return try Self.parse(rateLimits: limits, account: account)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw LimitsError.unavailable(L("codex app-server timed out"))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Parsing

    static func parse(rateLimits: [String: Any], account: [String: Any]?, now: Date = Date()) throws -> ProviderLimits {
        let direct = (rateLimits["rateLimits"] ?? rateLimits["rate_limits"]) as? [String: Any]
        let byId = (rateLimits["rateLimitsByLimitId"] ?? rateLimits["rate_limits_by_limit_id"]) as? [String: Any] ?? [:]
        let main = direct ?? (byId["codex"] as? [String: Any]) ?? [:]
        var windows: [LimitWindow] = []

        func window(_ raw: Any?, title: String?) -> LimitWindow? {
            guard let w = raw as? [String: Any],
                  let used = (w["usedPercent"] ?? w["used_percent"]) as? Double ?? ((w["usedPercent"] ?? w["used_percent"]) as? Int).map(Double.init)
            else { return nil }
            let minutes = (w["windowDurationMins"] ?? w["window_duration_mins"]) as? Int
            let reset = ((w["resetsAt"] ?? w["resets_at"]) as? Double ?? ((w["resetsAt"] ?? w["resets_at"]) as? Int).map(Double.init))
                .map { Date(timeIntervalSince1970: $0) }
            let kind: LimitWindow.Kind = title != nil ? .model : ((minutes ?? 0) >= 7 * 24 * 60 ? .weekly : .session)
            return LimitWindow(kind: kind, usedPercent: used, resetsAt: reset, windowMinutes: minutes, title: title)
        }

        for key in ["primary", "secondary"] {
            if let w = window(main[key], title: nil) { windows.append(w) }
        }
        // Per-model extra limits (e.g. GPT-5.3-Codex-Spark)
        for (id, value) in byId where id != "codex" {
            guard let snap = value as? [String: Any] else { continue }
            let name = (snap["limitName"] ?? snap["limit_name"]) as? String ?? id
            for key in ["primary", "secondary"] {
                if var w = window(snap[key], title: name) {
                    w.title = "\(name) · \(w.spanSeconds >= 7 * 86400 ? L("Weekly") : L("Session"))"
                    windows.append(w)
                }
            }
        }
        windows.sort { order($0) < order($1) }
        guard !windows.isEmpty else { throw LimitsError.notConfigured }

        let accountObject = account?["account"] as? [String: Any]
        let plan = (accountObject?["planType"] as? String) ?? (main["planType"] as? String) ?? ""
        return ProviderLimits(provider: .codex, windows: windows, accountLabel: planLabel(plan), updatedAt: now)
    }

    private static func order(_ w: LimitWindow) -> Int {
        switch w.kind {
        case .session: 0
        case .weekly: 1
        case .fable: 2
        case .model: 3
        }
    }

    /// Main mappings ported from codexPlanLabelFromParts
    static func planLabel(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = ["pro": "Pro 20x", "prolite": "Pro 5x", "pro_lite": "Pro 5x", "pro-lite": "Pro 5x", "pro lite": "Pro 5x",
                     "free": "Free", "plus": "Plus", "max": "Max", "team": "Team", "teams": "Team",
                     "enterprise": "Enterprise", "business": "Business"]
        if let label = exact[key] { return label }
        return key.isEmpty ? "" : key.prefix(1).uppercased() + key.dropFirst()
    }
}

/// Minimal JSON-RPC over stdio: reads by line, matches responses by id (notifications and other messages are ignored)
final class RPCSession: @unchecked Sendable {
    private let input: FileHandle
    // Requests are strictly serial (one pending response at a time), so the iterator is never advanced concurrently
    private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.iterator = output.bytes.lines.makeAsyncIterator()
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(UInt8(ascii: "\n"))
        try? input.write(contentsOf: data)
    }

    func notify(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    func request(id: Int, method: String, params: [String: Any]?) async throws -> [String: Any] {
        var message: [String: Any] = ["method": method, "id": id]
        if let params { message["params"] = params }
        write(message)
        while true {
            guard let line = try await nextLine() else { throw LimitsError.unavailable(L("codex app-server exited")) }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? Int) == id
            else { continue }
            if let error = object["error"] as? [String: Any] {
                throw LimitsError.unavailable(error["message"] as? String ?? L("codex RPC error"))
            }
            return object["result"] as? [String: Any] ?? [:]
        }
    }

    private func nextLine() async throws -> String? {
        var it = iterator
        let line = try await it.next()
        iterator = it
        return line
    }
}
