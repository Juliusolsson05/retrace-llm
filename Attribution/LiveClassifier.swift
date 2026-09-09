import Foundation
import CoreGraphics
import Storage
import RetraceKit

/// The progressive realtime loop: watch for new frames, close blocks as work
/// changes, classify each block the moment it closes, and checkpoint so a restart
/// resumes exactly where it stopped. Nothing here writes inside the recording
/// source; all harness state lives in AttributionStore.
public enum LiveClassifier {
    public struct Config: Sendable {
        public var maxBlockMs: Int64 = 300_000
        public var gapMs: Int64 = 120_000
        public var pollInterval: TimeInterval = 2
        public var imagesPerBlock = 2
        public var maxImageDimension = 768
        public var apiKey: String
        public var model: String = GeminiClient.defaultModel

        public init(apiKey: String) { self.apiKey = apiKey }
    }

    public static func run(storageRoot: URL, stateRoot: URL, config: Config,
                           transport: LLMTransport = URLSessionTransport(),
                           log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let store = try AttributionStore(stateRoot: stateRoot, sourceRoot: storageRoot)
        let client = GeminiClient(apiKey: config.apiKey, model: config.model, transport: transport)
        let watcher = FrameWatcher(storageRoot: storageRoot, pollInterval: config.pollInterval)
        var builder = BlockBuilder(maxBlockMs: config.maxBlockMs, gapMs: config.gapMs)
        let checkpoint = try store.loadCheckpoint()
        log("watching \(storageRoot.lastPathComponent) from frame \(checkpoint.map(String.init) ?? "now")")

        for await batch in watcher.stream(fromFrameId: checkpoint) {
            for frame in batch {
                if let closed = builder.add(frame) {
                    await classify(closed, store: store, client: client, storageRoot: storageRoot,
                                   config: config, log: log)
                }
                try? store.saveCheckpoint(frameId: frame.frameId)
            }
        }
        if let closed = builder.flush() {
            await classify(closed, store: store, client: client, storageRoot: storageRoot,
                           config: config, log: log)
        }
    }

    static func classify(_ block: ClosedBlock, store: AttributionStore, client: GeminiClient,
                         storageRoot: URL, config: Config, log: @Sendable (String) -> Void) async {
        do {
            let context = try await enrich(block, storageRoot: storageRoot, config: config)
            let attribution = try await client.classify(block: block, ocrDigest: context.text, images: context.images)
            try store.append(AttributionRecord(
                id: block.id, startedAtMs: block.startedAtMs, endedAtMs: block.endedAtMs,
                appBundleId: block.appBundleId, windowName: block.windowName, browserUrl: block.browserUrl,
                frameIds: block.frameIds, project: attribution.project, activity: attribution.activity,
                confidence: attribution.confidence ?? 0, model: config.model,
                classifiedAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
            log("block \(block.startedAtMs)-\(block.endedAtMs) → \(attribution.project): \(attribution.activity)")
        } catch {
            // A failed classification never stops the loop; the block is skipped and
            // the failure surfaces in the log where the operator can see the rate.
            log("classification failed for block \(block.startedAtMs): \(error)")
        }
    }

    /// OCR text and bounded images for the block: text from the newest frames (what
    /// was on screen at the end of the period), images from the first and last kept
    /// frames. DB reads happen inside the connection scope; HEVC decode runs after.
    static func enrich(_ block: ClosedBlock, storageRoot: URL, config: Config) async throws -> (text: String, images: [Data]) {
        let textFrameIds = block.frames.suffix(3).map(\.frameId)
        let imageFrameIds = ([block.frames.first?.frameId, block.frames.last?.frameId].compactMap { $0 })
            .prefix(config.imagesPerBlock)

        var digest: [String] = []
        var imageSources: [(chunk: String, index: Int, rate: Double?)] = []
        try SourceDatabase.withConnection(root: storageRoot) { connection in
            for frameId in textFrameIds {
                guard let evidence = try SourceDatabase.frameEvidence(connection, frameId: frameId) else { continue }
                for region in evidence.regions {
                    let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count > 2, !digest.contains(text) {
                        digest.append(text)
                        if digest.count >= 400 { break }
                    }
                }
            }
            for frameId in imageFrameIds {
                guard let evidence = try SourceDatabase.frameEvidence(connection, frameId: frameId),
                      let video = evidence.video, !video.chunkKey.isEmpty,
                      let index = video.videoFrameIndex else { continue }
                imageSources.append((video.chunkKey, index, video.frameRate))
            }
        }

        var images: [Data] = []
        let extractor = HEVCStorageExtractor(storageRoot: storageRoot.path)
        for source in imageSources {
            let chunk = storageRoot.appendingPathComponent(source.chunk)
            guard FileManager.default.fileExists(atPath: chunk.path) else { continue }
            guard let image = try? await extractor.extractFrameCGImage(videoPath: chunk.path,
                                                                       frameIndex: source.index,
                                                                       frameRate: source.rate),
                  let jpeg = ImageCoder.jpegData(from: image, maxDimension: config.maxImageDimension) else { continue }
            images.append(jpeg)
        }
        return (digest.joined(separator: "\n"), images)
    }
}
