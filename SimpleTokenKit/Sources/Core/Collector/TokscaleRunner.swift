import Foundation

/// The single entry point for the tokscale CLI (the role of the old collector.js).
/// The three period scans must be serial — concurrency triples CPU/IO (lesson from the old issue #15).
public struct TokscaleRunner: Sendable {
    public let binary: URL
    public let clients: String
    public let allTimeSince: String

    public enum Scan: Sendable {
        case today, month, allTime(since: String)

        var flags: [String] {
            switch self {
            case .today: ["--today"]
            case .month: ["--month"]
            case .allTime(let since): ["--since", since]
            }
        }
    }

    public init(binary: URL, clients: String = "claude", allTimeSince: String = "2024-01-01") {
        self.binary = binary
        self.clients = clients
        self.allTimeSince = allTimeSince
    }

    /// Binary lookup: app bundle Resources → environment variable → source repo (debug builds and tests)
    public static func locateBinary() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("tokscale/tokscale"))
        }
        if let env = ProcessInfo.processInfo.environment["SIMPLETOKEN_TOKSCALE_PATH"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        #if DEBUG
        // Development path: SimpleTokenKit/Sources/Core/Collector/ → repo root/Resources/tokscale.
        // Debug only: #filePath would put the build machine's source path into release binaries.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/tokscale/tokscale")
        candidates.append(dev)
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func scan(_ scan: Scan) async throws -> TokscaleReport {
        let args = ["--json", "--client", clients, "--group-by", "client,session,model"] + scan.flags
        let out = try await ProcessRunner.run(binary, arguments: args, timeout: 120)
        guard out.exitCode == 0 else {
            throw ProcessRunner.RunError.nonZeroExit(
                out.exitCode,
                stderr: String(data: out.stderr, encoding: .utf8) ?? ""
            )
        }
        return try TokscaleReport.decode(Self.extractJSON(out.stdout))
    }

    public func graph() async throws -> TokscaleGraph {
        let out = try await ProcessRunner.run(
            binary, arguments: ["graph", "--client", clients, "--no-spinner"], timeout: 120
        )
        guard out.exitCode == 0 else {
            throw ProcessRunner.RunError.nonZeroExit(
                out.exitCode,
                stderr: String(data: out.stderr, encoding: .utf8) ?? ""
            )
        }
        return try TokscaleGraph.decode(Self.extractJSON(out.stdout))
    }

    /// Lenient parsing: stdout may carry a non-JSON prefix, so find the first { or [ (as the old code did)
    static func extractJSON(_ data: Data) -> Data {
        if let brace = data.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }),
           brace != data.startIndex {
            return data[brace...]
        }
        return data
    }
}
