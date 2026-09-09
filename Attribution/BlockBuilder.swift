import Foundation
import RetraceKit

/// Accumulates incoming frames into work blocks. A block closes when the app or
/// window changes, when a capture gap exceeds the idle threshold, or when the block
/// outgrows its maximum span — whichever comes first. Closures are returned to the
/// caller, who owns classification timing.
public struct BlockBuilder: Sendable {
    public let maxBlockMs: Int64
    public let gapMs: Int64

    private var first: SourceDatabase.FrameSummary?
    private var last: SourceDatabase.FrameSummary?
    private var frames: [SourceDatabase.FrameSummary] = []

    public init(maxBlockMs: Int64 = 300_000, gapMs: Int64 = 120_000) {
        self.maxBlockMs = maxBlockMs
        self.gapMs = gapMs
    }

    public var openBlock: (startedAtMs: Int64, appBundleId: String?, windowName: String?)? {
        first.map { ($0.timestampMs, $0.appBundleId, $0.windowName) }
    }

    /// Adds a frame, returning the just-closed block when this frame starts new work.
    public mutating func add(_ frame: SourceDatabase.FrameSummary) -> ClosedBlock? {
        defer {
            if first == nil { first = frame }
            last = frame
            frames.append(frame)
        }
        if let first {
            let appChanged = frame.appBundleId != first.appBundleId
            let windowChanged = normalizedTitle(frame.windowName) != normalizedTitle(first.windowName)
            let gap = frame.timestampMs - max(first.timestampMs, last?.timestampMs ?? first.timestampMs)
            if appChanged || windowChanged || gap > gapMs {
                return close()
            }
            if frame.timestampMs - first.timestampMs > maxBlockMs {
                return close()
            }
        }
        return nil
    }

    /// Closes and clears any accumulated work.
    public mutating func close() -> ClosedBlock? {
        guard let first, let last else { return nil }
        let block = ClosedBlock(
            startedAtMs: first.timestampMs, endedAtMs: last.timestampMs,
            appBundleId: first.appBundleId, windowName: first.windowName, browserUrl: first.browserUrl,
            frames: frames)
        self.first = nil
        self.last = nil
        frames.removeAll()
        return block
    }

    public mutating func flush() -> ClosedBlock? { close() }

    /// Window titles carry volatile suffixes (counts, tab names, save state). Compare a
    /// coarse normalization so the same document does not fragment into new blocks.
    private func normalizedTitle(_ title: String?) -> String {
        guard let title else { return "" }
        return title.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .split(separator: " ").prefix(6).joined()
    }
}

/// A closed stretch of recording ready for classification.
public struct ClosedBlock: Sendable {
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let appBundleId: String?
    public let windowName: String?
    public let browserUrl: String?
    public let frames: [SourceDatabase.FrameSummary]

    public var frameIds: [Int64] { frames.map(\.frameId) }

    public var id: String {
        // Deterministic identity: same evidence always maps to the same block id, so
        // crash-replay inserts are no-ops.
        "\(firstFrameId)-\(lastFrameId)-\(startedAtMs)"
    }

    public var firstFrameId: Int64 { frames.first?.frameId ?? 0 }
    public var lastFrameId: Int64 { frames.last?.frameId ?? 0 }
}
