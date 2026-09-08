import XCTest
import SQLCipher
import Shared
import Storage
import Search
import Database
@testable import App

final class RetentionManagerTests: XCTestCase {
    private var database: DatabaseManager!
    private var retention: RetentionManager!
    private var db: OpaquePointer!
    private let cutoff = Date(timeIntervalSince1970: 2)

    override func setUp() async throws {
        let path = "file:retention_\(UUID().uuidString)?mode=memory&cache=private"
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = DatabaseManager(databasePath: path, storageRootPath: storageRoot.path)
        // Initialization applies the production schema through MigrationRunner.
        try await database.initialize()
        let connection = await database.getConnection()
        db = try XCTUnwrap(connection)
        retention = RetentionManager(
            database: database,
            storage: StorageManager(storageRoot: storageRoot, crashReportDirectory: storageRoot.path),
            search: SearchManager(database: database, ftsEngine: FTSManager())
        )
    }

    override func tearDown() async throws {
        retention = nil
        try await database?.close()
        database = nil
        db = nil
    }

    func testRetentionCutoffRemovesOCRAndKeepsNewerFrameSearchable() async throws {
        try insertFrame(id: 1, createdAt: 1_000, text: "expiredneedle")
        try insertFrame(id: 2, createdAt: 3_000, text: "recentneedle")
        try insertFrame(id: 3, createdAt: 2_000, text: "boundaryneedle")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredneedle';"), 1)

        let deleted = try await deleteRetainedFrames()

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame WHERE id = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM node WHERE frameId = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking_content WHERE id = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredneedle';"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame;"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM node;"), 2)
        XCTAssertEqual(try searchableFrames("recentneedle"), [2])
        XCTAssertEqual(try searchableFrames("boundaryneedle"), [3])
    }

    func testRetentionKeepsDocumentSharedWithSurvivingFrame() async throws {
        try insertFrame(id: 1, createdAt: 1_000, text: "sharedneedle")
        try execute("""
            INSERT INTO frame(id, createdAt, imageFileName, segmentId) VALUES (2, 3000, 'fixture', 1);
            INSERT INTO doc_segment(docid, segmentId, frameId) VALUES (1, 1, 2);
            """)

        let deleted = try await deleteRetainedFrames()

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 1;"), 1)
        XCTAssertEqual(try searchableFrames("sharedneedle"), [2])
    }

    func testRetentionProtectsExcludedAppsTagsAndHiddenSegments() async throws {
        for id in Int64(1)...6 {
            try insertFrame(id: id, createdAt: 1_000, text: "protectedneedle")
        }
        try execute("""
            UPDATE segment SET bundleID = 'com.example.protected' WHERE id = 2;
            UPDATE segment SET bundleID = 'com.example.second' WHERE id = 3;
            INSERT INTO tag(id, name) VALUES (10, 'Keep'), (11, 'Keep too');
            INSERT INTO segment_tag(segmentId, tagId) VALUES (4, 10), (5, 11);
            UPDATE tag SET name = 'HiDdEn' WHERE name = 'hidden';
            INSERT INTO segment_tag(segmentId, tagId) SELECT 6, id FROM tag WHERE name = 'HiDdEn';
            """)

        let deleted = try await retention.deleteFrames(
            olderThan: cutoff,
            excludingApps: ["com.example.protected", "com.example.second"],
            excludingTagIds: [10, 11],
            excludeHidden: true
        )

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 1;"), 0)
        XCTAssertEqual(try searchableFrames("protectedneedle"), [2, 3, 4, 5, 6])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame;"), 5)
    }

    func testRetentionEmptySelectionDoesNotStartTransaction() async throws {
        try insertFrame(id: 1, createdAt: 3_000, text: "recentneedle")
        let writer = await database.getConnection()
        sqlite3_set_authorizer(writer, { _, operation, _, _, _, _ in
            operation == SQLITE_TRANSACTION ? SQLITE_DENY : SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(writer, nil, nil) }

        let deleted = try await deleteRetainedFrames()

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(try searchableFrames("recentneedle"), [1])
    }

    func testRetentionDeletesAcrossTwoBoundedTransactions() async throws {
        try execute("BEGIN;")
        for id in Int64(1)...501 {
            try insertFrame(id: id, createdAt: 1_000, text: "batchneedle")
        }
        try execute("COMMIT;")
        let commits = CommitCounter()
        let writer = await database.getConnection()
        sqlite3_commit_hook(writer, { context in
            Unmanaged<CommitCounter>.fromOpaque(context!).takeUnretainedValue().count += 1
            return 0
        }, Unmanaged.passUnretained(commits).toOpaque())
        defer {
            sqlite3_commit_hook(writer, nil, nil)
        }

        let deleted = try await deleteRetainedFrames()

        XCTAssertEqual(deleted, 501)
        XCTAssertEqual(commits.count, 2)
        for table in ["frame", "node", "doc_segment", "searchRanking", "searchRanking_content"] {
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM \(table);"), 0, table)
        }
        XCTAssertEqual(try searchableFrames("batchneedle"), [])
    }

    func testDeleteFrameIDsCountsOnlyRowsDeleted() async throws {
        try insertFrame(id: 1, createdAt: 1_000, text: "expiredneedle")
        try insertFrame(id: 2, createdAt: 3_000, text: "recentneedle")

        let deleted = try await database.deleteFrames(ids: [1, 1, 999])

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 1;"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 1;"), 0)
        XCTAssertEqual(try searchableFrames("recentneedle"), [2])
    }

    func testDeleteFrameIDsEmptyInputDoesNotStartTransaction() async throws {
        try insertFrame(id: 1, createdAt: 1_000, text: "untouchedneedle")
        sqlite3_set_authorizer(db, { _, operation, _, _, _, _ in
            operation == SQLITE_TRANSACTION ? SQLITE_DENY : SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(db, nil, nil) }

        let deleted = try await database.deleteFrames(ids: [])

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(try searchableFrames("untouchedneedle"), [1])
    }

    func testDeleteFrameIDsRollsBackOCRAndFramesWhenDeletionFails() async throws {
        try insertFrame(id: 1, createdAt: 1_000, text: "firstneedle")
        try insertFrame(id: 2, createdAt: 1_000, text: "secondneedle")
        try execute("""
            CREATE TRIGGER fail_retention_delete BEFORE DELETE ON frame WHEN OLD.id = 2
            BEGIN SELECT RAISE(ABORT, 'retention deletion failure'); END;
            """)

        do {
            _ = try await database.deleteFrames(ids: [1, 2])
            XCTFail("Expected the frame deletion trigger to abort the batch")
        } catch DatabaseError.queryFailed(_, let underlying) {
            XCTAssertTrue(underlying.contains("retention deletion failure"))
        }

        for table in ["frame", "node", "doc_segment", "searchRanking", "searchRanking_content"] {
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM \(table);"), 2, table)
        }
        XCTAssertEqual(try searchableFrames("firstneedle"), [1])
        XCTAssertEqual(try searchableFrames("secondneedle"), [2])
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
    }

    private func deleteRetainedFrames() async throws -> Int {
        try await retention.deleteFrames(olderThan: cutoff, excludingApps: [], excludingTagIds: [], excludeHidden: false)
    }

    private func insertFrame(id: Int64, createdAt: Int64, text: String) throws {
        try execute("""
            INSERT INTO segment(id, bundleID, startDate, endDate, type) VALUES (\(id), 'com.example.fixture', 0, 4000, 0);
            INSERT INTO frame(id, createdAt, imageFileName, segmentId) VALUES (\(id), \(createdAt), 'fixture', \(id));
            INSERT INTO searchRanking(rowid, text) VALUES (\(id), '\(text)');
            INSERT INTO doc_segment(docid, segmentId, frameId) VALUES (\(id), \(id), \(id));
            INSERT INTO node(frameId, nodeOrder, textOffset, textLength, leftX, topY, width, height)
            VALUES (\(id), 0, 0, \(text.count), 0, 0, 1, 1);
            """)
    }

    private func searchableFrames(_ text: String) throws -> [Int64] {
        try integers("""
            SELECT f.id FROM searchRanking
            JOIN doc_segment ds ON ds.docid = searchRanking.rowid
            JOIN frame f ON f.id = ds.frameId
            WHERE searchRanking MATCH '\(text)' ORDER BY f.id;
            """)
    }

    private func scalar(_ sql: String) throws -> Int64 {
        try XCTUnwrap(integers(sql).first)
    }

    private func integers(_ sql: String) throws -> [Int64] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        var values: [Int64] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(sqlite3_column_int64(statement, 0))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return values
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private final class CommitCounter {
        var count = 0
    }
}
