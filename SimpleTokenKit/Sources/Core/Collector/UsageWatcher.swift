import Foundation
import CoreServices

/// FSEvents watcher for ~/.claude/projects and ~/.claude/transcripts (whichever exist).
/// Native file-level events; UsageStore handles debouncing (this only reports).
public final class UsageWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "simpletoken.usage-watcher")
    private let paths: [String]
    private let onEvent: @Sendable () -> Void

    public static func claudeWatchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".claude/transcripts").path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    public init(paths: [String], onEvent: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onEvent = onEvent
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<UsageWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onEvent()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // FSEvents coalesces 0.5 s; the layer above adds a 1.5 s debounce
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
