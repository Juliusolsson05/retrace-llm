import Foundation
import SQLCipher
import Darwin

public enum SyncManifestError: Error, Sendable, Equatable {
    case unsafeStateRoot, unavailable, invalidRecord, missingObject, staleRevision, readOnly, closed
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
                    COMMIT;
                    """)
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
        try rows(sql: "SELECT key,sha256,sizeBytes,mtimeNs,revision,uploadState,uploadedAt,contentTag FROM objects WHERE uploadState='pending' ORDER BY key")
    }

    @discardableResult
    public func recordSnapshot(createdMs: Int64, sizeBytes: Int64, sha256: String, frameCount: Int64,
                               videoCount: Int64, lineageTag: String, snapshotPath: String) throws -> Snapshot {
        try transaction { db in
            guard createdMs >= 0, sizeBytes > 0, frameCount >= 0, videoCount >= 0,
                  sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !lineageTag.isEmpty, !lineageTag.contains("\0"), snapshotPath.hasPrefix("/"),
                  !snapshotPath.contains("\0") else { throw SyncManifestError.invalidRecord }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, """
                INSERT INTO snapshots(createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath)
                VALUES(?,?,?,?,?,?,?)
                """, &statement)
            sqlite3_bind_int64(statement, 1, createdMs)
            sqlite3_bind_int64(statement, 2, sizeBytes)
            try Self.bind(sha256, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, frameCount)
            sqlite3_bind_int64(statement, 5, videoCount)
            try Self.bind(lineageTag, to: statement, at: 6)
            try Self.bind(snapshotPath, to: statement, at: 7)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncManifestError.unavailable }
            return Snapshot(id: sqlite3_last_insert_rowid(db), createdMs: createdMs, sizeBytes: sizeBytes,
                            sha256: sha256, frameCount: frameCount, videoCount: videoCount,
                            lineageTag: lineageTag, snapshotPath: snapshotPath)
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
        // A known path must match its own latest lineage, even if substituted bytes
        // happen to match another snapshot. Hash fallback permits moved/copied backups.
        for (column, value) in [("snapshotPath", snapshotPath), ("sha256", sha256)] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.prepare(db, """
                SELECT id,createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath
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
                            lineageTag: try text(6), snapshotPath: try text(7))
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
    private static func validateState(root: URL, sourceRoot: URL, create: Bool) throws -> Bool {
        guard root.isFileURL, sourceRoot.isFileURL,
              !root.pathComponents.contains(".."), !root.pathComponents.contains(".") else { throw SyncManifestError.unsafeStateRoot }
        let source = try canonicalPath(sourceRoot)
        let state = try canonicalPath(root)
        guard source != "/", state != source, !state.hasPrefix(source + "/") else { throw SyncManifestError.unsafeStateRoot }
        let names = [filename, filename + "-journal", filename + "-wal", filename + "-shm"]
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
