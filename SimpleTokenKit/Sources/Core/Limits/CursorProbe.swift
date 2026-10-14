import Foundation
import SQLite3

/// Cursor limit probe. Grok Bot is a Cursor app, so its usage and its weekly included-usage window live in the
/// Cursor account (the merged "X Pass" plan). The window comes from Cursor's dashboard RPC
/// (`DashboardService/GetSandUsageStatus`, the same call Grok Bot's own usage view makes), the on-demand spend
/// from `GetCurrentPeriodUsage`, and the plan name from the dashboard's `get-plan-info`.
///
/// Credentials are never typed into SimpleToken: the access token of the Cursor desktop sign-in is read from
/// Cursor's own state database (`cursorAuth/accessToken`), or from tokscale's Cursor credentials when tokscale
/// has already captured it. Nothing is stored by SimpleToken.
public struct CursorProbe: Sendable {
    public struct Token: Sendable, Equatable {
        /// The Cursor user id (`user_…`), from the token's subject
        public let userId: String
        public let accessToken: String

        /// The dashboard's session cookie: user id and token, joined as the web app does
        var sessionCookie: String { "WorkosCursorSessionToken=\(userId)%3A%3A\(accessToken)" }
    }

    public let token: Token

    public init(token: Token) {
        self.token = token
    }

    // MARK: - Finding the sign-in

    /// Cursor's desktop state database (VS Code global storage)
    public static var stateDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// tokscale's Cursor credentials (written by `tokscale cursor login`)
    public static var tokscaleCredentials: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tokscale/cursor-credentials.json")
    }

    /// The signed-in Cursor account, if any: the desktop app's token first (it keeps it fresh), else tokscale's copy
    public static func locateToken() -> Token? {
        if let token = tokenFromStateDatabase(stateDatabase) { return token }
        return tokenFromTokscale(tokscaleCredentials)
    }

    static func tokenFromStateDatabase(_ url: URL) -> Token? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        // Read-only, and the database may be open in Cursor: never take a write lock
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let accessToken = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userId = userId(fromJWT: accessToken) else { return nil }
        return Token(userId: userId, accessToken: accessToken)
    }

    static func tokenFromTokscale(_ url: URL) -> Token? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accounts = root["accounts"] as? [String: Any] ?? [:]
        let active = (root["activeAccountId"] as? String).flatMap { accounts[$0] as? [String: Any] }
            ?? accounts.values.compactMap { $0 as? [String: Any] }.first
        guard let session = active?["sessionToken"] as? String else { return nil }
        return token(fromSession: session)
    }

    /// tokscale stores the cookie value: `user_…::<jwt>` (the separator may be URL-encoded)
    static func token(fromSession session: String) -> Token? {
        let parts = session.replacingOccurrences(of: "%3A%3A", with: "::").components(separatedBy: "::")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return Token(userId: parts[0], accessToken: parts[1])
    }

    /// The `sub` claim of Cursor's token: `auth0|user_…`
    static func userId(fromJWT jwt: String) -> String? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    // MARK: - Probing

    static let rpcBase = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!
    static let planInfo = URL(string: "https://cursor.com/api/dashboard/get-plan-info")!

    public func probe() async throws -> ProviderLimits {
        let status = try await rpc("GetSandUsageStatus")
        // The other two only add to the picture
        let period = try? await rpc("GetCurrentPeriodUsage")
        let plan = try? await post(Self.planInfo, headers: ["Cookie": token.sessionCookie], body: "{}")
        return try Self.parse(status: status, period: period, plan: plan)
    }

    private func rpc(_ method: String) async throws -> [String: Any] {
        try await post(Self.rpcBase.appendingPathComponent(method),
                       headers: ["Authorization": "Bearer \(token.accessToken)", "Connect-Protocol-Version": "1"], body: "{}")
    }

    private func post(_ url: URL, headers: [String: String], body: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("SimpleToken", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403: throw LimitsError.unauthorized
        case 429: throw LimitsError.sourceRateLimited
        default: throw LimitsError.unavailable(L("Cursor returned HTTP \(code)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.unavailable(L("Cursor returned something other than JSON"))
        }
        return json
    }

    // MARK: - Parsing

    /// Builds the windows from the three responses. Numbers may arrive as numbers or strings (protobuf JSON);
    /// timestamps as RFC 3339 strings, `{seconds}` objects or milliseconds.
    static func parse(status: [String: Any], period: [String: Any]?, plan: [String: Any]?, now: Date = Date()) throws -> ProviderLimits {
        guard let percent = number(status["usagePercent"]) else {
            throw LimitsError.unavailable(L("Cursor reported no usage window"))
        }
        let reset = date(status["nextResetTimestampUtc"])
        var windows = [LimitWindow(kind: .weekly, usedPercent: max(0, percent), resetsAt: reset, windowMinutes: 7 * 24 * 60)]

        // On-demand spend against its limit, when the account has one
        if let spend = period?["spendLimitUsage"] as? [String: Any],
           let limit = number(spend["individualLimit"]), limit > 0, limit < 2_000_000_000,
           let used = number(spend["individualUsed"]) {
            windows.append(LimitWindow(kind: .model, usedPercent: used / limit * 100,
                                       resetsAt: date(period?["billingCycleEnd"]), title: L("On-demand")))
        }

        let info = plan?["planInfo"] as? [String: Any]
        var label = (info?["planName"] as? String ?? status["grokPlanLabel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if (plan?["isMerged"] as? Bool) == true, !label.lowercased().contains("x pass") {
            label = label.isEmpty ? "X Pass" : "X Pass \(label)"
        }
        return ProviderLimits(provider: .cursor, windows: windows, accountLabel: label, updatedAt: now)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let s as String: Double(s)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        switch value {
        case let s as String:
            if let parsed = ISO8601DateFormatter.cursor.date(from: s) ?? ISO8601DateFormatter.cursorFractional.date(from: s) { return parsed }
            if let ms = Double(s) { return Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms) }
            return nil
        case let object as [String: Any]:
            return number(object["seconds"]).map { Date(timeIntervalSince1970: $0) }
        case let n as Double:
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        case let i as Int:
            return Date(timeIntervalSince1970: Double(i) > 1e11 ? Double(i) / 1000 : Double(i))
        default:
            return nil
        }
    }
}

private extension ISO8601DateFormatter {
    // Created once: ICU initialisation is expensive (see Fmt)
    nonisolated(unsafe) static let cursor = ISO8601DateFormatter()
    nonisolated(unsafe) static let cursorFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
