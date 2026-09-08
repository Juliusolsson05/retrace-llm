import Foundation
import XCTest
import SQLCipher
import Shared
import Storage
@testable import Database
@testable import RetraceCLI

/// Single-frame evidence access. Text slicing mirrors the app's canonical read
/// (Database/Queries/NodeQueries.swift getNodesWithText):
///   SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)
/// with c0/c1 being searchRanking_content's text/otherText columns, joined via
/// doc_segment(frameId -> docid) -> searchRanking_content(id).
final class FrameCommandTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL { sandbox.appendingPathComponent("recordings") }
    private var state: URL { sandbox.appendingPathComponent("cli-state") }
    private var database: URL { root.appendingPathComponent("retrace.db") }

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        sandbox = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("FrameCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func run(_ extra: [String]) async -> CLIResult {
        await CLICommand.run(arguments: ["frame", "--storage-root", root.path, "--state-root", state.path] + extra)
    }

    private func json(_ result: CLIResult) throws -> [String: Any] {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        return value
    }

    private func openFixture() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// Seeds one frame whose OCR text blob is text||otherText and whose nodes
    /// slice known windows out of it, exactly like production ingestion does.
    private func initializeFixture() async throws -> OpaquePointer {
        let db = try openFixture()
        try await MigrationRunner(db: db).runMigrations()
        return db
    }

    private func seedFrame(db: OpaquePointer, frameId: Int64 = 50000110, withFTS: Bool = true, encrypted: Bool = false) throws {
        try exec(db, """
            INSERT INTO video(id,height,width,path,frameRate,processingState)
            VALUES(1000002,1000,1000,'chunks/202609/08/1788910058197',30.0,0);
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type)
            VALUES(10000001,'com.apple.Terminal',0,0,'juliusolsson@mac — bringdown-engine',NULL,0);
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex)
            VALUES(\(frameId),1788910100000,'frame-opaque',10000001,1000002,67);
            """)
        if withFTS {
            // text = 24 chars, otherText = 19 chars; blob = 43 chars.
            try exec(db, """
                INSERT INTO searchRanking(text, otherText) VALUES('Hello world from Retrace', ' OCR pipeline lives');
                INSERT INTO doc_segment(docid, segmentId, frameId)
                VALUES((SELECT rowid FROM searchRanking ORDER BY rowid DESC LIMIT 1), 10000001, \(frameId));
                """)
        }
        try exec(db, encrypted ? """
            INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,encryptedText)
            VALUES(\(frameId),0,0,24,0.1,0.2,0.3,0.4,'opaque-ciphertext');
            """ : """
            INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height)
            VALUES(\(frameId),0,0,24,0.1,0.2,0.3,0.4),
                   (\(frameId),1,25,18,0.5,0.6,0.05,0.06);
            """)
    }

    func testFrameReturnsOCRTextGeometryAndLineage() async throws {
        let db = try await initializeFixture()
        defer { sqlite3_close(db) }
        try seedFrame(db: db)
        let result = await run(["--frame-id", "50000110"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["frameId"] as? Int64, 5_000_0110)
        XCTAssertEqual(report["timestampMs"] as? Int64, 1_788_910_100_000)
        XCTAssertEqual(report["textAvailable"] as? Bool, true)
        XCTAssertEqual(report["ocrRegionCount"] as? Int, 2)
        XCTAssertEqual(report["encryptedRegionCount"] as? Int, 0)
        let video = try XCTUnwrap(report["video"] as? [String: Any])
        XCTAssertEqual(video["videoId"] as? Int64, 1_000_002)
        XCTAssertEqual(video["videoFrameIndex"] as? Int, 67)
        XCTAssertEqual(video["chunkKey"] as? String, "chunks/202609/08/1788910058197")
        XCTAssertEqual(video["frameRate"] as? Double, 30.0)
        let segment = try XCTUnwrap(report["segment"] as? [String: Any])
        XCTAssertEqual(segment["appBundleId"] as? String, "com.apple.Terminal")
        XCTAssertEqual(segment["appName"] as? String, "Terminal")
        XCTAssertEqual(segment["windowName"] as? String, "juliusolsson@mac — bringdown-engine")
        let regions = try XCTUnwrap(report["ocrRegions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0]["text"] as? String, "Hello world from Retrace")
        XCTAssertEqual(regions[0]["nodeOrder"] as? Int, 0)
        XCTAssertEqual(regions[0]["leftX"] as? Double ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(regions[1]["text"] as? String, "OCR pipeline lives")
        // OCR text is this command's purpose; unlike export it is included by design.
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains(root.path))
    }

    func testFrameReportsEncryptedRegionsAsPlaceholders() async throws {
        let db = try await initializeFixture()
        defer { sqlite3_close(db) }
        try seedFrame(db: db, encrypted: true)
        let result = await run(["--frame-id", "50000110"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["encryptedRegionCount"] as? Int, 1)
        let regions = try XCTUnwrap(report["ocrRegions"] as? [[String: Any]])
        XCTAssertEqual(regions[0]["text"] as? String, String(repeating: " ", count: 24))
    }

    func testFrameWithoutFTSDocReportsTextUnavailableAndKeepsGeometry() async throws {
        let db = try await initializeFixture()
        defer { sqlite3_close(db) }
        try seedFrame(db: db, withFTS: false)
        let result = await run(["--frame-id", "50000110"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["textAvailable"] as? Bool, false)
        XCTAssertEqual(report["ocrRegionCount"] as? Int, 2)
        let regions = try XCTUnwrap(report["ocrRegions"] as? [[String: Any]])
        XCTAssertEqual(regions[0]["text"] as? String, "")
        XCTAssertEqual(regions[0]["leftX"] as? Double ?? -1, 0.1, accuracy: 0.0001)
    }

    func testUnknownFrameIdFailsCleanly() async throws {
        let db = try await initializeFixture()
        defer { sqlite3_close(db) }
        try seedFrame(db: db)
        let result = await run(["--frame-id", "999999"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual((try json(result)["error"] as? [String: Any])?["code"] as? String, "frame_not_found")
    }

    func testFramePngRefusesSourceRootAndReportsMissingChunk() async throws {
        let db = try await initializeFixture()
        defer { sqlite3_close(db) }
        try seedFrame(db: db)
        let inside = await run(["--frame-id", "50000110", "--png", root.appendingPathComponent("out.png").path])
        XCTAssertEqual(inside.exitCode, 2)
        XCTAssertEqual((try json(inside)["error"] as? [String: Any])?["code"] as? String, "invalid_path")
        let outside = sandbox.appendingPathComponent("extracted.png")
        let missing = await run(["--frame-id", "50000110", "--png", outside.path])
        XCTAssertEqual(missing.exitCode, 3)
        XCTAssertEqual((try json(missing)["error"] as? [String: Any])?["code"] as? String, "image_unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }
}
