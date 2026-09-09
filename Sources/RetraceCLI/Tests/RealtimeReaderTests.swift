import Foundation
import XCTest
import SQLCipher
@testable import Database
@testable import RetraceKit

/// Realtime reads: windows of frames since a checkpoint, a watcher that streams new
/// frames as a second connection writes them (production shape: app writes, SDK reads),
/// and JPEG downsizing for model payloads.
final class RealtimeReaderTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL { sandbox.appendingPathComponent("recordings") }
    private var database: URL { root.appendingPathComponent("retrace.db") }

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        sandbox = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("RealtimeReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func openFixture() throws -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        return try XCTUnwrap(db)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw NSError(domain: "FixtureSQL", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// A migrated DB plus one segment and frames at known timestamps.
    @discardableResult
    private func seeded() async throws -> OpaquePointer {
        let db = try openFixture()
        try await MigrationRunner(db: db).runMigrations()
        try exec(db, """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type)
            VALUES(1,'com.apple.Terminal',0,0,'terminal — work',NULL,0);
            INSERT INTO frame(id,createdAt,imageFileName,segmentId) VALUES(10,1000,'f',1),(11,2000,'f',1),(12,3000,'f',1);
            """)
        return db
    }

    func testFramesSinceReturnsOnlyNewerFramesOrdered() async throws {
        let db = try await seeded()
        defer { sqlite3_close(db) }
        let frames = try SourceDatabase.withConnection(root: root) {
            try SourceDatabase.frames($0, sinceMs: 1500, untilMs: nil, limit: 10)
        }
        XCTAssertEqual(frames.map(\.frameId), [11, 12])
        XCTAssertEqual(frames.map(\.timestampMs), [2000, 3000])
        XCTAssertEqual(frames.first?.appBundleId, "com.apple.Terminal")
        XCTAssertEqual(frames.first?.windowName, "terminal — work")
    }

    func testFramesUntilBoundsTheWindowAndZeroLimitIsEmpty() async throws {
        let db = try await seeded()
        defer { sqlite3_close(db) }
        let bounded = try SourceDatabase.withConnection(root: root) {
            try SourceDatabase.frames($0, sinceMs: nil, untilMs: 2500, limit: 10)
        }
        XCTAssertEqual(bounded.map(\.frameId), [10, 11])
        let none = try SourceDatabase.withConnection(root: root) {
            try SourceDatabase.frames($0, sinceMs: nil, untilMs: nil, limit: 0)
        }
        XCTAssertTrue(none.isEmpty)
    }

    func testWatcherStreamsFramesWrittenByAnotherConnection() async throws {
        let db = try await seeded()
        defer { sqlite3_close(db) }
        let writer = try openFixture()
        defer { sqlite3_close(writer) }
        try exec(writer, "PRAGMA journal_mode=WAL;")
        let watcher = FrameWatcher(storageRoot: root, pollInterval: 0.2)
        let stream = watcher.stream(fromFrameId: 12)
        var iterator = stream.makeAsyncIterator()
        // Simulate the recorder committing a new frame while we poll read-only.
        try exec(writer, "INSERT INTO frame(id,createdAt,imageFileName,segmentId) VALUES(13,4000,'f',1);")
        let batch = try await withTimeout(seconds: 5) { try await iterator.next() }
        XCTAssertEqual(batch?.map(\.frameId), [13])
    }

    func testJPEGDownscaleBoundsLongEdgeAndDecodes() throws {
        let source = CGContext.bitmapContext(width: 3840, height: 2160)!
        let image = source.makeImage()!
        let data = try XCTUnwrap(ImageCoder.jpegData(from: image, maxDimension: 768))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let size = decoded.map { max($0.width, $0.height) }
        XCTAssertEqual(size, 768)
        XCTAssertFalse(data.isEmpty)
    }

    func testJPEGDownscalePreservesSmallImages() throws {
        let source = CGContext.bitmapContext(width: 300, height: 200)!
        let data = try XCTUnwrap(ImageCoder.jpegData(from: source.makeImage()!, maxDimension: 768))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(decoded?.width, 300)
        XCTAssertEqual(decoded?.height, 200)
    }
}

/// Fails the test when the body does not produce a value in time (watcher must not hang).
private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds), clock: .continuous)
            throw NSError(domain: "WatchTimeout", code: 1)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

extension CGContext {
    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
