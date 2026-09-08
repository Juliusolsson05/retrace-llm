import Foundation
import XCTest
import SQLCipher
import Shared
import Storage
@testable import Database
@testable import RetraceCLI

/// SQLite rows below exercise database mechanics, not recording quality or performance.
final class RetraceCLITests: XCTestCase {
    private var sandbox: URL!
    private var root: URL { sandbox.appendingPathComponent("recordings") }
    private var state: URL { sandbox.appendingPathComponent("cli-state") }
    private var database: URL { root.appendingPathComponent("retrace.db") }

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        sandbox = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("RetraceCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func run(_ command: String = "status", extra: [String] = []) async -> CLIResult {
        await CLICommand.run(arguments: [command, "--storage-root", root.path, "--state-root", state.path] + extra)
    }

    private func json(_ result: CLIResult) throws -> [String: Any] {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        XCTAssertEqual(value["exitCode"] as? Int32, result.exitCode)
        return value
    }

    private func assertError(_ result: CLIResult, _ code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNotEqual(result.exitCode, 0, file: file, line: line)
        XCTAssertEqual((try json(result)["error"] as? [String: Any])?["code"] as? String, code, file: file, line: line)
        XCTAssertFalse(result.stderr.isEmpty, file: file, line: line)
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains(sandbox.path), file: file, line: line)
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

    private func initialize(seed: Bool = false) async throws {
        let db = try openFixture()
        defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }
        // Direct production migrations avoid DatabaseManager startup, defaults and recording access.
        try await MigrationRunner(db: db).runMigrations()
        if seed {
            try exec(db, """
                INSERT INTO video(id,height,width,path,frameRate,processingState) VALUES(1,100,100,'private-opaque-path',0.5,0);
                INSERT INTO frame(id,createdAt,imageFileName,videoId) VALUES(1,1000,'private-opaque-frame',1),(2,4000,'private-opaque-frame',1);
                INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height) VALUES(1,0,0,1,0,0,1,1);
                """)
        }
    }

    private let exportDay = "2026-03-08"

    private var exportStart: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 8))!
    }

    private func initializeEvidence() async throws {
        try await initialize()
        let db = try openFixture()
        defer { sqlite3_close(db) }
        try exec(db, """
            INSERT INTO video(id,height,width,path,frameRate,processingState)
            VALUES(7,100,100,'fixture-video-path-must-not-be-exported',0.5,0);
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type)
            VALUES(1,'com.example.Editor',0,0,'Fixture window','https://example.com',0),
                  (2,'com.example.Hidden',0,0,'Hidden window',NULL,0),
                  (3,'',0,0,NULL,NULL,0);
            DELETE FROM tag;
            INSERT INTO tag(id,name) VALUES(42,'hidden');
            INSERT INTO segment_tag(segmentId,tagId) VALUES(2,42);
            """)
    }

    private func insertEvidence(_ id: Int64, timestampMs: Int64, segmentID: Int64? = 1,
                                status: Int = 2, rewrite: String? = nil) throws {
        let db = try openFixture()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, """
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,
                              processingStatus,redactionReason,rewritePurpose)
            VALUES(?,?,'fixture-frame-path-must-not-be-exported',?,7,12,?,'fixture-redaction',?)
            """, -1, &statement, nil), SQLITE_OK)
        _ = try XCTUnwrap(statement)
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_int64(statement, 2, timestampMs)
        if let segmentID { sqlite3_bind_int64(statement, 3, segmentID) }
        sqlite3_bind_int(statement, 4, Int32(status))
        if let rewrite {
            sqlite3_bind_text(statement, 5, rewrite, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE, String(cString: sqlite3_errmsg(db)))
    }

    private var exportStartMs: Int64 { Int64(exportStart.timeIntervalSince1970 * 1000) }

    private func exportFrames(_ result: CLIResult) throws -> [[String: Any]] {
        if !result.stdout.isEmpty { XCTAssertEqual(result.stdout.last, 0x0A) }
        return try result.stdout.split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func exportSummary(_ result: CLIResult) throws -> [String: Any] {
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 1, result.stderr)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
        XCTAssertEqual(summary["schemaVersion"] as? Int, 1)
        XCTAssertEqual(summary["command"] as? String, "export")
        XCTAssertEqual(summary["exitCode"] as? Int32, result.exitCode)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(summary["elapsedMs"] as? Double), 0)
        return summary
    }

    func testExportLocalDayWindowAndTimestampThenIDOrder() async throws {
        try await initializeEvidence()
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: exportStart))
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        for (id, timestamp) in [(Int64(1), exportStartMs - 1), (4, exportStartMs),
                                (3, exportStartMs), (2, endMs - 1), (5, endMs)] {
            try insertEvidence(id, timestampMs: timestamp)
        }
        let before = try Data(contentsOf: database)
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try exportFrames(result).compactMap { $0["frameId"] as? Int64 }, [3, 4, 2])
        let summary = try exportSummary(result)
        XCTAssertEqual(summary["day"] as? String, exportDay)
        XCTAssertEqual(summary["frameCount"] as? Int, 3)
        XCTAssertEqual(summary["videoCount"] as? Int, 1)
        XCTAssertEqual(summary["segmentCount"] as? Int, 1)
        XCTAssertEqual(summary["limitApplied"] as? Int, 5000)
        XCTAssertEqual(summary["truncated"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
    }

    func testExportHiddenSegmentsMatchStrictEvidenceDayRead() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        try insertEvidence(2, timestampMs: exportStartMs + 1, segmentID: 2)
        try insertEvidence(3, timestampMs: exportStartMs + 2, segmentID: nil)
        let expected = try SourceDatabase.withConnection(root: root) {
            try EvidenceReadQueries.visibleFrameIDs(connection: $0, config: .retrace(storageRoot: root.path), day: exportStart)
        }
        XCTAssertEqual(expected, [1])
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try exportFrames(result).compactMap { $0["frameId"] as? Int64 }, expected)
    }

    func testExportExcludesDeletionRewritesAcrossStatusesAndKeepsRedactions() async throws {
        try await initializeEvidence()
        for status in 0...4 {
            try insertEvidence(Int64(status + 1), timestampMs: exportStartMs + Int64(status), status: status,
                               rewrite: status == 4 ? "redaction" : nil)
            try insertEvidence(Int64(status + 11), timestampMs: exportStartMs + Int64(status), status: status,
                               rewrite: "deletion")
        }
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try exportFrames(result).compactMap { $0["frameId"] as? Int }, [1, 2, 3, 4, 5])
    }

    func testExportJSONLMetadataShapeEscapingAndExplicitNulls() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        try insertEvidence(2, timestampMs: exportStartMs + 1, segmentID: 3)
        let db = try openFixture()
        try exec(db, """
            UPDATE segment SET windowName = 'First' || char(10) || '"Quoted" Ω' WHERE id = 1;
            UPDATE frame SET videoId = NULL, videoFrameIndex = NULL WHERE id = 2;
            """)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        let frames = try exportFrames(result)
        XCTAssertEqual(frames.count, 2)
        let keys: Set<String> = ["schemaVersion", "frameId", "timestampMs", "videoId", "videoFrameIndex",
                                 "segmentId", "appBundleId", "appName", "windowName", "browserUrl"]
        for frame in frames {
            XCTAssertEqual(Set(frame.keys), keys)
            XCTAssertEqual(frame["schemaVersion"] as? Int, 1)
            XCTAssertNotNil(frame["frameId"] as? Int64)
            XCTAssertNotNil(frame["timestampMs"] as? Int64)
            XCTAssertNotNil(frame["segmentId"] as? Int64)
        }
        let populated = try XCTUnwrap(frames.first)
        XCTAssertEqual(populated["timestampMs"] as? Int64, exportStartMs)
        XCTAssertEqual(populated["videoId"] as? Int, 7)
        XCTAssertEqual(populated["videoFrameIndex"] as? Int, 12)
        XCTAssertEqual(populated["segmentId"] as? Int, 1)
        XCTAssertEqual(populated["appBundleId"] as? String, "com.example.Editor")
        // Native segment rows store a bundle ID, not a display name; match DataAdapter's fallback.
        XCTAssertEqual(populated["appName"] as? String, "Editor")
        XCTAssertEqual(populated["windowName"] as? String, "First\n\"Quoted\" Ω")
        XCTAssertEqual(populated["browserUrl"] as? String, "https://example.com")
        let absent = try XCTUnwrap(frames.last)
        for key in ["appBundleId", "appName", "windowName", "browserUrl", "videoId", "videoFrameIndex"] {
            XCTAssertTrue(absent[key] is NSNull, "Expected explicit null for \(key)")
        }
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("must-not-be-exported"))
        XCTAssertEqual(try exportSummary(result)["videoCount"] as? Int, 1)
    }

    func testExportLimitUsesVisibleLookaheadAndDoesNotTruncateExactLimit() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        try insertEvidence(2, timestampMs: exportStartMs + 1, segmentID: 2)
        try insertEvidence(3, timestampMs: exportStartMs + 2, rewrite: "deletion")
        let exact = await run("export", extra: ["--day", exportDay, "--limit", "1"])
        XCTAssertEqual(exact.exitCode, 0)
        XCTAssertEqual(try exportFrames(exact).compactMap { $0["frameId"] as? Int }, [1])
        XCTAssertEqual(try exportSummary(exact)["truncated"] as? Bool, false)
        try insertEvidence(4, timestampMs: exportStartMs + 3)
        let limited = await run("export", extra: ["--day", exportDay, "--limit", "1"])
        XCTAssertEqual(limited.exitCode, 0)
        XCTAssertEqual(try exportFrames(limited).compactMap { $0["frameId"] as? Int }, [1])
        let summary = try exportSummary(limited)
        XCTAssertEqual(summary["frameCount"] as? Int, 1)
        XCTAssertEqual(summary["limitApplied"] as? Int, 1)
        XCTAssertEqual(summary["truncated"] as? Bool, true)
    }

    func testExportDefaultLimitAndMaximumOverride() async throws {
        try await initializeEvidence()
        let db = try openFixture()
        try exec(db, """
            WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM ids WHERE id < 5001)
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex)
            SELECT id, \(exportStartMs) + id, '', 1, 7, id FROM ids;
            """)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let limited = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(limited.exitCode, 0)
        XCTAssertEqual(try exportFrames(limited).count, 5000)
        XCTAssertEqual(try exportSummary(limited)["truncated"] as? Bool, true)
        let maximum = await run("export", extra: ["--day", exportDay, "--limit", "50000"])
        XCTAssertEqual(maximum.exitCode, 0)
        XCTAssertEqual(try exportFrames(maximum).count, 5001)
        XCTAssertEqual(try exportSummary(maximum)["truncated"] as? Bool, false)
    }

    func testExportEmptyDayAndValidLeapDaySucceed() async throws {
        try await initialize()
        for day in [exportDay, "2024-02-29"] {
            let result = await run("export", extra: ["--day", day])
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.stdout.isEmpty)
            let summary = try exportSummary(result)
            XCTAssertEqual(summary["day"] as? String, day)
            for key in ["frameCount", "videoCount", "segmentCount"] { XCTAssertEqual(summary[key] as? Int, 0) }
            XCTAssertEqual(summary["truncated"] as? Bool, false)
        }
    }

    func testExportInvalidDaysLimitsAndFlagsAreUsageErrorsWithoutMetrics() async throws {
        let invalidDays = ["", "2026-3-08", "2026-03-8", "2026-02-29", "2024-02-30", "2026-04-31",
                           "2026-00-01", "2026-13-01", "2026-01-00", "0000-01-01", "26-03-08",
                           "2026-03-08T00:00:00Z", "2026-03-08\n", " 2026-03-08", "２０２６-03-08"]
        let invalidOptions = invalidDays.map { ["--day", $0] } + [
            [], ["--day"], ["--day", exportDay, "--day", exportDay], ["--day", exportDay, "--unknown", "1"],
            ["--day", exportDay, "--limit"], ["--day", exportDay, "--limit", "1", "--limit", "2"]
        ] + ["0", "50001", "-1", "1.5", "many", "99999999999999999999"].map { ["--day", exportDay, "--limit", $0] }
        for extra in invalidOptions {
            let result = await run("export", extra: extra)
            XCTAssertEqual(result.exitCode, 2, "Arguments: \(extra)")
            XCTAssertTrue(result.stdout.isEmpty)
            XCTAssertEqual((try exportSummary(result)["error"] as? [String: Any])?["code"] as? String, "usage")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        for command in ["status", "baseline"] {
            try assertError(await run(command, extra: ["--day", exportDay]), "usage")
            try assertError(await run(command, extra: ["--limit", "1"]), "usage")
        }
        let help = try json(await CLICommand.run(arguments: ["help"]))
        XCTAssertTrue(try XCTUnwrap(help["help"] as? [String]).contains { $0.contains("export --day YYYY-MM-DD") })
    }

    func testExportMetricsRecordOutcomeAndTruncationWithoutContent() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        try insertEvidence(2, timestampMs: exportStartMs + 1)
        let result = await run("export", extra: ["--day", exportDay, "--limit", "1"])
        XCTAssertEqual(result.exitCode, 0)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metricType, metadata FROM daily_metrics ORDER BY id", -1, &statement, nil), SQLITE_OK)
        _ = try XCTUnwrap(statement)
        for outcome in ["started", "succeeded"] {
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            let type = try XCTUnwrap(sqlite3_column_text(statement, 0))
            XCTAssertEqual(String(cString: type), "cli_command")
            let bytes = try XCTUnwrap(sqlite3_column_text(statement, 1))
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: bytes).utf8)) as? [String: Any])
            XCTAssertEqual(metadata["command"] as? String, "export")
            XCTAssertEqual(metadata["outcome"] as? String, outcome)
            XCTAssertEqual(metadata["truncated"] as? Bool, outcome == "succeeded")
            XCTAssertTrue(Set(metadata.keys).isSubset(of: ["command", "outcome", "durationMs", "errorCode", "truncated"]))
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testExportMissingVisibilitySchemaFailsWithoutFrameOutput() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        let db = try openFixture()
        try exec(db, "DROP TABLE segment_tag; DROP TABLE tag;")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(try exportSummary(result)["status"] as? String, "failed")
    }

    func testExportStreamsToWriterAndRecordsFailedOutput() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        try insertEvidence(2, timestampMs: exportStartMs + 1)
        let output = sandbox.appendingPathComponent("export.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: Data()))
        let writer = try FileHandle(forWritingTo: output)
        let arguments = ["export", "--day", exportDay, "--storage-root", root.path, "--state-root", state.path]
        let succeeded = await CLICommand.run(arguments: arguments) { try writer.write(contentsOf: $0) }
        try writer.close()
        XCTAssertEqual(succeeded.exitCode, 0)
        XCTAssertTrue(succeeded.stdout.isEmpty, "Streamed bytes must not be buffered for a second stdout write")
        let bytes = try Data(contentsOf: output)
        let frames = try exportFrames(CLIResult(stdout: bytes, stderr: succeeded.stderr, exitCode: 0))
        XCTAssertEqual(frames.compactMap { $0["frameId"] as? Int }, [1, 2])
        XCTAssertEqual(try exportSummary(succeeded)["frameCount"] as? Int, 2)

        let failingWriter = try FileHandle(forWritingTo: output)
        try failingWriter.truncate(atOffset: 0)
        let failed = await CLICommand.run(arguments: arguments) { line in
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            if frame["frameId"] as? Int == 2 { try failingWriter.close() }
            try failingWriter.write(contentsOf: line)
        }
        XCTAssertEqual(failed.exitCode, 5)
        XCTAssertTrue(failed.stdout.isEmpty)
        let partial = try exportFrames(CLIResult(stdout: Data(contentsOf: output), stderr: failed.stderr, exitCode: 5))
        XCTAssertEqual(partial.compactMap { $0["frameId"] as? Int }, [1])
        let summary = try exportSummary(failed)
        XCTAssertEqual(summary["frameCount"] as? Int, 1)
        XCTAssertEqual(summary["truncated"] as? Bool, false)
        XCTAssertEqual((summary["error"] as? [String: Any])?["code"] as? String, "output_failed")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics ORDER BY id DESC LIMIT 1", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any])
        XCTAssertEqual(metadata["command"] as? String, "export")
        XCTAssertEqual(metadata["outcome"] as? String, "failed")
        XCTAssertEqual(metadata["errorCode"] as? String, "output_failed")
        XCTAssertEqual(metadata["truncated"] as? Bool, false)
    }

    func testExportLiveWALAndMissingSidecarsNeverMutateSource() async throws {
        try await initializeEvidence()
        let writer = try openFixture()
        try exec(writer, """
            PRAGMA journal_mode=WAL;
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex)
            VALUES(1,\(exportStartMs),'',1,7,0);
            """)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let before = try Data(contentsOf: database)
        let walBefore = try Data(contentsOf: wal)
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try exportFrames(result).compactMap { $0["frameId"] as? Int }, [1])
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)

        let checkpointed = try Data(contentsOf: database)
        let unavailable = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(unavailable.exitCode, 3)
        XCTAssertTrue(unavailable.stdout.isEmpty)
        XCTAssertEqual((try exportSummary(unavailable)["error"] as? [String: Any])?["code"] as? String, "database_unreadable")
        XCTAssertEqual(try Data(contentsOf: database), checkpointed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
    }

    func testExportMissingHiddenTagDoesNotCreateOne() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        let db = try openFixture()
        try exec(db, "DELETE FROM segment_tag; DELETE FROM tag;")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try Data(contentsOf: database)
        let result = await run("export", extra: ["--day", exportDay])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try exportFrames(result).compactMap { $0["frameId"] as? Int }, [1])
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testHelpAndUsageContractWithoutFilesystem() async throws {
        let help = await CLICommand.run(arguments: ["help"])
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertNotNil(try json(help)["help"])
        XCTAssertTrue(help.stderr.isEmpty)
        for arguments in [["wat"], ["status", "--unknown"], ["status", "--storage-root"], ["help", "--state-root", state.path]] {
            try assertError(await CLICommand.run(arguments: arguments), "usage")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testStreamingHasherKnownVectorsAcrossOneMiBBoundary() async throws {
        let vectors: [(Data, String, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "a9993e364706816aba3e25717850c26c9cd0d89d"),
            (Data(repeating: 97, count: 1_048_579), "f5e25b6b994188fdb721357d459785dc479934edfd40f95658a45ab2ce2d8027", "f115526df8beeaf0ad6a3c0223b1a546e10425e1")
        ]
        let file = sandbox.appendingPathComponent("hash-vector")
        for (bytes, sha256, sha1) in vectors {
            try bytes.write(to: file)
            let digest = try await SyncFileHasher.hash(file: file)
            XCTAssertEqual(digest.sha256, sha256)
            XCTAssertEqual(digest.sha1, sha1)
            XCTAssertEqual(digest.sizeBytes, Int64(bytes.count))
        }
    }

    func testSyncDryRunPlansNewUnchangedAndRewrittenWithoutManifestWrites() async throws {
        let day = root.appendingPathComponent("chunks/202609/08")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("1")
        try Data("abc".utf8).write(to: file)
        let firstResult = await run("sync", extra: ["--dry-run"])
        XCTAssertEqual(firstResult.exitCode, 0, firstResult.stderr)
        let first = try json(firstResult)
        let uploads = try XCTUnwrap(first["wouldUpload"] as? [[String: Any]])
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?["key"] as? String, "chunks/202609/08/1")
        XCTAssertEqual(uploads.first?["revision"] as? Int, 1)
        XCTAssertEqual(first["bytesTotal"] as? Int, 3)
        XCTAssertEqual(first["objectsTotal"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(SyncManifest.filename).path))

        let digest = try await SyncFileHasher.hash(file: file)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        _ = try await manifest.record(key: "chunks/202609/08/1", sha256: digest.sha256, sizeBytes: 3, mtimeNs: digest.mtimeNs)
        try await manifest.markUploaded(key: "chunks/202609/08/1", revision: 1, uploadedAt: 100, contentTag: "fixture")
        try await manifest.close()
        let manifestURL = state.appendingPathComponent(SyncManifest.filename)
        let before = try Data(contentsOf: manifestURL)
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
        let unchanged = try json(await run("sync", extra: ["--dry-run"]))
        XCTAssertEqual(unchanged["unchangedCount"] as? Int, 1)
        XCTAssertEqual((unchanged["wouldUpload"] as? [Any])?.count, 0)
        XCTAssertEqual((unchanged["wouldReupload"] as? [Any])?.count, 0)
        // Same length and restored mtime must still be detected by content, never a stat shortcut.
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try Data("abd".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attrs[.modificationDate])], ofItemAtPath: file.path)
        let rewritten = try json(await run("sync", extra: ["--dry-run"]))
        let changes = try XCTUnwrap(rewritten["wouldReupload"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["revision"] as? Int, 2)
        XCTAssertNotEqual(changes.first?["sha256"] as? String, digest.sha256)
        XCTAssertEqual(try Data(contentsOf: manifestURL), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: state.path).sorted(), namesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics ORDER BY id DESC LIMIT 1", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let metric = String(cString: sqlite3_column_text(statement, 0))
        XCTAssertTrue(metric.contains("sync"))
        XCTAssertTrue(metric.contains("succeeded"))
        XCTAssertFalse(metric.contains(digest.sha256))
        XCTAssertFalse(metric.contains("chunks/"))
    }

    private func initializePurgeEvidence() async throws -> [String] {
        try await initializeEvidence()
        let keys = ["chunks/202603/07/1772928000000", "chunks/202603/08/1773014400000"]
        for key in keys + ["chunks/202603/08/99"] {
            let file = root.appendingPathComponent(key)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture chunk".utf8).write(to: file)
        }
        let db = try openFixture()
        defer { sqlite3_close(db) }
        try exec(db, """
            UPDATE video SET path='\(keys[0])' WHERE id=7;
            INSERT INTO video(id,height,width,path,frameRate,processingState) VALUES(8,100,100,'\(keys[1])',0.5,0),
                (9,100,100,'chunks/202603/08/99',0.5,0);
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,rewritePurpose)
            VALUES(1,\(exportStartMs),'',1,7,0,NULL),(2,\(exportStartMs + 1),'',1,7,1,'redaction'),
                  (3,\(exportStartMs + 2),'',1,8,0,NULL),(4,\(exportStartMs + 3),'',2,9,0,NULL),
                  (5,\(exportStartMs + 4),'',1,9,1,'deletion'),(6,\(exportStartMs - 1),'',1,9,2,NULL),
                  (7,\(exportStartMs + 5),'',NULL,9,3,NULL),(8,\(exportStartMs + 6),'',1,NULL,0,NULL);
            """)
        return keys
    }

    func testPurgeDayUsesVisibleFramesAndStoredChunkCreationPathsWithoutSourceWrites() async throws {
        let keys = try await initializePurgeEvidence()
        let before = try sourceFingerprint()
        let result = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["purgeDay"] as? String, exportDay)
        XCTAssertEqual(report["frameCount"] as? Int, 4)
        XCTAssertEqual(report["affectedKeys"] as? [String], keys)
        XCTAssertEqual(report["recordedDeletions"] as? Int, 2)
        XCTAssertEqual(try sourceFingerprint(), before)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root, readOnly: true)
        let pending = try await manifest.pendingDeletionKeys()
        XCTAssertEqual(pending, Set(keys))
        try await manifest.close()
    }

    func testPurgeRepeatResetsLocalAcknowledgementAndApplyUsesRecordedDayAfterSourceRemoval() async throws {
        let keys = try await initializePurgeEvidence()
        let first = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let before = try sourceFingerprint()
        let applied = await run("purge-apply", extra: ["--day", exportDay])
        XCTAssertEqual(applied.exitCode, 0, applied.stderr)
        XCTAssertEqual(try json(applied)["appliedLocal"] as? Int, 2)
        XCTAssertEqual(try sourceFingerprint(), before)
        let repeated = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(repeated.exitCode, 0, repeated.stderr)
        XCTAssertEqual(try json(repeated)["recordedDeletions"] as? Int, 0)
        XCTAssertEqual(try stateScalar("SELECT count(*) FROM deletions"), 2)
        XCTAssertEqual(try stateScalar("SELECT sum(appliedLocal) FROM deletions"), 0)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        _ = try await manifest.recordPendingDeletions(keys: [keys[0]], reason: "purge-day:2026-03-09")
        try await manifest.close()
        try FileManager.default.removeItem(at: database) // Simulates app retention after recording intent.
        let afterRetention = await run("purge-apply", extra: ["--day", exportDay])
        XCTAssertEqual(afterRetention.exitCode, 0, afterRetention.stderr)
        XCTAssertEqual(try stateScalar("SELECT sum(appliedLocal) FROM deletions WHERE reason='purge-day:2026-03-08'"), 2)
        XCTAssertEqual(try stateScalar("SELECT sum(appliedLocal) FROM deletions WHERE reason='purge-day:2026-03-09'"), 0)
        let plan = try json(await run("sync", extra: ["--dry-run"]))
        XCTAssertEqual(plan["purgeKeysAffected"] as? [String], keys)
        XCTAssertEqual(plan["suppressedPendingPurges"] as? Int, 2)
    }

    func testSyncSuppressesNewQueuedAndRewrittenPurgesWithoutManifestWrites() async throws {
        let keys = try await initializePurgeEvidence()
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        _ = try await manifest.record(key: keys[0], sha256: String(repeating: "a", count: 64), sizeBytes: 3, mtimeNs: 1)
        try await manifest.markUploaded(key: keys[0], revision: 1, uploadedAt: 1, contentTag: "prior-version")
        _ = try await manifest.recordPendingDeletions(keys: keys, reason: "fixture")
        try await manifest.close()
        let before = try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename))
        let sourceBefore = try sourceFingerprint()
        let result = await run("sync", extra: ["--dry-run"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["suppressedPendingPurges"] as? Int, 2)
        XCTAssertEqual(report["purgeKeysAffected"] as? [String], keys)
        XCTAssertEqual((report["wouldReupload"] as? [Any])?.count, 0)
        XCTAssertEqual((report["wouldUpload"] as? [[String: Any]])?.compactMap { $0["key"] as? String }, ["chunks/202603/08/99"])
        XCTAssertEqual(report["objectsTotal"] as? Int, 1)
        XCTAssertEqual(report["bytesTotal"] as? Int, 13)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename)), before)
        XCTAssertEqual(try sourceFingerprint(), sourceBefore)
    }

    func testPurgeStrictOptionsEmptyDaysAndCommandMetrics() async throws {
        for (command, flag) in [("sync-plan", "--purge-day"), ("purge-apply", "--day")] {
            for options in [[], [flag], [flag, "2026-02-30"], [flag, "2026-3-08"],
                            [flag, exportDay, flag, exportDay], [flag, exportDay, "--dry-run"]] {
                try assertError(await run(command, extra: options), "usage")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        try await initializeEvidence()
        for (command, flag) in [("sync-plan", "--purge-day"), ("purge-apply", "--day")] {
            let result = await run(command, extra: [flag, "2024-02-29"])
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            XCTAssertEqual(try json(result)["affectedKeys"] as? [String], [])
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics ORDER BY id", -1, &statement, nil), SQLITE_OK)
        for command in ["sync-plan", "purge-apply"] {
            for outcome in ["started", "succeeded"] {
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                let bytes = Data(String(cString: sqlite3_column_text(statement, 0)).utf8)
                let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(metadata["command"] as? String, command)
                XCTAssertEqual(metadata["outcome"] as? String, outcome)
                XCTAssertTrue(Set(metadata.keys).isSubset(of: ["command", "outcome", "durationMs"]))
            }
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        let help = try json(await CLICommand.run(arguments: ["help"]))
        let lines = try XCTUnwrap(help["help"] as? [String]).joined(separator: "\n")
        XCTAssertTrue(lines.contains("purge-apply --day"))
        XCTAssertTrue(lines.contains("no file deletion"))
    }

    func testCorruptDeletionLedgerFailsClosedForPlanRecordAndApply() async throws {
        _ = try await initializePurgeEvidence()
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        try await manifest.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        try exec(try XCTUnwrap(db), "ALTER TABLE deletions RENAME COLUMN objectKey TO broken")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try sourceFingerprint()
        for (command, flags) in [("sync", ["--dry-run"]), ("sync-plan", ["--purge-day", exportDay]), ("purge-apply", ["--day", exportDay])] {
            let result = await run(command, extra: flags)
            try assertError(result, "manifest_unavailable")
            XCTAssertEqual(result.exitCode, 3)
            let report = try json(result)
            XCTAssertTrue((report["wouldUpload"] as? [Any] ?? []).isEmpty)
            XCTAssertTrue((report["wouldReupload"] as? [Any] ?? []).isEmpty)
        }
        XCTAssertEqual(try sourceFingerprint(), before)
    }

    private func stateScalar(_ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent(SyncManifest.filename).path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        _ = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    func testPurgeUsesRelativePathAndPathlessTimestampIDsWithoutInventingSequenceDates() async throws {
        try await initializeEvidence()
        try insertEvidence(1, timestampMs: exportStartMs)
        let db = try openFixture()
        let key = "chunks/202603/07/1772928000000"
        try exec(db, "UPDATE video SET path='\(key)'; ALTER TABLE video RENAME COLUMN path TO relativePath")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let relative = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(relative.exitCode, 0, relative.stderr)
        XCTAssertEqual(try json(relative)["affectedKeys"] as? [String], [key], "Absent chunks still need remote deletion intent")
        let writer = try openFixture()
        try exec(writer, "ALTER TABLE video DROP COLUMN relativePath")
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        let before = try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename))
        try assertError(await run("sync-plan", extra: ["--purge-day", exportDay]), "purge_evidence_unavailable")
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename)), before)

        let timestampID = exportStartMs + 3_600_000
        let timestampKey = "chunks/202603/08/\(timestampID)"
        let updater = try openFixture()
        try exec(updater, "UPDATE video SET id=\(timestampID); UPDATE frame SET videoId=\(timestampID)")
        XCTAssertEqual(sqlite3_close(updater), SQLITE_OK)
        let file = root.appendingPathComponent(timestampKey)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        let sourceBefore = try sourceFingerprint()
        let fallback = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(fallback.exitCode, 0, fallback.stderr)
        XCTAssertEqual(try json(fallback)["affectedKeys"] as? [String], [key, timestampKey].sorted())
        XCTAssertEqual(try sourceFingerprint(), sourceBefore)
    }

    func testPurgeRejectsAmbiguousPathsAndOversizedDaysBeforeRecordingAnything() async throws {
        _ = try await initializePurgeEvidence()
        let writer = try openFixture()
        try exec(writer, "UPDATE video SET path='../chunks/202603/07/7' WHERE id=7")
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        try assertError(await run("sync-plan", extra: ["--purge-day", exportDay]), "purge_evidence_unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(SyncManifest.filename).path))
        let db = try openFixture()
        try exec(db, """
            UPDATE video SET path='chunks/202603/07/7' WHERE id=7;
            WITH RECURSIVE ids(id) AS (SELECT 100 UNION ALL SELECT id+1 FROM ids WHERE id<50100)
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex)
            SELECT id,\(exportStartMs),'',1,7,id FROM ids;
            """)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try sourceFingerprint()
        let result = await run("sync-plan", extra: ["--purge-day", exportDay])
        try assertError(result, "purge_day_limit")
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(SyncManifest.filename).path))
        XCTAssertEqual(try sourceFingerprint(), before)
    }

    func testPurgeReadsCommittedWALAndFailsWithoutMissingSidecarRepair() async throws {
        _ = try await initializePurgeEvidence()
        let writer = try openFixture()
        try exec(writer, "PRAGMA journal_mode=WAL; UPDATE video SET path='chunks/202603/06/777' WHERE id=7")
        let before = try sourceFingerprint()
        let result = await run("sync-plan", extra: ["--purge-day", exportDay])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try json(result)["affectedKeys"] as? [String], ["chunks/202603/06/777", "chunks/202603/08/1773014400000"])
        XCTAssertEqual(try sourceFingerprint(), before)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        let afterCheckpoint = try sourceFingerprint()
        let ledgerBefore = try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename))
        try assertError(await run("sync-plan", extra: ["--purge-day", exportDay]), "database_unreadable")
        XCTAssertEqual(try sourceFingerprint(), afterCheckpoint)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(SyncManifest.filename)), ledgerBefore)
    }

    private func sourceFingerprint() throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[file.path] = try Data(contentsOf: file)
            }
        }
        return result
    }

    func testSyncExcludesZeroBytesNoncanonicalNamesAndSymlinks() async throws {
        let day = root.appendingPathComponent("chunks/202402/29")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for (name, bytes) in [("1", 3), ("2", 0), ("01", 4), ("3.tmp", 5)] {
            try Data(repeating: 97, count: bytes).write(to: day.appendingPathComponent(name))
        }
        let invalid = root.appendingPathComponent("chunks/202402/30")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("invalid-day".utf8).write(to: invalid.appendingPathComponent("4"))
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("5"), withDestinationURL: day.appendingPathComponent("1"))
        let result = await run("sync", extra: ["--dry-run"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["objectsTotal"] as? Int, 1)
        XCTAssertEqual(report["bytesTotal"] as? Int, 3)
        XCTAssertEqual(report["incompleteFileCount"] as? Int, 1)
        XCTAssertEqual(report["noncanonicalFileCount"] as? Int, 3)
        XCTAssertEqual(report["noncanonicalDirectoryCount"] as? Int, 1)
        XCTAssertEqual(report["symlinkCount"] as? Int, 1)
    }

    func testSyncRequiresDryRunAndStrictOptions() async throws {
        let disabled = await run("sync")
        XCTAssertEqual(disabled.exitCode, 6)
        try assertError(disabled, "upload_disabled")
        XCTAssertTrue(disabled.stderr.contains("privacy-deletion"))
        XCTAssertTrue(disabled.stderr.contains("snapshot"))
        XCTAssertTrue(disabled.stderr.contains("encryption"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        for options in [["--dry-run", "--dry-run"], ["--dry-run", "true"], ["--unknown"]] {
            try assertError(await run("sync", extra: options), "usage")
        }
        let help = try json(await CLICommand.run(arguments: ["help"]))
        XCTAssertTrue((help["help"] as? [String])?.contains(where: { $0.contains("sync --dry-run") }) == true)
    }

    func testSyncPlanningBudgetAndHardlinksArePartialAndPendingObjectsRemainPlanned() async throws {
        let day = root.appendingPathComponent("chunks/202609/08")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("1")
        try Data("abc".utf8).write(to: file)
        let bounded = try await SyncPlanner.plan(root: root, state: state, maxEntries: 1)
        XCTAssertEqual(bounded.exitCode, 4)
        XCTAssertEqual(bounded.errors["entry_limit"], 1)
        XCTAssertTrue(bounded.wouldUpload.isEmpty)
        let digest = try await SyncFileHasher.hash(file: file)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        _ = try await manifest.record(key: "chunks/202609/08/1", sha256: digest.sha256, sizeBytes: 3, mtimeNs: digest.mtimeNs)
        try await manifest.close()
        let pending = try json(await run("sync", extra: ["--dry-run"]))
        XCTAssertEqual((pending["wouldUpload"] as? [[String: Any]])?.first?["revision"] as? Int, 1)
        XCTAssertEqual(pending["unchangedCount"] as? Int, 0)
        try FileManager.default.linkItem(at: file, to: sandbox.appendingPathComponent("outside-link"))
        let unsafe = await run("sync", extra: ["--dry-run"])
        XCTAssertEqual(unsafe.exitCode, 4)
        let report = try json(unsafe)
        XCTAssertEqual((report["errors"] as? [String: Int])?["unsafe_chunk"], 1)
        XCTAssertEqual(report["objectsTotal"] as? Int, 0)
    }

    func testB2AuthorizeAndUploadUseNativeHeadersAndFileTransport() async throws {
        let transport = B2StubTransport(responses: [
            (200, Self.authorizationJSON),
            (200, #"{"bucketId":"bucket","uploadUrl":"https://upload.example.test/b2api/v4/b2_upload_file","authorizationToken":"upload-token"}"#),
            (200, Self.fileJSON)
        ])
        let client = B2Client(enabled: true, transport: transport, credentials: { B2Credentials(keyID: "fixture-id", applicationKey: "fixture-key") })
        let authorization = try await client.authorize()
        XCTAssertEqual(authorization.accountId, "account")
        let upload = try await client.getUploadURL(authorization: authorization, bucketID: "bucket")
        let file = sandbox.appendingPathComponent("upload-fixture")
        try Data("abc".utf8).write(to: file)
        let result = try await client.uploadFile(upload: upload, fileName: "chunks/a b/å%.mp4", file: file,
                                               sizeBytes: 3, sha1: "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(result.fileId, "file-id")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].request.url?.absoluteString, "https://api.backblazeb2.com/b2api/v4/b2_authorize_account")
        XCTAssertEqual(requests[0].request.httpMethod, "GET")
        XCTAssertEqual(requests[0].request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("fixture-id:fixture-key".utf8).base64EncodedString())
        XCTAssertEqual(requests[1].request.url?.path, "/b2api/v4/b2_get_upload_url")
        XCTAssertEqual(requests[1].request.value(forHTTPHeaderField: "Authorization"), "account-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].request.httpBody)) as? [String: String])
        XCTAssertEqual(body["bucketId"], "bucket")
        let request = requests[2].request
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bz-File-Name"), "chunks/a%20b/%C3%A5%25.mp4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bz-Content-Sha1"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "upload-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Transfer-Encoding"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(requests[2].file, file)
    }

    func testB2DisabledMissingCredentialsAndErrorMapping() async throws {
        let transport = B2StubTransport(responses: [])
        let disabled = B2Client(transport: transport, credentials: { XCTFail("Credentials must be lazy and behind the gate"); return nil })
        do { _ = try await disabled.authorize(); XCTFail("Disabled client sent a request") }
        catch { XCTAssertEqual(error as? B2ClientError, .disabled) }
        let missing = B2Client(enabled: true, transport: transport, credentials: { nil })
        do { _ = try await missing.authorize(); XCTFail("Missing credentials accepted") }
        catch { XCTAssertEqual(error as? B2ClientError, .missingCredentials) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let cases: [(Int, String, B2ClientError)] = [(401, "expired_token", .expiredToken), (401, "bad_auth_token", .badAuthToken),
                                                  (400, "bad_request", .badRequest), (503, "service_unavailable", .retryable)]
        for (status, code, expected) in cases {
            let stub = B2StubTransport(responses: [(status, "{\"status\":\(status),\"code\":\"\(code)\",\"message\":\"must-not-echo-provider-message\"}")])
            let client = B2Client(enabled: true, transport: stub, credentials: { B2Credentials(keyID: "id", applicationKey: "key") })
            do { _ = try await client.authorize(); XCTFail("Expected typed API error") }
            catch {
                XCTAssertEqual(error as? B2ClientError, expected)
                XCTAssertFalse(String(describing: error).contains("must-not-echo"))
            }
        }
    }

    func testB2ListVersionsPaginatesAndDeletionUsesBothIdentifiers() async throws {
        let transport = B2StubTransport(responses: [
            (200, Self.authorizationJSON),
            (200, "{\"files\":[\(Self.fileJSON)],\"nextFileName\":\"next name\",\"nextFileId\":\"next-id\"}"),
            (200, #"{"files":[],"nextFileName":null,"nextFileId":null}"#),
            (200, #"{"fileId":"file-id","fileName":"chunks/one"}"#)
        ])
        let client = B2Client(enabled: true, transport: transport, credentials: { B2Credentials(keyID: "id", applicationKey: "key") })
        let authorization = try await client.authorize()
        let versions = try await client.listFileVersions(authorization: authorization, bucketID: "bucket")
        XCTAssertEqual(versions.map(\.fileId), ["file-id"])
        let deleted = try await client.deleteFileVersion(authorization: authorization, fileID: "file-id", fileName: "chunks/one")
        XCTAssertEqual(deleted.fileId, "file-id")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        let secondPage = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].request.httpBody)) as? [String: Any])
        XCTAssertEqual(secondPage["startFileName"] as? String, "next name")
        XCTAssertEqual(secondPage["startFileId"] as? String, "next-id")
        XCTAssertEqual(secondPage["bucketId"] as? String, "bucket")
        XCTAssertEqual(requests[3].request.url?.path, "/b2api/v4/b2_delete_file_version")
        let deletion = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].request.httpBody)) as? [String: String])
        XCTAssertEqual(deletion, ["fileId": "file-id", "fileName": "chunks/one"])
    }

    private static let authorizationJSON = #"{"accountId":"account","authorizationToken":"account-token","apiInfo":{"storageApi":{"apiUrl":"https://api.example.test","downloadUrl":"https://download.example.test","recommendedPartSize":100000000,"absoluteMinimumPartSize":5000000,"capabilities":["listFiles","writeFiles"]}},"applicationKeyExpirationTimestamp":null}"#
    private static let fileJSON = #"{"fileId":"file-id","fileName":"chunks/one","action":"upload","contentLength":3,"contentSha1":"a9993e364706816aba3e25717850c26c9cd0d89d","uploadTimestamp":1234,"fileInfo":{}}"#

    func testMissingRootMissingDatabaseAndZeroByteDatabaseDoNotCreateSource() async throws {
        try assertError(await run(), "storage_root_missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try assertError(await run(), "database_missing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertTrue(FileManager.default.createFile(atPath: database.path, contents: Data()))
        try assertError(await run(), "database_empty")
        XCTAssertEqual(try Data(contentsOf: database), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
    }

    private func snapshot() async throws -> (URL, [String: Any]) {
        let result = await run("snapshot")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        let path = try XCTUnwrap(report["snapshotPath"] as? String)
        XCTAssertTrue(path.hasPrefix(state.path + "/snapshots/"))
        XCTAssertNotNil(Int64(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))
        return (URL(fileURLWithPath: path), report)
    }

    private func snapshotReadCounts(_ file: URL, frames: Int64, videos: Int64) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_db_readonly(db, "main"), 1)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "ok")
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        statement = nil
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT (SELECT COUNT(*) FROM frame), (SELECT COUNT(*) FROM video)", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), frames)
        XCTAssertEqual(sqlite3_column_int64(statement, 1), videos)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM frame", nil, nil, nil), SQLITE_READONLY)
    }

    func testSnapshotIncludesCommittedWALWhileWriterTransactionRemainsOpen() async throws {
        try await initialize(seed: true)
        let writer = try openFixture()
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); sqlite3_close(writer) }
        try exec(writer, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            BEGIN IMMEDIATE;
            INSERT INTO frame(createdAt,imageFileName) VALUES(9000,'committed-wal');
            COMMIT;
            BEGIN IMMEDIATE;
            INSERT INTO frame(createdAt,imageFileName) VALUES(10000,'uncommitted-wal');
            """)
        let before = try Data(contentsOf: database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        // The DB header alone cannot contain the committed third row: it is still in WAL.
        let naive = sandbox.appendingPathComponent("naive.db")
        try before.write(to: naive)
        try snapshotReadCounts(naive, frames: 2, videos: 1)
        let (file, report) = try await snapshot()
        XCTAssertEqual(report["frameCount"] as? Int, 3)
        XCTAssertEqual(report["videoCount"] as? Int, 1)
        XCTAssertEqual(report["integrity"] as? String, "ok")
        try snapshotReadCounts(file, frames: 3, videos: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [file.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
    }

    func testSnapshotEmptyMigratedSchemaAndUniqueFiles() async throws {
        try await initialize()
        let (file, report) = try await snapshot()
        let (second, _) = try await snapshot()
        XCTAssertNotEqual(file, second)
        XCTAssertEqual(report["frameCount"] as? Int, 0)
        XCTAssertEqual(report["videoCount"] as? Int, 0)
        XCTAssertGreaterThan(try XCTUnwrap(report["sizeBytes"] as? Int), 0)
        XCTAssertEqual((report["sha256"] as? String)?.count, 64)
        try snapshotReadCounts(file, frames: 0, videos: 0)
    }

    func testSnapshotCopiesMultiplePageBatchesAndLockedSourceFailsWithoutArtifacts() async throws {
        try await initialize(seed: true)
        let writer = try openFixture()
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); sqlite3_close(writer) }
        try exec(writer, "CREATE TABLE fixture_payload(value BLOB); INSERT INTO fixture_payload VALUES(zeroblob(2097152))")
        let (file, report) = try await snapshot()
        XCTAssertGreaterThan(try XCTUnwrap(report["sizeBytes"] as? Int), 2_097_152)
        try snapshotReadCounts(file, frames: 2, videos: 1)
        let directory = file.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try exec(writer, "BEGIN EXCLUSIVE")
        let start = ProcessInfo.processInfo.systemUptime
        let locked = await run("snapshot")
        XCTAssertNotEqual(locked.exitCode, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 15)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }

    func testRestoreRejectsCorruptSnapshotWithoutLeavingDatabase() async throws {
        try await initialize()
        let (file, _) = try await snapshot()
        try Data([0]).write(to: file)
        let target = sandbox.appendingPathComponent("restore-corrupt")
        try assertError(await run("restore", extra: ["--snapshot", file.path, "--to", target.path]), "snapshot_integrity_failed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testVerifyUnsafeInputRecordsFailureAndMetricsAliasIsNeverModified() async throws {
        try await initialize()
        let before = try Data(contentsOf: database)
        try assertError(await run("verify", extra: ["--snapshot", database.path]), "unsafe_snapshot")
        let metrics = state.appendingPathComponent("metrics.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metrics.path))
        guard FileManager.default.fileExists(atPath: metrics.path) else { return }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(metrics.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics ORDER BY id", -1, &statement, nil), SQLITE_OK)
        for outcome in ["started", "failed"] {
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            let text = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(metadata["outcome"] as? String, outcome)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let metricsBefore = try Data(contentsOf: metrics)
        try assertError(await run("verify", extra: ["--snapshot", metrics.path]), "unsafe_snapshot")
        XCTAssertEqual(try Data(contentsOf: metrics), metricsBefore)
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testSnapshotVerifyMatchesLineageAndMovedCopyWithoutManifestWrites() async throws {
        try await initialize(seed: true)
        let (file, report) = try await snapshot()
        let manifest = state.appendingPathComponent(SyncManifest.filename)
        let before = try Data(contentsOf: manifest)
        for candidate in [file, sandbox.appendingPathComponent("moved.db")] {
            if candidate != file { try FileManager.default.copyItem(at: file, to: candidate) }
            let result = await run("verify", extra: ["--snapshot", candidate.path])
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            let verified = try json(result)
            XCTAssertEqual(verified["sha256"] as? String, report["sha256"] as? String)
            XCTAssertEqual(verified["checks"] as? [String: String], ["manifest": "match", "sha256": "match", "sizeBytes": "match", "frameCount": "match", "videoCount": "match", "integrity": "match"])
            XCTAssertGreaterThan(try XCTUnwrap(verified["lineageId"] as? Int), 0)
        }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }

    func testVerifyTamperedByteReportsSHA256MismatchEvenWhenDatabaseIsCorrupt() async throws {
        try await initialize(seed: true)
        let (file, _) = try await snapshot()
        let handle = try FileHandle(forUpdating: file)
        try handle.write(contentsOf: Data([0])) // Corrupt SQLite's magic, preserving size.
        try handle.close()
        let result = await run("verify", extra: ["--snapshot", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        let report = try json(result)
        let checks = try XCTUnwrap(report["checks"] as? [String: String])
        XCTAssertEqual(checks["sha256"], "mismatch")
        XCTAssertEqual(checks["sizeBytes"], "match")
        XCTAssertEqual(checks["integrity"], "mismatch")
        XCTAssertEqual(checks["frameCount"], "unavailable")
    }

    func testVerifyReportsEveryManifestFieldMismatchAndMissingLineage() async throws {
        try await initialize(seed: true)
        let (file, _) = try await snapshot()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        try exec(XCTUnwrap(db), "UPDATE snapshots SET sizeBytes=sizeBytes+1, frameCount=frameCount+1, videoCount=videoCount+1")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let result = await run("verify", extra: ["--snapshot", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        let checks = try XCTUnwrap(try json(result)["checks"] as? [String: String])
        for field in ["sizeBytes", "frameCount", "videoCount"] { XCTAssertEqual(checks[field], "mismatch") }
        XCTAssertEqual(checks["sha256"], "match")
        try FileManager.default.removeItem(at: state.appendingPathComponent(SyncManifest.filename))
        let missing = await run("verify", extra: ["--snapshot", file.path])
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertEqual((try json(missing)["checks"] as? [String: String])?["manifest"], "missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(SyncManifest.filename).path))
    }

    func testRestoreOpensReadOnlyWithExpectedCountsAndLeavesSourceUnchanged() async throws {
        try await initialize(seed: true)
        let before = try Data(contentsOf: database)
        let (file, _) = try await snapshot()
        for name in ["new-target", "existing-empty-target"] {
            let target = sandbox.appendingPathComponent(name)
            if name.hasPrefix("existing") { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            let result = await run("restore", extra: ["--snapshot", file.path, "--to", target.path])
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            let report = try json(result)
            XCTAssertEqual(report["integrity"] as? String, "ok")
            XCTAssertEqual(report["frameCount"] as? Int, 2)
            XCTAssertEqual(report["videoCount"] as? Int, 1)
            try snapshotReadCounts(target.appendingPathComponent("retrace.db"), frames: 2, videos: 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["retrace.db"])
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testRestoreRefusesNonemptySourceInsideAndSymlinkTargets() async throws {
        try await initialize(seed: true)
        let (file, _) = try await snapshot()
        let occupied = sandbox.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("sentinel".utf8).write(to: occupied.appendingPathComponent(".keep"))
        try assertError(await run("restore", extra: ["--snapshot", file.path, "--to", occupied.path]), "target_not_empty")
        let alias = sandbox.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        for target in [root, root.appendingPathComponent("restore"), alias.appendingPathComponent("restore")] {
            try assertError(await run("restore", extra: ["--snapshot", file.path, "--to", target.path]), "unsafe_restore_target")
        }
        let empty = sandbox.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let outsideAlias = sandbox.appendingPathComponent("outside-alias")
        try FileManager.default.createSymbolicLink(at: outsideAlias, withDestinationURL: empty)
        try assertError(await run("restore", extra: ["--snapshot", file.path, "--to", outsideAlias.path]), "unsafe_restore_target")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
        XCTAssertEqual(try String(contentsOf: occupied.appendingPathComponent(".keep")), "sentinel")
    }

    func testSnapshotRejectsSourceContainedStateAndSymlinkSnapshotDirectory() async throws {
        try await initialize()
        for destination in [root, root.appendingPathComponent("state")] {
            try assertError(await CLICommand.run(arguments: ["snapshot", "--storage-root", root.path, "--state-root", destination.path]), "unsafe_state_root")
        }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("snapshots"), withDestinationURL: root)
        try assertError(await run("snapshot"), "unsafe_state_root")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
    }

    func testVerifyAndRestoreRefuseSourceSnapshotsAndLinkedFiles() async throws {
        try await initialize()
        let alias = sandbox.appendingPathComponent("alias.db")
        let hardlink = sandbox.appendingPathComponent("hardlink.db")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: database)
        try FileManager.default.linkItem(at: database, to: hardlink)
        for file in [database, alias, hardlink] {
            try assertError(await run("verify", extra: ["--snapshot", file.path]), "unsafe_snapshot")
            try assertError(await run("restore", extra: ["--snapshot", file.path, "--to", sandbox.appendingPathComponent("restore").path]), "unsafe_snapshot")
        }
    }

    func testSnapshotCommandsRecordOnlyCommandOutcomesAndRejectInvalidOptions() async throws {
        for (command, extra) in [("snapshot", ["--snapshot", "x"]), ("verify", []), ("restore", ["--snapshot", "x"]), ("verify", ["--snapshot", "x", "--snapshot", "y"])] {
            try assertError(await run(command, extra: extra), "usage")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        try await initialize()
        let (file, _) = try await snapshot()
        _ = await run("verify", extra: ["--snapshot", file.path])
        _ = await run("restore", extra: ["--snapshot", file.path, "--to", sandbox.appendingPathComponent("restored").path])
        _ = await run("restore", extra: ["--snapshot", file.path, "--to", root.path])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='cli_command' ORDER BY id", -1, &statement, nil), SQLITE_OK)
        for (command, outcomes) in [("snapshot", ["started", "succeeded"]), ("verify", ["started", "succeeded"]), ("restore", ["started", "succeeded"]), ("restore", ["started", "failed"])] {
            for outcome in outcomes {
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                let text = String(cString: sqlite3_column_text(statement, 0))
                let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                XCTAssertEqual(metadata["command"] as? String, command)
                XCTAssertEqual(metadata["outcome"] as? String, outcome)
                XCTAssertFalse(text.contains(sandbox.path))
                XCTAssertTrue(Set(metadata.keys).isSubset(of: ["command", "outcome", "durationMs", "errorCode"]))
            }
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testRejectsMemoryURIAndEmptyPaths() async throws {
        for path in ["", " ", ":memory:", "file:/tmp/retrace?mode=ro", "https://example.com", "fake?mode=memory"] {
            try assertError(await CLICommand.run(arguments: ["status", "--storage-root", path, "--state-root", state.path]), "invalid_path")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSchemaRequiredAndEmptyInitializedDatabaseValid() async throws {
        let db = try openFixture()
        try exec(db, "CREATE TABLE unrelated(id INTEGER)")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try assertError(await run(), "unsupported_schema")
        try FileManager.default.removeItem(at: database)
        try await initialize()
        let report = try json(await run("baseline"))
        XCTAssertEqual(report["status"] as? String, "complete")
        let data = try XCTUnwrap(report["database"] as? [String: Any])
        XCTAssertEqual(data["frameCount"] as? Int, 0)
        XCTAssertTrue(data["firstFrameTimestampMs"] is NSNull)
        XCTAssertTrue(data["lastFrameTimestampMs"] is NSNull)
    }

    func testMissingRequiredColumnAndCorruptDatabaseAreErrors() async throws {
        try await initialize()
        let db = try openFixture()
        try exec(db, "ALTER TABLE video RENAME COLUMN path TO unavailable_path")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try assertError(await run(), "unsupported_schema")
        try FileManager.default.removeItem(at: database)
        XCTAssertTrue(FileManager.default.createFile(atPath: database.path, contents: Data(repeating: 0x41, count: 512)))
        try assertError(await run(), "database_unreadable")
    }

    func testStatusCountsCoverageAndNoSourceOrDefaultsMutation() async throws {
        try await initialize(seed: true)
        let before = try Data(contentsOf: database)
        let defaults = UserDefaults(suiteName: "io.retrace.app")!.dictionaryRepresentation()
        let result = await run()
        XCTAssertEqual(result.exitCode, 0)
        let data = try XCTUnwrap(try json(result)["database"] as? [String: Any])
        XCTAssertEqual(data["frameCount"] as? Int, 2)
        XCTAssertEqual(data["videoCount"] as? Int, 1)
        XCTAssertEqual(data["nodeCount"] as? Int, 1)
        XCTAssertEqual(data["firstFrameTimestampMs"] as? Int, 1000)
        XCTAssertEqual(data["lastFrameTimestampMs"] as? Int, 4000)
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("private-opaque"))
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
        XCTAssertTrue(NSDictionary(dictionary: defaults).isEqual(to: UserDefaults(suiteName: "io.retrace.app")!.dictionaryRepresentation()))
    }

    func testReadOnlyHandleRejectsWritesAndFinalizesStatements() async throws {
        try await initialize(seed: true)
        try SourceDatabase.withConnection(root: root) { connection in
            let handle = try XCTUnwrap(connection.getConnection())
            XCTAssertEqual(sqlite3_db_readonly(handle, "main"), 1)
            XCTAssertThrowsError(try connection.execute(sql: "DELETE FROM frame"))
            _ = try SourceDatabase.aggregate(connection)
            XCTAssertNil(sqlite3_next_stmt(handle, nil))
        }
        // An exclusive writer after closure exercises lock and handle ownership.
        let db = try openFixture()
        defer { sqlite3_close(db) }
        try exec(db, "BEGIN EXCLUSIVE; ROLLBACK;")
    }

    func testSelectFailureIsNotReportedAsZeroCounts() async throws {
        try await initialize()
        try SourceDatabase.withConnection(root: root) { connection in
            let db = try XCTUnwrap(connection.getConnection())
            sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
                action == SQLITE_READ ? SQLITE_DENY : SQLITE_OK
            }, nil)
            XCTAssertThrowsError(try SourceDatabase.aggregate(connection))
            XCTAssertNil(sqlite3_next_stmt(db, nil))
        }
    }

    func testWALWithoutSidecarsFailsWithoutCreatingThem() async throws {
        try await initialize(seed: true)
        let db = try openFixture()
        try exec(db, "PRAGMA journal_mode=WAL;")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try Data(contentsOf: database)
        try assertError(await run(), "database_unreadable")
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retrace.db"])
    }

    func testExistingWALRowsAreIncluded() async throws {
        try await initialize(seed: true)
        let writer = try openFixture()
        defer { sqlite3_close(writer) }
        try exec(writer, "PRAGMA journal_mode=WAL; INSERT INTO frame(createdAt,imageFileName) VALUES(9000,'fixture');")
        let before = try Data(contentsOf: database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        let result = await run()
        XCTAssertEqual(result.exitCode, 0)
        let summary = try XCTUnwrap(try json(result)["database"] as? [String: Any])
        XCTAssertEqual(summary["frameCount"] as? Int, 3)
        XCTAssertEqual(summary["lastFrameTimestampMs"] as? Int, 9000)
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
    }

    func testInventoryExcludesArtifactsSymlinksInvalidDatesAndZeroBytes() async throws {
        try await initialize(seed: true)
        let day = root.appendingPathComponent("chunks/202402/29")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for (name, size) in [("1", 10), ("2", 20), ("3", 0), (".1.rewrite-backup-1", 40), ("2.tmp", 50), ("opaque-secret", 60)] {
            XCTAssertTrue(FileManager.default.createFile(atPath: day.appendingPathComponent(name).path, contents: Data(repeating: 0, count: size)))
        }
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.appendingPathComponent("9").path, contents: Data(repeating: 0, count: 500)))
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("4"), withDestinationURL: outside.appendingPathComponent("9"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("chunks/202403"), withDestinationURL: outside)
        let invalid = root.appendingPathComponent("chunks/202402/30")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: invalid.appendingPathComponent("5").path, contents: Data(repeating: 0, count: 70)))
        let result = await run("baseline")
        XCTAssertEqual(result.exitCode, 0)
        let inventory = try XCTUnwrap(try json(result)["inventory"] as? [String: Any])
        let months = try XCTUnwrap(inventory["months"] as? [[String: Any]])
        XCTAssertEqual(months.count, 1)
        XCTAssertEqual(months[0]["month"] as? String, "2024-02")
        XCTAssertEqual(months[0]["fileCount"] as? Int, 2)
        XCTAssertEqual(months[0]["bytes"] as? Int, 30)
        XCTAssertEqual(inventory["incompleteFileCount"] as? Int, 1)
        XCTAssertEqual(inventory["noncanonicalFileCount"] as? Int, 4)
        XCTAssertEqual(inventory["symlinkCount"] as? Int, 2)
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("opaque-secret"))
    }

    func testInventoryBudgetReportsPartial() async throws {
        try await initialize()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks/202401/01"), withIntermediateDirectories: true)
        let inventory = try await ChunkInventory.scan(root: root, maxEntries: 1)
        XCTAssertEqual(inventory.status, "partial")
        XCTAssertEqual(inventory.errors["entry_limit"], 1)
        XCTAssertLessThanOrEqual(inventory.visitedEntries, 1)
    }

    func testChunksSymlinkReportsPartialWithoutTraversing() async throws {
        try await initialize()
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("chunks"), withDestinationURL: outside)
        let result = await run("baseline")
        XCTAssertEqual(result.exitCode, 4)
        let inventory = try XCTUnwrap(try json(result)["inventory"] as? [String: Any])
        XCTAssertEqual(inventory["visitedEntries"] as? Int, 0)
        XCTAssertEqual(inventory["symlinkCount"] as? Int, 1)
    }

    func testMetricsRejectHardlinkToSourceDatabase() async throws {
        try await initialize()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: database, to: state.appendingPathComponent("metrics.db"))
        let before = try Data(contentsOf: database)
        try assertError(await run(), "unsafe_state_root")
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testMetricsRejectSourceDatabaseSymlinkToMetricsFile() async throws {
        try await initialize()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let destination = state.appendingPathComponent("metrics.db")
        try FileManager.default.moveItem(at: database, to: destination)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: destination)
        let before = try Data(contentsOf: destination)
        try assertError(await run(), "unsafe_state_root")
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testMetricsDoNotCreateDanglingSourceAliasTarget() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = state.appendingPathComponent("metrics.db")
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: destination)
        try assertError(await run(), "unsafe_state_root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testMetricsAreIndependentAndRejectSourceAndSymlinkLocations() async throws {
        try await initialize(seed: true)
        let result = await run()
        XCTAssertEqual(result.exitCode, 0)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metricType, metadata FROM daily_metrics ORDER BY id", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        _ = try XCTUnwrap(stmt)
        for outcome in ["started", "succeeded"] {
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "cli_command")
            let text = String(cString: sqlite3_column_text(stmt, 1))
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(metadata["command"] as? String, "status")
            XCTAssertEqual(metadata["outcome"] as? String, outcome)
            XCTAssertFalse(text.contains(sandbox.path))
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        for destination in [root, root.appendingPathComponent("state")] {
            try assertError(await CLICommand.run(arguments: ["status", "--storage-root", root.path, "--state-root", destination.path]), "unsafe_state_root")
        }
        let alias = sandbox.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state)
        try assertError(await CLICommand.run(arguments: ["status", "--storage-root", root.path, "--state-root", alias.path]), "unsafe_state_root")
    }

    func testMetricsSchemaAcceptsAppEventWithNullMetadata() async throws {
        try await initialize()
        let result = await run()
        XCTAssertEqual(result.exitCode, 0)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        // Exercise the existing app query against the independent CLI store, including
        // V4's optional metadata contract. This connection touches only temporary state.
        try DailyMetricsQueries.recordEvent(db: XCTUnwrap(db), metricType: .cliCommand,
                                           timestamp: Date(timeIntervalSince1970: 1000), metadata: nil)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metricType, metadata FROM daily_metrics WHERE timestamp = 1000000", -1, &statement, nil), SQLITE_OK)
        _ = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "cli_command")
        XCTAssertEqual(sqlite3_column_type(statement, 1), SQLITE_NULL)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}

private actor B2StubTransport: B2Transport {
    struct Recorded: Sendable {
        let request: URLRequest
        let file: URL?
    }
    var requests: [Recorded] = []
    private var responses: [(Int, String)]
    init(responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest, file: URL?) async throws -> (Data, HTTPURLResponse) {
        requests.append(Recorded(request: request, file: file))
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let (status, body) = responses.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(body.utf8), response)
    }
}
