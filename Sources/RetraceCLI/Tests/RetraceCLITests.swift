import Foundation
import XCTest
import SQLCipher
import Shared
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
