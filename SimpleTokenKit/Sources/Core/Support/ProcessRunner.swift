import Foundation

/// Child process execution with a timeout and a clean environment. Shared by every spawn (tokscale / claude CLI).
public enum ProcessRunner {
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    public enum RunError: Error, Equatable {
        case timeout
        case launchFailed(String)
        case nonZeroExit(Int32, stderr: String)
    }

    /// Minimal clean environment. Required when spawning `claude` — CLAUDE_CODE_* / ANTHROPIC_* variables
    /// inherited from a Claude Code session turn the child into an API-billed sub-session (verified).
    public static func cleanEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Runs until exit or timeout (SIGTERM on timeout). Returns stdout/stderr/exitCode;
    /// the exit code is not judged here — tokscale may exit non-zero on empty data, so callers decide.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 120
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            process.currentDirectoryURL = currentDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            // Read on a background queue so a full 64 KB pipe cannot hang the child
            let ioQueue = DispatchQueue(label: "simpletoken.process.io")
            nonisolated(unsafe) var outData = Data()
            nonisolated(unsafe) var errData = Data()
            let group = DispatchGroup()
            group.enter()
            ioQueue.async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            ioQueue.async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            nonisolated(unsafe) var timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak process] in
                timedOut = true
                process?.terminate()
            }

            process.terminationHandler = { proc in
                timer.cancel()
                group.wait()
                if timedOut {
                    continuation.resume(throwing: RunError.timeout)
                } else {
                    continuation.resume(returning: Output(
                        stdout: outData, stderr: errData, exitCode: proc.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
                timer.resume()
            } catch {
                timer.cancel()
                continuation.resume(throwing: RunError.launchFailed(error.localizedDescription))
            }
        }
    }
}
