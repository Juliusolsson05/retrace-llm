import Foundation
import Database
import Shared
import SQLCipher

public struct DatabaseSummary: Encodable, Sendable {
    public let frameCount: Int64
    public let videoCount: Int64
    public let nodeCount: Int64
    public let firstFrameTimestampMs: Int64?
    public let lastFrameTimestampMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case frameCount, videoCount, nodeCount, firstFrameTimestampMs, lastFrameTimestampMs
    }

    public func encode(to encoder: Encoder) throws {
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
public struct CLIExportFrame: Encodable, Sendable {
    public let frameId: Int64
    public let timestampMs: Int64
    public let videoId: Int64?
    public let videoFrameIndex: Int64?
    public let segmentId: Int64
    public let appBundleId: String?
    public let windowName: String?
    public let browserUrl: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, frameId, timestampMs, videoId, videoFrameIndex, segmentId
        case appBundleId, appName, windowName, browserUrl
    }

    public func encode(to encoder: Encoder) throws {
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

public enum SourceDatabase {
    public static func withConnection<T>(root: URL, allowMissingVideoPath: Bool = false, _ body: (DatabaseConnection) throws -> T) throws -> T {
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
        try validateSchema(connection, allowMissingVideoPath: allowMissingVideoPath)
        return try body(connection)
    }

    private static func validateSchema(_ connection: DatabaseConnection, allowMissingVideoPath: Bool) throws {
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
                guard columns.allSatisfy({
                    (allowMissingVideoPath && table == "video" && $0.key == "path" && observed["path"] == nil)
                        || observed[$0.key] == $0.value
                }) else { throw schemaError() }
            }
            try statement(connection, "SELECT MAX(version) FROM schema_migrations") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) >= 1 else { throw schemaError() }
            }
        } catch { throw schemaError() }
    }

    private static func schemaError() -> CLIError {
        CLIError("unsupported_schema", "Required native schema is missing or incompatible (schema_migrations, segment, frame, video, node); no migrations were run.")
    }

    public struct FrameOCRRegion: Sendable {
        public let nodeOrder: Int
        public let text: String
        public let leftX: Double
        public let topY: Double
        public let width: Double
        public let height: Double
        public let windowIndex: Int?
    }

    public struct FrameVideoInfo: Sendable {
        public let videoId: Int64
        public let videoFrameIndex: Int?
        public let chunkKey: String
        public let frameRate: Double?
    }

    public struct FrameSegmentInfo: Sendable {
        public let segmentId: Int64
        public let appBundleId: String?
        public let windowName: String?
        public let browserUrl: String?
    }

    public struct FrameEvidence: Sendable {
        public let frameId: Int64
        public let timestampMs: Int64
        public let textAvailable: Bool
        public let video: FrameVideoInfo?
        public let segment: FrameSegmentInfo?
        public var regions: [FrameOCRRegion] = []
        public var encryptedRegionCount = 0
    }

    /// Single-frame evidence: lineage plus OCR regions. Text slicing mirrors the app's
    /// canonical read (Database/Queries/NodeQueries.swift getNodesWithText): the frame's
    /// text blob is searchRanking_content c0||c1 reached via doc_segment, each node
    /// slices SUBSTR(blob, textOffset + 1, textLength), and encrypted nodes yield the
    /// same-length space placeholder instead of their ciphertext.
    public static func frameEvidence(_ connection: DatabaseConnection, frameId: Int64) throws -> FrameEvidence? {
        try statement(connection, """
            SELECT f.id, f.createdAt, f.videoFrameIndex,
                   v.id, v.path, v.frameRate,
                   s.id, NULLIF(s.bundleID, ''), s.windowName, s.browserUrl,
                   ds.docid,
                   n.nodeOrder, n.textOffset, n.textLength, n.leftX, n.topY, n.width, n.height, n.windowIndex,
                   CASE WHEN n.encryptedText IS NOT NULL THEN 1 ELSE 0 END,
                   CASE WHEN n.encryptedText IS NOT NULL THEN printf('%.*c', n.textLength, ' ')
                        ELSE SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength) END
            FROM frame f
            LEFT JOIN video v ON v.id = f.videoId
            LEFT JOIN segment s ON s.id = f.segmentId
            LEFT JOIN doc_segment ds ON ds.frameId = f.id
            LEFT JOIN node n ON n.frameId = f.id
            LEFT JOIN searchRanking_content sc ON sc.id = ds.docid
            WHERE f.id = ?
            ORDER BY n.nodeOrder ASC
            """) { stmt in
            guard sqlite3_bind_int64(stmt, 1, frameId) == SQLITE_OK else {
                throw CLIError("database_query_failed", "Could not bind frame evidence lookup.")
            }
            func text(_ column: Int32) -> String? {
                guard let value = sqlite3_column_text(stmt, column) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(stmt, column))), as: UTF8.self)
            }
            func integer(_ column: Int32) -> Int64? {
                sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
            }
            var evidence: FrameEvidence?
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                guard let id = integer(0), let createdAt = integer(1) else {
                    throw CLIError("database_query_failed", "Frame evidence contains invalid native numeric metadata.")
                }
                if evidence == nil {
                    evidence = FrameEvidence(
                        frameId: id, timestampMs: createdAt,
                        textAvailable: sqlite3_column_type(stmt, 10) != SQLITE_NULL,
                        video: integer(3).map { FrameVideoInfo(videoId: $0, videoFrameIndex: integer(2).map(Int.init), chunkKey: text(4) ?? "", frameRate: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)) },
                        segment: integer(6).map { FrameSegmentInfo(segmentId: $0, appBundleId: text(7), windowName: text(8), browserUrl: text(9)) }
                    )
                }
                if integer(11) != nil {
                    evidence?.regions.append(FrameOCRRegion(
                        nodeOrder: Int(integer(11)!),
                        text: text(20) ?? "",
                        leftX: sqlite3_column_double(stmt, 14), topY: sqlite3_column_double(stmt, 15),
                        width: sqlite3_column_double(stmt, 16), height: sqlite3_column_double(stmt, 17),
                        windowIndex: integer(18).map(Int.init)
                    ))
                    if sqlite3_column_int(stmt, 19) != 0 { evidence?.encryptedRegionCount += 1 }
                }
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else { throw CLIError("database_query_failed", "Frame evidence SELECT did not complete.") }
            return evidence
        }
    }

    public static func aggregate(_ connection: DatabaseConnection) throws -> DatabaseSummary {
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
    public static func exportFrames(
        _ connection: DatabaseConnection,
        config: DatabaseConfig,
        day: Date,
        limit: Int,
        emit: (CLIExportFrame) throws -> Void
    ) throws -> Bool {
        try withVisibleDayRows(connection, config: config, day: day, limit: limit,
            projection: "f.id, f.createdAt, f.videoId, f.videoFrameIndex, f.segmentId, NULLIF(s.bundleID, ''), s.windowName, s.browserUrl"
        ) { stmt in
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

    public struct PurgeEvidence: Sendable {
        public let frameCount: Int
        public let keys: [String]
    }

    /// Read only bounded metadata, never OCR or files. A lookahead beyond the bound
    /// fails the entire command before any deletion intent is committed.
    public static func purgeEvidence(_ connection: DatabaseConnection, config: DatabaseConfig, day: Date,
                              limit: Int = 50_000) throws -> PurgeEvidence {
        var columns: Set<String> = []
        try statement(connection, "SELECT name FROM pragma_table_info('video')") { stmt in
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                guard let text = sqlite3_column_text(stmt, 0) else { throw purgePathError() }
                columns.insert(String(cString: text))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw purgePathError() }
        }
        let path = columns.contains("path") ? "v.path" : "NULL"
        let relativePath = columns.contains("relativePath") ? "v.relativePath" : "NULL"
        return try withVisibleDayRows(connection, config: config, day: day, limit: limit,
            projection: "f.createdAt, f.videoId, \(path), \(relativePath)",
            joins: "LEFT JOIN video v ON f.videoId=v.id"
        ) { stmt in
            var count = 0
            var keys: Set<String> = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                guard count < limit else {
                    throw CLIError("purge_day_limit", "Purge day exceeds 50000 visible frames; no deletion rows were recorded.", exitCode: 4)
                }
                guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
                      [SQLITE_INTEGER, SQLITE_NULL].contains(sqlite3_column_type(stmt, 1)) else { throw purgePathError() }
                count += 1
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                    let videoID = sqlite3_column_int64(stmt, 1)
                    guard videoID > 0 else { throw purgePathError() }
                    var stored: String?
                    for column: Int32 in [2, 3] {
                        if sqlite3_column_type(stmt, column) == SQLITE_NULL { continue }
                        guard sqlite3_column_type(stmt, column) == SQLITE_TEXT,
                              let text = sqlite3_column_text(stmt, column) else { throw purgePathError() }
                        let value = String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(stmt, column))), as: UTF8.self)
                        if !value.isEmpty {
                            // Conflicting paths are ambiguous; do not silently omit one.
                            if let stored, stored != value { throw purgePathError() }
                            stored = value
                        }
                    }
                    let key = try stored ?? timestampChunkKey(videoID)
                    guard ChunkInventory.isCanonicalKey(key) else { throw purgePathError() }
                    keys.insert(key)
                }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw purgePathError() }
            return PurgeEvidence(frameCount: count, keys: keys.sorted())
        }
    }

    private static func timestampChunkKey(_ videoID: Int64) throws -> String {
        // Native video.path stores writer.relativePath, whose filename can differ
        // from the AUTOINCREMENT video.id (SegmentQueries.insert). Always prefer
        // that path: its creation day survives midnight and timezone changes.
        // Pathless legacy timestamp IDs are epoch milliseconds, as generated by
        // StorageManager.createSegmentWriter. Never interpret small DB sequence IDs
        // as 1970 timestamps. No trustworthy path means fail closed for native rows.
        guard (946_684_800_000...253_402_214_399_999).contains(videoID) else { throw purgePathError() }
        let date = Date(timeIntervalSince1970: Double(videoID) / 1000)
        let calendar = Calendar.current
        // Exactly DirectoryManager.segmentURL's calendar and formatting, without
        // calling it (that API creates source directories).
        return String(format: "chunks/%04d%02d/%02d/%lld", calendar.component(.year, from: date),
                      calendar.component(.month, from: date), calendar.component(.day, from: date), videoID)
    }

    private static func purgePathError() -> CLIError {
        CLIError("purge_evidence_unavailable", "Cannot resolve every visible frame's canonical chunk key; no deletion rows were recorded.")
    }

    private static func withVisibleDayRows<T>(
        _ connection: DatabaseConnection, config: DatabaseConfig, day: Date, limit: Int,
        projection: String, joins: String = "", body: (OpaquePointer) throws -> T
    ) throws -> T {
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
            SELECT \(projection)
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(joins)
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
            return try body(stmt)
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

public enum ReadOnlySourceVFS {
    public static let name = "retrace-cli-readonly"
    private static let methodsOffset: Int = {
        let size = Int(sqlite3_vfs_find(nil)!.pointee.szOsFile)
        let alignment = MemoryLayout<UnsafePointer<sqlite3_io_methods>>.alignment
        return (size + alignment - 1) / alignment * alignment
    }()

    private static func originalMethods(_ file: UnsafeMutablePointer<sqlite3_file>) -> UnsafeMutablePointer<UnsafePointer<sqlite3_io_methods>> {
        UnsafeMutableRawPointer(file).advanced(by: methodsOffset).assumingMemoryBound(to: UnsafePointer<sqlite3_io_methods>.self)
    }
    // SQLite's built-in Unix VFS opens WAL with CREATE even for a read-only main DB.
    // This process-lifetime, nondefault VFS denies creation/deletion and forces read-only
    // file opens. readonly_shm=1 separately prevents writes through shared-memory mapping.
    // A missing WAL therefore fails, instead of writing a sidecar or ignoring live WAL.
    public static let registration: Int32 = {
        guard let base = sqlite3_vfs_find(nil) else { return SQLITE_ERROR }
        let wrapper = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        wrapper.initialize(to: base.pointee)
        wrapper.pointee.zName = UnsafePointer(strdup(name))
        wrapper.pointee.pNext = nil
        wrapper.pointee.pAppData = UnsafeMutableRawPointer(base)
        wrapper.pointee.szOsFile = Int32(methodsOffset + MemoryLayout<UnsafePointer<sqlite3_io_methods>>.size)
        wrapper.pointee.xOpen = { vfs, path, file, flags, outputFlags in
            guard let base = vfs?.pointee.pAppData?.assumingMemoryBound(to: sqlite3_vfs.self) else { return SQLITE_CANTOPEN }
            let readFlags = (flags & ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE)) | SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW
            let result = base.pointee.xOpen!(base, path, file, readFlags, outputFlags)
            guard result == SQLITE_OK, let file, let original = file.pointee.pMethods else { return result }
            originalMethods(file).initialize(to: original)
            let guarded = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
            guarded.initialize(to: original.pointee)
            // Unix SQLite reuses a process-wide inode SHM mapping. A writer in the
            // same process can make readonly_shm ineffective on later connections.
            // Explicit READONLY tells the WAL reader never to update read marks;
            // bExtend=0 also forbids growing the shared-memory file.
            guarded.pointee.xShmMap = { file, page, size, _, output in
                guard let file, let map = originalMethods(file).pointee.pointee.xShmMap else { return SQLITE_IOERR }
                let result = map(file, page, size, 0, output)
                return result == SQLITE_OK ? SQLITE_READONLY : result
            }
            guarded.pointee.xShmUnmap = { file, _ in
                guard let file, let unmap = originalMethods(file).pointee.pointee.xShmUnmap else { return SQLITE_IOERR }
                return unmap(file, 0)
            }
            guarded.pointee.xClose = { file in
                guard let file, let guarded = file.pointee.pMethods else { return SQLITE_IOERR }
                let original = originalMethods(file).pointee
                file.pointee.pMethods = original
                let result = original.pointee.xClose!(file)
                UnsafeMutablePointer(mutating: guarded).deallocate()
                return result
            }
            file.pointee.pMethods = UnsafePointer(guarded)
            return SQLITE_OK
        }
        wrapper.pointee.xDelete = { _, _, _ in SQLITE_READONLY }
        return sqlite3_vfs_register(wrapper, 0)
    }()
}
