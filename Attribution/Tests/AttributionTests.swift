import Foundation
import XCTest
@testable import RetraceKit
@testable import Attribution

final class AttributionTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL { sandbox.appendingPathComponent("recordings") }
    private var state: URL { sandbox.appendingPathComponent("attribution-state") }

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        sandbox = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("AttributionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func frame(_ id: Int64, _ ts: Int64, app: String? = "com.apple.Terminal",
                       window: String? = "term") -> SourceDatabase.FrameSummary {
        SourceDatabase.FrameSummary(frameId: id, timestampMs: ts, videoId: nil, videoFrameIndex: nil,
                                    appBundleId: app, windowName: window, browserUrl: nil)
    }

    // MARK: - AttributionStore

    private func block(_ id: String, from: Int64, to: Int64, project: String = "retrace") -> AttributionRecord {
        AttributionRecord(id: id, startedAtMs: from, endedAtMs: to, appBundleId: "com.apple.Terminal",
                          windowName: "term", browserUrl: nil, frameIds: [from], project: project,
                          activity: "coding with AI", confidence: 0.9, model: "fixture-model",
                          classifiedAtMs: to + 1)
    }

    func testStoreRoundtripsBlocksIdempotentlyAndTracksCheckpoint() throws {
        let store = try AttributionStore(stateRoot: state, sourceRoot: root)
        XCTAssertNil(try store.loadCheckpoint())
        try store.saveCheckpoint(frameId: 42)
        XCTAssertEqual(try store.loadCheckpoint(), 42)
        let first = block("b1", from: 1000, to: 60_000)
        try store.append(first)
        try store.append(first)  // replay after crash must not duplicate
        let stored = try store.blocks(sinceMs: 0)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.project, "retrace")
        XCTAssertEqual(stored.first?.durationMs, 59_000)
    }

    func testStoreRefusesStateInsideSource() throws {
        XCTAssertThrowsError(try AttributionStore(stateRoot: root, sourceRoot: root))
    }

    func testTotalsGroupByProjectWithoutOverlap() throws {
        let store = try AttributionStore(stateRoot: state, sourceRoot: root)
        try store.append(block("a", from: 0, to: 60_000, project: "retrace"))
        try store.append(block("b", from: 60_000, to: 150_000, project: "retrace"))
        try store.append(block("c", from: 150_000, to: 200_000, project: "email"))
        let totals = try store.totals(sinceMs: 0)
        XCTAssertEqual(totals["retrace"], 150_000)
        XCTAssertEqual(totals["email"], 50_000)
    }

    // MARK: - BlockBuilder

    func testBuilderClosesOnAppSwitchGapAndMaxAge() {
        var builder = BlockBuilder(maxBlockMs: 300_000, gapMs: 120_000)
        XCTAssertNil(builder.add(frame(1, 0, app: "com.apple.Terminal", window: "term")))
        XCTAssertNil(builder.add(frame(2, 10_000, app: "com.apple.Terminal", window: "term")))
        let switched = builder.add(frame(3, 20_000, app: "com.google.Chrome", window: "site a"))
        XCTAssertEqual(switched?.frameIds, [1, 2])
        XCTAssertNil(builder.add(frame(4, 30_000, app: "com.google.Chrome", window: "site a")))
        let gapped = builder.add(frame(5, 400_000, app: "com.google.Chrome", window: "site a"))
        XCTAssertEqual(gapped?.frameIds, [3, 4])
        // Frame 5 opened a lone Chrome block; switching back to Terminal closes it.
        let lone = builder.add(frame(6, 410_000, app: "com.apple.Terminal", window: "term2"))
        XCTAssertEqual(lone?.frameIds, [5])
        let closedAgain = builder.add(frame(7, 720_000, app: "com.apple.Terminal", window: "term2"))
        XCTAssertEqual(closedAgain?.frameIds, [6])
        XCTAssertEqual(closedAgain?.startedAtMs, 410_000)
        let flushed = builder.flush()
        XCTAssertEqual(flushed?.frameIds, [7])
    }

    // MARK: - GeminiClient (recorded transport, no network)

    private func closedBlock(from: Int64, to: Int64) -> ClosedBlock {
        ClosedBlock(startedAtMs: from, endedAtMs: to, appBundleId: "com.apple.Terminal",
                    windowName: "term", browserUrl: nil,
                    frames: [frame(from, from), frame(to, to)])
    }

    func testGeminiClientParsesStructuredResponse() async throws {
        let recorded = """
        {"candidates":[{"content":{"parts":[{"text":"{\\"project\\":\\"retrace-llm\\",\\"activity\\":\\"AI-assisted coding\\",\\"confidence\\":0.93}"}]}}]}
        """
        let transport = RecordedTransport(status: 200, body: Data(recorded.utf8))
        let client = GeminiClient(apiKey: "fixture-key", transport: transport)
        let attribution = try await client.classify(
            block: closedBlock(from: 0, to: 1000),
            ocrDigest: "terminal swift test output",
            images: [Data([0xFF, 0xD8, 0xFF])])
        XCTAssertEqual(attribution.project, "retrace-llm")
        XCTAssertEqual(attribution.activity, "AI-assisted coding")
        XCTAssertEqual(attribution.confidence ?? 0, 0.93, accuracy: 0.001)
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        XCTAssertTrue(request.url?.path.contains("generateContent") ?? false)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("terminal swift test output"))
        XCTAssertTrue(body.contains("inline_data") || body.contains("inlineData"))
    }

    func testGeminiClientRetriesRateLimitThenSurfacesFailure() async {
        let transport = RecordedTransport(status: 429, body: Data("{}".utf8), succeedAfterAttempts: 1)
        let client = GeminiClient(apiKey: "k", transport: transport)
        let attribution = try? await client.classify(block: closedBlock(from: 0, to: 1), ocrDigest: "", images: [])
        XCTAssertNil(attribution)
        XCTAssertGreaterThanOrEqual(transport.attempts, 2)
    }
}

/// Deterministic transport: serves failures until `succeedAfterAttempts` is reached.
private final class RecordedTransport: LLMTransport, @unchecked Sendable {
    let status: Int
    let body: Data
    let succeedAfterAttempts: Int
    private(set) var attempts = 0
    private(set) var lastRequest: URLRequest?
    private(set) var lastBody: Data?

    init(status: Int, body: Data, succeedAfterAttempts: Int = 0) {
        self.status = status
        self.body = body
        self.succeedAfterAttempts = succeedAfterAttempts
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            let data = NSMutableData()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                guard read > 0 else { break }
                data.append(buffer, length: read)
            }
            return data as Data
        }
        attempts += 1
        let ok = attempts > succeedAfterAttempts
        let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (ok ? body : Data("{}".utf8), response)
    }
}
