import Foundation
import Database
import Shared
import SQLCipher

struct DatabaseSummary: Encodable, Sendable {
    let frameCount: Int64
    let videoCount: Int64
    let nodeCount: Int64
    let firstFrameTimestampMs: Int64?
    let lastFrameTimestampMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case frameCount, videoCount, nodeCount, firstFrameTimestampMs, lastFrameTimestampMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameCount, forKey: .frameCount)
        try container.encode(videoCount, forKey: .videoCount)
        try container.encode(nodeCount, forKey: .nodeCount)
        // Null explicitly distinguishes initialized-empty coverage from a missing contract field.
        try container.encode(firstFrameTimestampMs, forKey: .firstFrameTimestampMs)
        try container.encode(lastFrameTimestampMs, forKey: .lastFrameTimestampMs)
    }
}

/// Versioned JSONL wire record. Native rows can precede video assignment, so preserve
/// missing video references as null instead of inventing a usable frame location.
struct CLIExportFrame: Encodable, Sendable {
    let frameId: Int64
    let timestampMs: Int64
    let videoId: Int64?
    let videoFrameIndex: Int64?
    let segmentId: Int64
    let appBundleId: String?
    let windowName: String?
    let browserUrl: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, frameId, timestampMs, videoId, videoFrameIndex, segmentId
        case appBundleId, appName, windowName, browserUrl
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(frameId, forKey: .frameId)
        try container.encode(timestampMs, forKey: .timestampMs)
        try container.encode(videoId, forKey: .videoId)
        try container.encode(videoFrameIndex, forKey: .videoFrameIndex)
        try container.encode(segmentId, forKey: .segmentId)
        try container.encode(appBundleId, forKey: .appBundleId)
        // No display name is stored in segment; use DataAdapter's metadata fallback
        // without consulting NSWorkspace, installed apps, or any other source.
        try container.encode(appBundleId?.components(separatedBy: ".").last, forKey: .appName)
        try container.encode(windowName, forKey: .windowName)
        try container.encode(browserUrl, forKey: .browserUrl)
    }
}

enum SourceDatabase {
    static func withConnection<T>(root: URL, _ body: (DatabaseConnection) throws -> T) throws -> T {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw CLIError("storage_root_missing", "Storage root does not exist. Pass --storage-root PATH to an existing Retrace storage directory.")
        }
        guard isDirectory.boolValue else { throw CLIError("invalid_path", "Storage root must be a directory.", exitCode: 2) }
        let database = root.appendingPathComponent("retrace.db")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: database.path) else {
            throw CLIError("database_missing", "No readable retrace.db exists under the supplied storage root; no database was created.")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError("database_unreadable", "retrace.db must be a regular file, not a symlink or directory.")
        }
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw CLIError("database_empty", "retrace.db is zero bytes and is not an initialized native database.")
        }
        // The existing factory consults Keychain when this setting is enabled. Stage 0 must
        // remain noninteractive and key-free; never change the preference to bypass it.
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard !(defaults.object(forKey: "encryptionEnabled") as? Bool ?? false) else {
            throw CLIError("encryption_unavailable", "Encryption-enabled configuration requires a later noninteractive connection API; no keys were requested.")
        }
        var components = URLComponents(url: database, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"),
                                 URLQueryItem(name: "readonly_shm", value: "1"),
                                 URLQueryItem(name: "vfs", value: ReadOnlySourceVFS.name)]
        let connection: DatabaseConnection
        do {
            guard ReadOnlySourceVFS.registration == SQLITE_OK else { throw CLIError("database_unreadable", "Read-only source VFS unavailable.") }
            connection = try SQLiteReadOnlyConnectionFactory.makeRetraceConnection(databasePath: components.string!)
        } catch {
            // Existing errors can contain paths or SQL/key material. Only this fixed diagnostic
            // crosses the CLI boundary; SELECT failures never turn into empty success results.
            throw CLIError("database_unreadable", "Cannot open the existing database read-only. Check permissions, format and existing WAL/SHM sidecars; no repair was attempted.")
        }
        guard let handle = connection.getConnection() else { throw CLIError("database_unreadable", "Database handle unavailable.") }
        // The factory wrappers do not own/close handles. Every statement below is finalized
        // before this scope ends, including errors. close_v2 also safely handles thrown callers.
        defer { sqlite3_close_v2(handle) }
        try validateSchema(connection)
        return try body(connection)
    }

    private static func validateSchema(_ connection: DatabaseConnection) throws {
        // Validate the minimum native contract, not every later app migration. No text/path
        // values are fetched. Types distinguish native integer timestamps from Rewind TEXT.
        let required: [String: [String: String]] = [
            "schema_migrations": ["version": "INTEGER"],
            "segment": ["id": "INTEGER", "startDate": "INTEGER", "endDate": "INTEGER", "bundleID": "TEXT"],
            "frame": ["id": "INTEGER", "createdAt": "INTEGER", "imageFileName": "TEXT", "segmentId": "INTEGER", "videoId": "INTEGER"],
            "video": ["id": "INTEGER", "path": "TEXT", "fileSize": "INTEGER", "width": "INTEGER", "height": "INTEGER", "frameRate": "REAL", "processingState": "INTEGER"],
            "node": ["id": "INTEGER", "frameId": "INTEGER", "nodeOrder": "INTEGER", "textOffset": "INTEGER", "textLength": "INTEGER"]
        ]
        do {
            for (table, columns) in required {
                // Table names here are compile-time allowlisted identifiers, never user input.
                try statement(connection, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)'") { stmt in
                    guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) == 1 else { throw schemaError() }
                }
                var observed: [String: String] = [:]
                try statement(connection, "SELECT name, type FROM pragma_table_info('\(table)')") { stmt in
                    var result = sqlite3_step(stmt)
                    while result == SQLITE_ROW {
                        observed[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1)).uppercased()
                        result = sqlite3_step(stmt)
                    }
                    guard result == SQLITE_DONE else { throw schemaError() }
                }
                guard columns.allSatisfy({ observed[$0.key] == $0.value }) else { throw schemaError() }
            }
            try statement(connection, "SELECT MAX(version) FROM schema_migrations") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) >= 1 else { throw schemaError() }
            }
        } catch { throw schemaError() }
    }

    private static func schemaError() -> CLIError {
        CLIError("unsupported_schema", "Required native schema is missing or incompatible (schema_migrations, segment, frame, video, node); no migrations were run.")
    }

    static func aggregate(_ connection: DatabaseConnection) throws -> DatabaseSummary {
        // One statement gives internally consistent counts/coverage at SQLite's read snapshot.
        try statement(connection, """
            SELECT COUNT(*), (SELECT COUNT(*) FROM video), (SELECT COUNT(*) FROM node),
                   MIN(createdAt), MAX(createdAt), COUNT(CASE WHEN typeof(createdAt) != 'integer' THEN 1 END)
            FROM frame
            """) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 5) == 0 else {
                throw CLIError("database_query_failed", "Aggregate SELECT failed or native frame timestamps are invalid.")
            }
            let result = DatabaseSummary(frameCount: sqlite3_column_int64(stmt, 0), videoCount: sqlite3_column_int64(stmt, 1),
                                         nodeCount: sqlite3_column_int64(stmt, 2),
                                         firstFrameTimestampMs: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
                                         lastFrameTimestampMs: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CLIError("database_query_failed", "Aggregate SELECT did not complete.") }
            return result
        }
    }

    /// Streams at most limit rows and returns whether another visible row exists.
    /// visibleFrameIDs is intentionally unbounded; reuse its visibility helpers and
    /// strict day predicates here so the CLI never materializes an entire day's IDs.
    static func exportFrames(
        _ connection: DatabaseConnection,
        config: DatabaseConfig,
        day: Date,
        limit: Int,
        emit: (CLIExportFrame) throws -> Void
    ) throws -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CLIError("database_query_failed", "Could not determine the next local midnight.")
        }
        // The hidden-tag lookup and frame SELECT must observe the same snapshot. This
        // deferred read transaction does not create journals or reserve a writer lock.
        try connection.beginTransaction()
        defer { try? connection.rollback() }
        let hiddenTagID = try EvidenceReadQueries.hiddenTagID(connection: connection)
        let boundary = EvidenceReadQueries.buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        var clauses = ["f.createdAt >= ?", "f.createdAt < ?"]
        if let visibility = EvidenceReadQueries.nativeVisibleFrameClause(isRewindDatabase: false) {
            clauses.append(visibility)
        }
        if let boundaryClause = boundary.clause { clauses.append(boundaryClause) }
        if hiddenTagID != nil {
            clauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId AND st_hidden.tagId = ?
                )
                """)
        }
        return try statement(connection, """
            SELECT f.id, f.createdAt, f.videoId, f.videoFrameIndex, f.segmentId,
                   NULLIF(s.bundleID, ''), s.windowName, s.browserUrl
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY f.createdAt ASC, f.id ASC
            LIMIT ?
            """) { stmt in
            config.bindDate(start, to: stmt, at: 1)
            config.bindDate(end, to: stmt, at: 2)
            var index: Int32 = 3
            for date in boundary.bindValues {
                config.bindDate(date, to: stmt, at: index)
                index += 1
            }
            if let hiddenTagID {
                sqlite3_bind_int64(stmt, index, hiddenTagID)
                index += 1
            }
            sqlite3_bind_int64(stmt, index, Int64(limit) + 1)
            var count = 0
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                if count == limit { return true }
                // SQLite affinity permits malformed values even in INTEGER columns.
                // Preserve raw milliseconds and IDs; never silently coerce bad evidence.
                guard [Int32(0), 1, 4].allSatisfy({ sqlite3_column_type(stmt, $0) == SQLITE_INTEGER }),
                      [Int32(2), 3].allSatisfy({ [SQLITE_INTEGER, SQLITE_NULL].contains(sqlite3_column_type(stmt, $0)) }) else {
                    throw CLIError("database_query_failed", "Frame evidence contains invalid native numeric metadata.")
                }
                func text(_ column: Int32) -> String? {
                    guard let value = sqlite3_column_text(stmt, column) else { return nil }
                    // Length-based decoding preserves embedded NULs in stored metadata.
                    return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(stmt, column))), as: UTF8.self)
                }
                try emit(CLIExportFrame(
                    frameId: sqlite3_column_int64(stmt, 0), timestampMs: sqlite3_column_int64(stmt, 1),
                    videoId: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2),
                    videoFrameIndex: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
                    segmentId: sqlite3_column_int64(stmt, 4), appBundleId: text(5), windowName: text(6), browserUrl: text(7)
                ))
                count += 1
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else { throw CLIError("database_query_failed", "Frame evidence SELECT did not complete.") }
            return false
        }
    }

    private static func statement<T>(_ connection: DatabaseConnection, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let prepared: OpaquePointer?
        do { prepared = try connection.prepare(sql: sql) }
        catch { throw CLIError("database_query_failed", "Could not prepare metadata SELECT.") }
        defer { connection.finalize(prepared) }
        guard let prepared, sqlite3_stmt_readonly(prepared) != 0 else {
            throw CLIError("database_query_failed", "Expected a read-only metadata SELECT.")
        }
        return try body(prepared)
    }
}

enum ReadOnlySourceVFS {
    static let name = "retrace-cli-readonly"
    // SQLite's built-in Unix VFS opens WAL with CREATE even for a read-only main DB.
    // This process-lifetime, nondefault VFS denies creation/deletion and forces read-only
    // file opens. readonly_shm=1 separately prevents writes through shared-memory mapping.
    // A missing WAL therefore fails, instead of writing a sidecar or ignoring live WAL.
    static let registration: Int32 = {
        guard let base = sqlite3_vfs_find(nil) else { return SQLITE_ERROR }
        let wrapper = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        wrapper.initialize(to: base.pointee)
        wrapper.pointee.zName = UnsafePointer(strdup(name))
        wrapper.pointee.pNext = nil
        wrapper.pointee.pAppData = UnsafeMutableRawPointer(base)
        wrapper.pointee.xOpen = { vfs, path, file, flags, outputFlags in
            guard let base = vfs?.pointee.pAppData?.assumingMemoryBound(to: sqlite3_vfs.self) else { return SQLITE_CANTOPEN }
            let readFlags = (flags & ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE)) | SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW
            return base.pointee.xOpen!(base, path, file, readFlags, outputFlags)
        }
        wrapper.pointee.xDelete = { _, _, _ in SQLITE_READONLY }
        return sqlite3_vfs_register(wrapper, 0)
    }()
}
