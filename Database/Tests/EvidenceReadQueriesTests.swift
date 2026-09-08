import XCTest
import SQLCipher
import Shared
@testable import Database

final class EvidenceReadQueriesTests: XCTestCase {
    private var db: OpaquePointer!
    private var connection: SQLiteConnection!
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_775_300_000))

    override func setUp() async throws {
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        connection = SQLiteConnection(db: db)
        try connection.execute(sql: "PRAGMA foreign_keys = ON")
        try await MigrationRunner(db: db).runMigrations()
        try connection.execute(sql: """
            INSERT INTO segment (id, bundleID, startDate, endDate, windowName, browserUrl, type)
            VALUES (1, 'com.example.Editor', 0, 0, 'Fixture', 'https://example.com', 0),
                   (2, 'com.example.Hidden', 0, 0, 'Hidden', NULL, 0);
            """)
    }

    override func tearDown() {
        connection = nil
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        db = nil
    }

    private func config(textDates: Bool = false, source: FrameSource = .native,
                        minimum: Date? = nil, cutoff: Date? = nil) -> DatabaseConfig {
        DatabaseConfig(dateFormatter: textDates ? DatabaseConfig.rewindDateFormatter : nil,
                       storageRoot: "/fixture", source: source, cutoffDate: cutoff, minimumDate: minimum)
    }

    private func insert(_ id: Int64, at timestamp: Date, config: DatabaseConfig,
                        segmentID: Int64? = 1, status: Int = 2,
                        redaction: String? = nil, rewrite: String? = nil) throws {
        let statement = try XCTUnwrap(connection.prepare(sql: """
            INSERT INTO frame (id, createdAt, imageFileName, segmentId, videoFrameIndex,
                               processingStatus, redactionReason, rewritePurpose)
            VALUES (?, ?, '', ?, 0, ?, ?, ?)
            """))
        defer { connection.finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        // Fixtures bind independently so a production date-binding regression is observable.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let formatter = config.dateFormatter {
            sqlite3_bind_text(statement, 2, formatter.string(from: timestamp), -1, transient)
        } else {
            sqlite3_bind_int64(statement, 2, Int64(timestamp.timeIntervalSince1970 * 1000))
        }
        if let segmentID { sqlite3_bind_int64(statement, 3, segmentID) }
        sqlite3_bind_int(statement, 4, Int32(status))
        if let redaction { sqlite3_bind_text(statement, 5, redaction, -1, transient) }
        if let rewrite { sqlite3_bind_text(statement, 6, rewrite, -1, transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE, String(cString: sqlite3_errmsg(db)))
    }

    func testEmptyDatabase() throws {
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config(), day: day), [])
        XCTAssertEqual(try EvidenceReadQueries.distinctDates(connection: connection, config: config()), [])
    }

    func testHiddenTagResolvedByNameThroughReadConnection() throws {
        // The ID is deliberately different from the migration's built-in tag ID.
        try connection.execute(sql: "DELETE FROM tag; INSERT INTO tag (id, name) VALUES (42, 'hidden');")
        try insert(1, at: day, config: config())
        try insert(2, at: day.addingTimeInterval(1), config: config(), segmentID: 2)
        try connection.execute(sql: "INSERT INTO segment_tag (segmentId, tagId) VALUES (2, 42)")
        try connection.execute(sql: "PRAGMA query_only = ON")
        XCTAssertEqual(try EvidenceReadQueries.hiddenTagID(connection: connection), 42)
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config(), day: day), [1])
    }

    func testMissingHiddenTagDoesNotCreateOne() throws {
        try connection.execute(sql: "DELETE FROM tag")
        try insert(1, at: day, config: config())
        try connection.execute(sql: "PRAGMA query_only = ON")
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config(), day: day), [1])
        XCTAssertNil(try EvidenceReadQueries.hiddenTagID(connection: connection))
    }

    func testVisibilityExcludesDeletionAcrossProcessingStatusesButKeepsRedactions() throws {
        for status in 0...4 {
            try insert(Int64(status + 1), at: day.addingTimeInterval(Double(status)), config: config(),
                       status: status, redaction: "private", rewrite: status == 4 ? "redaction" : nil)
            try insert(Int64(status + 11), at: day.addingTimeInterval(Double(status)), config: config(),
                       status: status, rewrite: "deletion")
        }
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config(), day: day), [1, 2, 3, 4, 5])
    }

    func testLocalDayIncludesStartAndExcludesNextMidnightInMilliseconds() throws {
        try assertDayWindow(config: config())
    }

    func testLocalDayIncludesStartAndExcludesNextMidnightInRewindText() throws {
        try assertDayWindow(config: config(textDates: true, source: .rewind))
    }

    private func assertDayWindow(config: DatabaseConfig) throws {
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: day))
        try insert(1, at: day.addingTimeInterval(-0.001), config: config)
        try insert(2, at: day, config: config)
        try insert(3, at: end.addingTimeInterval(-0.001), config: config)
        try insert(4, at: end, config: config)
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config,
                                                               day: day.addingTimeInterval(3600)), [2, 3])
    }

    func testSourceBoundsIncludeMinimumAndExcludeCutoffForBothTimestampFormats() throws {
        for textDates in [false, true] {
            try connection.execute(sql: "DELETE FROM frame")
            let minimum = day.addingTimeInterval(3600.125)
            let cutoff = day.addingTimeInterval(7200.875)
            let config = config(textDates: textDates, source: textDates ? .rewind : .native,
                                minimum: minimum, cutoff: cutoff)
            try insert(1, at: minimum.addingTimeInterval(-0.001), config: config)
            try insert(2, at: minimum, config: config)
            try insert(3, at: cutoff.addingTimeInterval(-0.001), config: config)
            try insert(4, at: cutoff, config: config)
            XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config, day: day), [2, 3])
            XCTAssertEqual(try EvidenceReadQueries.distinctDates(connection: connection, config: config), [minimum])
        }
    }

    func testRewindDoesNotRequireNativeVisibilityOrTagColumns() throws {
        let rewind = config(textDates: true, source: .rewind)
        try insert(1, at: day, config: rewind, rewrite: "deletion")
        try connection.execute(sql: """
            DROP TABLE segment_tag;
            DROP TABLE tag;
            DROP INDEX idx_frame_rewrite_purpose_status_video;
            ALTER TABLE frame DROP COLUMN rewritePurpose;
            """)
        try connection.execute(sql: "PRAGMA query_only = ON")
        XCTAssertEqual(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: rewind, day: day), [1])
        let frames = try EvidenceReadQueries.timelineFramesInRange(
            from: day, to: day.addingTimeInterval(1), limit: 10, connection: connection, config: rewind
        )
        XCTAssertEqual(frames.map(\.frame.id.value), [1])
    }

    func testReadFailureIsThrownRatherThanReportedAsEmptyEvidence() throws {
        try connection.execute(sql: "DROP TABLE segment_tag; DROP TABLE tag")
        XCTAssertThrowsError(try EvidenceReadQueries.visibleFrameIDs(connection: connection, config: config(), day: day))
    }
}
