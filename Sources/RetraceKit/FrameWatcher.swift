import Foundation

/// Streams batches of newly recorded frames from the live database by polling the
/// frame table on the strict read-only VFS. The recorder keeps writing through its
/// own connection; transient lock contention degrades to an empty poll, never an
/// error, because a live watcher's contract is "keep watching".
public final class FrameWatcher: Sendable {
    private let storageRoot: URL
    private let pollInterval: TimeInterval
    private let batchLimit = 200

    public init(storageRoot: URL, pollInterval: TimeInterval = 2) {
        self.storageRoot = storageRoot
        self.pollInterval = pollInterval
    }

    /// Batches of frames with id strictly greater than `fromFrameId` (nil = only the
    /// newest id first, so a fresh start does not replay history).
    public func stream(fromFrameId: Int64?) -> AsyncStream<[SourceDatabase.FrameSummary]> {
        let root = storageRoot
        let interval = pollInterval
        let limit = batchLimit
        return AsyncStream { continuation in
            let task = Task.detached {
                var lastId = fromFrameId
                if lastId == nil {
                    // Realtime means "from now on": skip everything already recorded.
                    lastId = (try? await Self.latestFrameId(root: root)) ?? 0
                }
                while !Task.isCancelled {
                    if let batch = try? await Self.poll(root: root, afterId: lastId ?? 0, limit: limit), !batch.isEmpty {
                        lastId = batch.map(\.frameId).max()
                        continuation.yield(batch)
                    }
                    try? await Task.sleep(for: .seconds(interval), clock: .continuous)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func poll(root: URL, afterId: Int64, limit: Int) throws -> [SourceDatabase.FrameSummary] {
        try SourceDatabase.withConnection(root: root) {
            try SourceDatabase.frames($0, sinceFrameId: afterId, limit: limit)
        }
    }

    private static func latestFrameId(root: URL) throws -> Int64 {
        try SourceDatabase.withConnection(root: root) { try SourceDatabase.latestFrameId($0) }
    }
}
