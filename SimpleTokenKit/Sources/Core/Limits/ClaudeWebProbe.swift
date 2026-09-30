import Foundation

/// Claude Web limit probe (the main path on this machine — new Claude Code builds keep no OAuth token on disk).
/// Flow ported from the old fetchClaudeWebLimits:
///   GET claude.ai/api/organizations → pick an org (chat-capable first)
///   GET claude.ai/api/organizations/{id}/usage → five_hour / seven_day / limits[] (Fable)
/// Notes: cookie header `sessionKey=sk-ant-…`; a browser UA is required (an honest UA gets a Cloudflare 403);
/// set-cookie in the response may rotate sessionKey, which must go back to the caller to persist or the cookie dies.
public struct ClaudeWebProbe: Sendable {
    /// Browser UA from the same source as the old code (claude.ai rejects non-browser clients)
    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    static let base = URL(string: "https://claude.ai")!

    public struct Result: Sendable {
        public let limits: ClaudeLimits
        public let renewedSessionKey: String?   // when non-nil the caller must persist it
    }

    let sessionKey: String

    public init(cookie: String) throws {
        let key = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "sessionKey=", with: "")
        guard key.hasPrefix("sk-ant-") else { throw LimitsError.invalidCookie }
        self.sessionKey = key
    }

    public func probe(cachedOrganizationId: String? = nil) async throws -> (result: Result, organizationId: String) {
        var currentKey = sessionKey

        let organizationId: String
        if let cachedOrganizationId {
            organizationId = cachedOrganizationId
        } else {
            let (orgsData, renewed1) = try await get("api/organizations", sessionKey: currentKey)
            if let renewed1 { currentKey = renewed1 }
            organizationId = try Self.selectOrganization(from: orgsData)
        }

        let (usageData, renewed2) = try await get(
            "api/organizations/\(organizationId)/usage", sessionKey: currentKey
        )
        if let renewed2 { currentKey = renewed2 }

        let limits = try Self.parseUsage(usageData)
        let renewed = currentKey == sessionKey ? nil : currentKey
        return (Result(limits: limits, renewedSessionKey: renewed), organizationId)
    }

    // MARK: - HTTP

    private func get(_ path: String, sessionKey: String) async throws -> (Data, renewedKey: String?) {
        var request = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "cookie")
        request.setValue(Self.browserUA, forHTTPHeaderField: "user-agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LimitsError.unavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LimitsError.unavailable("no http response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403:
            if http.value(forHTTPHeaderField: "cf-mitigated") == "challenge" {
                throw LimitsError.challenge
            }
            throw LimitsError.unauthorized
        case 429: throw LimitsError.sourceRateLimited
        default: throw LimitsError.unavailable("http \(http.statusCode)")
        }
        return (data, Self.renewedSessionKey(from: http))
    }

    /// Rotated sessionKey from set-cookie (multiple headers get comma-joined; split the same way as the old code)
    static func renewedSessionKey(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        var latest: String?
        for chunk in header.components(separatedBy: CharacterSet(charactersIn: ",\r\n")) {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("sessionkey=") else { continue }
            let value = trimmed.dropFirst("sessionKey=".count)
                .components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("sk-ant-") { latest = value }
        }
        return latest
    }

    // MARK: - Parsing

    /// Org choice (ported from selectClaudeWebOrganization): chat-capable > not API-only > first
    static func selectOrganization(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw LimitsError.unavailable("organizations: not json")
        }
        let list: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            list = arr
        } else if let dict = root as? [String: Any] {
            list = (dict["organizations"] ?? dict["data"]) as? [[String: Any]] ?? []
        } else {
            list = []
        }
        func orgId(_ o: [String: Any]) -> String {
            for k in ["uuid", "id", "organization_uuid"] {
                if let v = o[k] as? String, !v.isEmpty { return v }
            }
            return ""
        }
        func capabilities(_ o: [String: Any]) -> Set<String> {
            Set((o["capabilities"] as? [String]) ?? [])
        }
        let candidates = list.filter { !orgId($0).isEmpty }
        let chosen = candidates.first { capabilities($0).contains("chat") }
            ?? candidates.first { !(capabilities($0) == ["api"]) }
            ?? candidates.first
        guard let chosen else { throw LimitsError.unavailable("no organization") }
        return orgId(chosen)
    }

    /// usage response → windows (five_hour / seven_day / weekly_scoped Fable in limits[])
    static func parseUsage(_ data: Data) throws -> ClaudeLimits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.unavailable("usage: not json")
        }
        var windows: [LimitWindow] = []

        func percent(_ o: [String: Any]) -> Double? {
            for k in ["utilization", "usedPercent", "used_percent", "percent"] {
                if let v = o[k] as? Double { return v }
                if let v = o[k] as? Int { return Double(v) }
            }
            return nil
        }
        func reset(_ o: [String: Any]) -> Date? {
            for k in ["resets_at", "resetsAt"] {
                if let s = o[k] as? String { return parseISO(s) }
            }
            return nil
        }
        func window(_ keys: [String], kind: LimitWindow.Kind) {
            for k in keys {
                guard let o = root[k] as? [String: Any], let p = percent(o) else { continue }
                windows.append(LimitWindow(kind: kind, usedPercent: p, resetsAt: reset(o)))
                return
            }
        }
        window(["five_hour", "fiveHour"], kind: .session)
        window(["seven_day", "sevenDay"], kind: .weekly)

        // weekly_scoped · Fable in limits[] (a time-limited quota, only in the structured array)
        for entry in (root["limits"] as? [[String: Any]]) ?? [] {
            guard (entry["kind"] as? String) == "weekly_scoped" else { continue }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let display = (model?["display_name"] as? String) ?? ""
            guard display.lowercased() == "fable" else { continue }
            let source = (entry["usage"] as? [String: Any]) ?? entry
            guard let p = percent(source) else { continue }
            windows.append(LimitWindow(kind: .fable, usedPercent: p,
                                       resetsAt: reset(source) ?? reset(entry)))
        }

        guard !windows.isEmpty else { throw LimitsError.unavailable("usage: no windows") }
        return ClaudeLimits(windows: windows, accountLabel: "", updatedAt: Date())
    }

    static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }
}
