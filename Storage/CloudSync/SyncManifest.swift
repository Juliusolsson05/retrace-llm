import Foundation
import SQLCipher
import Darwin

public enum SyncManifestError: Error, Sendable, Equatable {
    case unsafeStateRoot, unavailable, invalidRecord, missingObject, staleRevision, pendingDeletion, readOnly, closed
}

/// CLI-owned state, deliberately independent of the application's schema and migrations.
/// A key names a logical chunk; SHA-256 identifies its bytes. A rewrite advances its revision.
public actor SyncManifest {
    public static let filename = "sync-manifest.db"

    public enum UploadState: String, Sendable { case pending, uploaded }

    public struct Object: Sendable, Equatable {
        public let key: String
        public let sha256: String
        public let sizeBytes: Int64
        public let mtimeNs: Int64
        public let revision: Int64
        public let uploadState: UploadState
        public let uploadedAt: Int64?
        public let contentTag: String?
    }

    public struct Snapshot: Sendable, Equatable {
        public let id: Int64
        public let createdMs: Int64
        public let sizeBytes: Int64
        public let sha256: String
        public let frameCount: Int64
        public let videoCount: Int64
        public let lineageTag: String
        public let snapshotPath: String
        public let plainSha256: String?
    }

    private var db: OpaquePointer?
    private let readOnly: Bool
    private var isClosed = false

    public static func open(root: URL, sourceRoot: URL, readOnly: Bool = false) async throws -> SyncManifest {
        try await Task.detached { try SyncManifest(root: root, sourceRoot: sourceRoot, readOnly: readOnly) }.value
    }

    private init(root: URL, sourceRoot: URL, readOnly: Bool) throws {
        self.readOnly = readOnly
        guard try Self.validateState(root: root, sourceRoot: sourceRoot, create: !readOnly) else {
            db = nil // An absent manifest is an empty view, never a reason for dry-run DDL.
            return
        }
        let file = root.appendingPathComponent(Self.filename)
        if readOnly {
            var item = stat()
            if lstat(file.path, &item) != 0 {
                guard errno == ENOENT else { throw SyncManifestError.unavailable }
                db = nil
                return
            }
        }
        var handle: OpaquePointer?
        var path = file.path
        var flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        if readOnly {
            guard SyncManifestReadOnlyVFS.registration == SQLITE_OK else { throw SyncManifestError.unavailable }
            // SQLCipher's readonly_shm option also prevents writes to an existing WAL's
            // shared-memory index. Never use immutable mode on a potentially live file.
            var uri = URLComponents()
            uri.scheme = "file"
            uri.path = file.path
            uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "readonly_shm", value: "1"),
                              URLQueryItem(name: "vfs", value: SyncManifestReadOnlyVFS.name)]
            guard let encoded = uri.string else { throw SyncManifestError.unsafeStateRoot }
            path = encoded
            flags |= SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw SyncManifestError.unavailable
        }
        do {
            sqlite3_busy_timeout(handle, 1000)
            // Validate before migration: never replace a damaged/lost ledger with an
            // empty one. Version 0 is the only legacy format without a deletions table.
            _ = try Self.validateDeletionLedger(handle)
            if readOnly {
                try Self.execute(handle, "PRAGMA query_only=ON;")
            } else {
                // DELETE + FULL makes every committed revision durable without a WAL
                // checkpoint dependency; SQLite rolls interrupted transactions back.
                try Self.execute(handle, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
                try Self.execute(handle, """
                    BEGIN IMMEDIATE;
                    CREATE TABLE IF NOT EXISTS objects (
                        key TEXT PRIMARY KEY NOT NULL,
                        sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
                        sizeBytes INTEGER NOT NULL CHECK(sizeBytes >= 0),
                        mtimeNs INTEGER NOT NULL,
                        revision INTEGER NOT NULL CHECK(revision > 0),
                        uploadState TEXT NOT NULL CHECK(uploadState IN ('pending','uploaded')),
                        uploadedAt INTEGER,
                        contentTag TEXT
                    );
                    CREATE TABLE IF NOT EXISTS snapshots (
                        id INTEGER PRIMARY KEY,
                        createdMs INTEGER NOT NULL CHECK(createdMs >= 0),
                        sizeBytes INTEGER NOT NULL CHECK(sizeBytes > 0),
                        sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
                        frameCount INTEGER NOT NULL CHECK(frameCount >= 0),
                        videoCount INTEGER NOT NULL CHECK(videoCount >= 0),
                        lineageTag TEXT NOT NULL,
                        snapshotPath TEXT NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS snapshots_by_path ON snapshots(snapshotPath,createdMs DESC,id DESC);
                    CREATE INDEX IF NOT EXISTS snapshots_by_hash ON snapshots(sha256,createdMs DESC,id DESC);
                    CREATE TABLE IF NOT EXISTS deletions (
                        objectKey TEXT NOT NULL,
                        deletedAtMs INTEGER NOT NULL,
                        reason TEXT NOT NULL,
                        appliedLocal INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY(objectKey, deletedAtMs)
                    );
                    PRAGMA user_version=1;
                    """)
                if try !Self.hasPlainSnapshotHash(handle) {
                    try Self.execute(handle, "ALTER TABLE snapshots ADD COLUMN plainSha256 TEXT CHECK(plainSha256 IS NULL OR length(plainSha256)=64);")
                }
                try Self.execute(handle, "COMMIT;")
            }
            // Validate the shape even when the table has no rows. No app migrations run.
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, "SELECT key,sha256,sizeBytes,mtimeNs,revision,uploadState,uploadedAt,contentTag FROM objects LIMIT 0",
                                     -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw SyncManifestError.unavailable }
            db = handle
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    public func close() throws {
        if let db {
            guard sqlite3_close(db) == SQLITE_OK else { throw SyncManifestError.unavailable }
        }
        db = nil
        isClosed = true
    }

    public func lookup(key: String) throws -> Object? {
        try rows(sql: "SELECT key,sha256,sizeBytes,mtimeNs,revision,uploadState,uploadedAt,contentTag FROM objects WHERE key=?", key: key).first
    }

    public func listPending() throws -> [Object] {
        guard !isClosed else { throw SyncManifestError.closed }
        guard let db else { return [] }
        let hasLedger = try Self.validateDeletionLedger(db)
        // Select queue eligibility in one SQLite snapshot, including purges from
        // other processes. Keep object history without exposing it as queued work.
        let suppression = hasLedger ? " AND NOT EXISTS (SELECT 1 FROM deletions d WHERE d.objectKey=objects.key)" : ""
        return try rows(sql: "SELECT key,sha256,sizeBytes,mtimeNs,revision,uploadState,uploadedAt,contentTag FROM objects WHERE uploadState='pending'"
                        + suppression + " ORDER BY key")
    }

    /// Intent is durable before app retention runs. Retrying the same key/reason
    /// reopens its local acknowledgement without manufacturing another cloud purge.
    /// History in objects is retained so prior revisions/provider versions can be deleted.
    @discardableResult
    public func recordPendingDeletions(keys: [String], reason: String) throws -> Int {
        try transaction { db in
            guard !reason.isEmpty, !reason.contains("\0"),
                  keys.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw SyncManifestError.invalidRecord }
            guard try Self.validateDeletionLedger(db) else { throw SyncManifestError.unavailable }
            var inserted = 0
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for key in Set(keys).sorted() {
                var update: OpaquePointer?
                defer { sqlite3_finalize(update) }
                try Self.prepare(db, "UPDATE deletions SET appliedLocal=0 WHERE objectKey=? AND reason=?", &update)
                try Self.bind(key, to: update, at: 1)
                try Self.bind(reason, to: update, at: 2)
                guard sqlite3_step(update) == SQLITE_DONE else { throw SyncManifestError.unavailable }
                if sqlite3_changes(db) > 0 { continue }
                var latest: OpaquePointer?
                defer { sqlite3_finalize(latest) }
                try Self.prepare(db, "SELECT MAX(deletedAtMs) FROM deletions WHERE objectKey=?", &latest)
                try Self.bind(key, to: latest, at: 1)
                guard sqlite3_step(latest) == SQLITE_ROW else { throw SyncManifestError.unavailable }
                let previous = sqlite3_column_type(latest, 0) == SQLITE_NULL ? -1 : sqlite3_column_int64(latest, 0)
                guard previous < Int64.max else { throw SyncManifestError.invalidRecord }
                let timestamp = max(now, previous + 1)
                guard sqlite3_step(latest) == SQLITE_DONE else { throw SyncManifestError.unavailable }
                var insert: OpaquePointer?
                defer { sqlite3_finalize(insert) }
                try Self.prepare(db, "INSERT INTO deletions(objectKey,deletedAtMs,reason,appliedLocal) VALUES(?,?,?,0)", &insert)
                try Self.bind(key, to: insert, at: 1)
                sqlite3_bind_int64(insert, 2, timestamp)
                try Self.bind(reason, to: insert, at: 3)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SyncManifestError.unavailable }
                inserted += 1
            }
            return inserted
        }
    }

    /// appliedLocal describes only app retention. Until cloud all-version deletion
    /// is implemented, EVERY ledger key remains suppressed, including local applies.
    public func pendingDeletionKeys() throws -> Set<String> {
        try deletionKeys(reason: nil)
    }

    public func isPendingDeletion(key: String) throws -> Bool {
        try pendingDeletionKeys().contains(key)
    }

    /// The reason carries the requested evidence day, which can differ from the
    /// chunk directory day and must survive removal of source frame/video rows.
    public func deletionKeys(reason: String?) throws -> Set<String> {
        guard !isClosed else { throw SyncManifestError.closed }
        guard let db else { return [] }
        guard try Self.validateDeletionLedger(db) else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try Self.prepare(db, "SELECT DISTINCT objectKey FROM deletions" + (reason == nil ? "" : " WHERE reason=?"), &statement)
        if let reason { try Self.bind(reason, to: statement, at: 1) }
        var keys: Set<String> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return keys }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw SyncManifestError.unavailable }
            keys.insert(String(cString: text))
        }
    }

    @discardableResult
    public func markAppliedLocal(keys: [String], reason: String? = nil) throws -> Int {
        try transaction { db in
            guard try Self.validateDeletionLedger(db) else { throw SyncManifestError.unavailable }
            guard keys.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
                  reason?.contains("\0") != true else { throw SyncManifestError.invalidRecord }
            var changed = 0
            for key in Set(keys).sorted() {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try Self.prepare(db, "UPDATE deletions SET appliedLocal=1 WHERE objectKey=? AND appliedLocal=0"
                                 + (reason == nil ? "" : " AND reason=?"), &statement)
                try Self.bind(key, to: statement, at: 1)
                if let reason { try Self.bind(reason, to: statement, at: 2) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncManifestError.unavailable }
                changed += Int(sqlite3_changes(db))
            }
            return changed
        }
    }

    @discardableResult
    public func recordSnapshot(createdMs: Int64, sizeBytes: Int64, sha256: String, frameCount: Int64,
                               videoCount: Int64, lineageTag: String, snapshotPath: String,
                               plainSha256: String? = nil) throws -> Snapshot {
        try transaction { db in
            guard createdMs >= 0, sizeBytes > 0, frameCount >= 0, videoCount >= 0,
                  sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !lineageTag.isEmpty, !lineageTag.contains("\0"), snapshotPath.hasPrefix("/"),
                  !snapshotPath.contains("\0") else { throw SyncManifestError.invalidRecord }
            if let plainSha256 {
                guard plainSha256.utf8.count == 64,
                      plainSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw SyncManifestError.invalidRecord
                }
            }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, """
                INSERT INTO snapshots(createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath,plainSha256)
                VALUES(?,?,?,?,?,?,?,?)
                """, &statement)
            sqlite3_bind_int64(statement, 1, createdMs)
            sqlite3_bind_int64(statement, 2, sizeBytes)
            try Self.bind(sha256, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, frameCount)
            sqlite3_bind_int64(statement, 5, videoCount)
            try Self.bind(lineageTag, to: statement, at: 6)
            try Self.bind(snapshotPath, to: statement, at: 7)
            if let plainSha256 { try Self.bind(plainSha256, to: statement, at: 8) }
            else { sqlite3_bind_null(statement, 8) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncManifestError.unavailable }
            return Snapshot(id: sqlite3_last_insert_rowid(db), createdMs: createdMs, sizeBytes: sizeBytes,
                            sha256: sha256, frameCount: frameCount, videoCount: videoCount,
                            lineageTag: lineageTag, snapshotPath: snapshotPath, plainSha256: plainSha256)
        }
    }

    public func lookupSnapshot(sha256: String, snapshotPath: String) throws -> Snapshot? {
        guard !isClosed else { throw SyncManifestError.closed }
        guard let db else { return nil }
        var table: OpaquePointer?
        defer { sqlite3_finalize(table) }
        try Self.prepare(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='snapshots'", &table)
        let status = sqlite3_step(table)
        // A slice-5 manifest remains readable without migrating during verify/dry-run.
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw SyncManifestError.unavailable }
        let plainColumn = try Self.hasPlainSnapshotHash(db) ? "plainSha256" : "NULL"
        // A known path must match its own latest lineage, even if substituted bytes
        // happen to match another snapshot. Hash fallback permits moved/copied backups.
        for (column, value) in [("snapshotPath", snapshotPath), ("sha256", sha256)] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, """
                SELECT id,createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath,\(plainColumn)
                FROM snapshots WHERE \(column)=? ORDER BY createdMs DESC,id DESC LIMIT 1
                """, &statement)
            try Self.bind(value, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { continue }
            guard result == SQLITE_ROW else { throw SyncManifestError.unavailable }
            func text(_ index: Int32) throws -> String {
                guard let bytes = sqlite3_column_text(statement, index) else { throw SyncManifestError.unavailable }
                return String(cString: bytes)
            }
            return Snapshot(id: sqlite3_column_int64(statement, 0), createdMs: sqlite3_column_int64(statement, 1),
                            sizeBytes: sqlite3_column_int64(statement, 2), sha256: try text(3),
                            frameCount: sqlite3_column_int64(statement, 4), videoCount: sqlite3_column_int64(statement, 5),
                            lineageTag: try text(6), snapshotPath: try text(7),
                            plainSha256: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : try text(8))
        }
        return nil
    }

    @discardableResult
    public func record(key: String, sha256: String, sizeBytes: Int64, mtimeNs: Int64) throws -> Object {
        try transaction { db in
            guard !key.isEmpty, !key.contains("\0"), sizeBytes >= 0,
                  sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw SyncManifestError.invalidRecord
            }
            guard try !isPendingDeletion(key: key) else { throw SyncManifestError.pendingDeletion }
            let old = try lookup(key: key)
            let same = old?.sha256 == sha256
            if same, old?.sizeBytes != sizeBytes { throw SyncManifestError.invalidRecord }
            let revision = try old.map { same ? $0.revision : try Self.nextRevision($0.revision) } ?? 1
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, """
                INSERT INTO objects(key,sha256,sizeBytes,mtimeNs,revision,uploadState,uploadedAt,contentTag)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET
                sha256=excluded.sha256,sizeBytes=excluded.sizeBytes,mtimeNs=excluded.mtimeNs,
                revision=excluded.revision,uploadState=excluded.uploadState,
                uploadedAt=excluded.uploadedAt,contentTag=excluded.contentTag
                """, &statement)
            try Self.bind(key, to: statement, at: 1)
            try Self.bind(sha256, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, sizeBytes)
            sqlite3_bind_int64(statement, 4, mtimeNs)
            sqlite3_bind_int64(statement, 5, revision)
            try Self.bind(same ? old!.uploadState.rawValue : UploadState.pending.rawValue, to: statement, at: 6)
            if same, let time = old?.uploadedAt { sqlite3_bind_int64(statement, 7, time) }
            if same, let tag = old?.contentTag { try Self.bind(tag, to: statement, at: 8) }
            guard sqlite3_step(statement) == SQLITE_DONE, let result = try lookup(key: key) else { throw SyncManifestError.unavailable }
            return result
        }
    }

    @discardableResult
    public func incrementRevision(key: String) throws -> Object {
        try transaction { db in
            guard try !isPendingDeletion(key: key) else { throw SyncManifestError.pendingDeletion }
            guard let old = try lookup(key: key) else { throw SyncManifestError.missingObject }
            let revision = try Self.nextRevision(old.revision)
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, "UPDATE objects SET revision=?,uploadState='pending',uploadedAt=NULL,contentTag=NULL WHERE key=?", &statement)
            sqlite3_bind_int64(statement, 1, revision)
            try Self.bind(key, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE, let result = try lookup(key: key) else { throw SyncManifestError.unavailable }
            return result
        }
    }

    public func markUploaded(key: String, revision: Int64, uploadedAt: Int64, contentTag: String?) throws {
        try transaction { db in
            guard try !isPendingDeletion(key: key) else { throw SyncManifestError.pendingDeletion }
            guard uploadedAt >= 0, contentTag?.contains("\0") != true else { throw SyncManifestError.invalidRecord }
            guard let old = try lookup(key: key) else { throw SyncManifestError.missingObject }
            // An in-flight transfer may complete after a rewrite. Never mark newer bytes uploaded.
            guard old.revision == revision else { throw SyncManifestError.staleRevision }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, "UPDATE objects SET uploadState='uploaded',uploadedAt=?,contentTag=? WHERE key=?", &statement)
            sqlite3_bind_int64(statement, 1, uploadedAt)
            if let contentTag { try Self.bind(contentTag, to: statement, at: 2) }
            try Self.bind(key, to: statement, at: 3)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncManifestError.unavailable }
        }
    }

    private func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard !isClosed else { throw SyncManifestError.closed }
        guard !readOnly else { throw SyncManifestError.readOnly }
        guard let db else { throw SyncManifestError.unavailable }
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            let value = try body(db)
            try Self.execute(db, "COMMIT")
            return value
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func rows(sql: String, key: String? = nil) throws -> [Object] {
        guard !isClosed else { throw SyncManifestError.closed }
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try Self.prepare(db, sql, &statement)
        if let key { try Self.bind(key, to: statement, at: 1) }
        var result: [Object] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw SyncManifestError.unavailable }
            func text(_ column: Int32) throws -> String {
                guard let value = sqlite3_column_text(statement, column) else { throw SyncManifestError.unavailable }
                return String(cString: value)
            }
            guard let uploadState = UploadState(rawValue: try text(5)) else { throw SyncManifestError.unavailable }
            result.append(Object(key: try text(0), sha256: try text(1), sizeBytes: sqlite3_column_int64(statement, 2),
                                 mtimeNs: sqlite3_column_int64(statement, 3), revision: sqlite3_column_int64(statement, 4), uploadState: uploadState,
                                 uploadedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
                                 contentTag: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : try text(7)))
        }
    }

    private static func nextRevision(_ value: Int64) throws -> Int64 {
        guard value > 0, value < Int64.max else { throw SyncManifestError.invalidRecord }
        return value + 1
    }

    private static func validateDeletionLedger(_ db: OpaquePointer) throws -> Bool {
        var version: OpaquePointer?
        defer { sqlite3_finalize(version) }
        try prepare(db, "PRAGMA user_version", &version)
        guard sqlite3_step(version) == SQLITE_ROW else { throw SyncManifestError.unavailable }
        let schemaVersion = sqlite3_column_int(version, 0)
        guard (0...1).contains(schemaVersion), sqlite3_step(version) == SQLITE_DONE else { throw SyncManifestError.unavailable }
        var table: OpaquePointer?
        defer { sqlite3_finalize(table) }
        try prepare(db, "SELECT type FROM sqlite_master WHERE name='deletions'", &table)
        let status = sqlite3_step(table)
        if status == SQLITE_DONE {
            guard schemaVersion == 0 else { throw SyncManifestError.unavailable }
            return false
        }
        guard status == SQLITE_ROW, let type = sqlite3_column_text(table, 0), String(cString: type) == "table",
              sqlite3_step(table) == SQLITE_DONE else { throw SyncManifestError.unavailable }
        var columns: OpaquePointer?
        defer { sqlite3_finalize(columns) }
        try prepare(db, "PRAGMA table_info(deletions)", &columns)
        for (name, type, primaryKey) in [("objectKey", "TEXT", 1), ("deletedAtMs", "INTEGER", 2),
                                          ("reason", "TEXT", 0), ("appliedLocal", "INTEGER", 0)] {
            guard sqlite3_step(columns) == SQLITE_ROW,
                  let actualName = sqlite3_column_text(columns, 1), String(cString: actualName) == name,
                  let actualType = sqlite3_column_text(columns, 2), String(cString: actualType).uppercased() == type,
                  sqlite3_column_int(columns, 3) == 1, sqlite3_column_int(columns, 5) == primaryKey else {
                throw SyncManifestError.unavailable
            }
        }
        guard sqlite3_step(columns) == SQLITE_DONE else { throw SyncManifestError.unavailable }
        var invalid: OpaquePointer?
        defer { sqlite3_finalize(invalid) }
        try prepare(db, """
            SELECT 1 FROM deletions WHERE typeof(objectKey)!='text' OR length(objectKey)=0 OR instr(objectKey,char(0))>0
            OR typeof(deletedAtMs)!='integer' OR deletedAtMs<0
            OR typeof(reason)!='text' OR length(reason)=0 OR instr(reason,char(0))>0
            OR typeof(appliedLocal)!='integer' OR appliedLocal NOT IN (0,1) LIMIT 1
            """, &invalid)
        guard sqlite3_step(invalid) == SQLITE_DONE else { throw SyncManifestError.unavailable }
        return true
    }

    private static func hasPlainSnapshotHash(_ db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(db, "SELECT 1 FROM pragma_table_info('snapshots') WHERE name='plainSha256'", &statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw SyncManifestError.unavailable }
        return result == SQLITE_ROW
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SyncManifestError.unavailable }
    }

    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw SyncManifestError.unavailable }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SyncManifestError.unavailable }
    }

    /// Mirrors CLIStateMetrics: reject source-contained state, symlink components,
    /// hardlinked DB/sidecars and an inverse source-DB symlink into proposed state.
    static func validateState(root: URL, sourceRoot: URL, create: Bool, filenames: [String]? = nil) throws -> Bool {
        guard root.isFileURL, sourceRoot.isFileURL,
              !root.pathComponents.contains(".."), !root.pathComponents.contains(".") else { throw SyncManifestError.unsafeStateRoot }
        let source = try canonicalPath(sourceRoot)
        let state = try canonicalPath(root)
        guard source != "/", state != source, !state.hasPrefix(source + "/") else { throw SyncManifestError.unsafeStateRoot }
        let names = filenames ?? [filename, filename + "-journal", filename + "-wal", filename + "-shm"]
        let sourceDB = try canonicalPath(sourceRoot.appendingPathComponent("retrace.db"))
        guard try !names.contains(where: { try canonicalPath(root.appendingPathComponent($0)) == sourceDB }) else {
            throw SyncManifestError.unsafeStateRoot
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw SyncManifestError.unavailable }
        defer { Darwin.close(directory) }
        for component in root.pathComponents.dropFirst() {
            if create, mkdirat(directory, component, 0o700) != 0, errno != EEXIST { throw SyncManifestError.unavailable }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if !create, errno == ENOENT { return false }
                throw SyncManifestError.unsafeStateRoot
            }
            Darwin.close(directory)
            directory = next
        }
        for name in names {
            var item = stat()
            if fstatat(directory, name, &item, AT_SYMLINK_NOFOLLOW) == 0 {
                guard item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), item.st_nlink == 1 else { throw SyncManifestError.unsafeStateRoot }
            } else if errno != ENOENT { throw SyncManifestError.unavailable }
        }
        return true
    }

    private static func canonicalPath(_ url: URL) throws -> String {
        var path = url.path
        var suffix: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.isEmpty ? base : (base == "/" ? "" : base) + "/" + suffix.reversed().joined(separator: "/")
            }
            guard errno == ENOENT, path != "/" else { throw SyncManifestError.unsafeStateRoot }
            var item = stat()
            if lstat(path, &item) == 0, item.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { throw SyncManifestError.unsafeStateRoot }
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }
}

private enum SyncManifestReadOnlyVFS {
    static let name = "retrace-sync-manifest-readonly"
    // SQLITE_OPEN_READONLY applies to the main DB, but Unix SQLite still opens WAL
    // with CREATE. Mirror the CLI source VFS so even a foreign WAL-mode manifest can
    // never acquire new sidecars during planning. readonly_shm separately forbids
    // writes through shared-memory mapping; missing recovery files fail closed.
    static let registration: Int32 = {
        guard let base = sqlite3_vfs_find(nil) else { return SQLITE_ERROR }
        let wrapper = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        wrapper.initialize(to: base.pointee)
        wrapper.pointee.zName = UnsafePointer(strdup(name))
        wrapper.pointee.pNext = nil
        wrapper.pointee.pAppData = UnsafeMutableRawPointer(base)
        wrapper.pointee.xOpen = { vfs, path, file, flags, outputFlags in
            guard let base = vfs?.pointee.pAppData?.assumingMemoryBound(to: sqlite3_vfs.self) else { return SQLITE_CANTOPEN }
            let readFlags = (flags & ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE))
                | SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW
            return base.pointee.xOpen!(base, path, file, readFlags, outputFlags)
        }
        wrapper.pointee.xDelete = { _, _, _ in SQLITE_READONLY }
        return sqlite3_vfs_register(wrapper, 0)
    }()
}
