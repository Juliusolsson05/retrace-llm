import Foundation
import Database
import SQLCipher
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owned by a single command worker. No DatabaseManager, source connection, app migrations
/// or defaults writes: this table exists solely in independent CLI state.
final class CLIStateMetrics {
    private let db: OpaquePointer

    init(root: URL, sourceRoot: URL) throws {
        let state = root
        let source = try Self.canonicalPath(sourceRoot)
        let stateCanonical = try Self.canonicalPath(state)
        guard stateCanonical != source, !stateCanonical.hasPrefix(source + "/"), source != "/" else {
            throw Self.unsafePath()
        }
        let filenames = ["metrics.db", "metrics.db-journal", "metrics.db-wal", "metrics.db-shm"]
        let sourceDatabase = try Self.canonicalPath(sourceRoot.appendingPathComponent("retrace.db"))
        // The source itself might be a symlink pointing OUT to proposed state. Reject that
        // inverse alias before initialization can create a table in what is still source data.
        guard try !filenames.contains(where: { try Self.canonicalPath(state.appendingPathComponent($0)) == sourceDatabase }) else {
            throw Self.unsafePath()
        }
        // Walk each directory component with O_NOFOLLOW instead of resolving symlinks and
        // subsequently writing to their targets. In particular --state-root never aliases source.
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.unavailable() }
        defer { close(directory) }
        for component in state.pathComponents.dropFirst() {
            if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST { throw Self.unavailable() }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.unsafePath() }
            close(directory)
            directory = next
        }
        for name in filenames {
            var item = stat()
            if fstatat(directory, name, &item, AT_SYMLINK_NOFOLLOW) == 0 {
                // Hardlinks could alias retrace.db even though their path lies outside root.
                guard item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), item.st_nlink == 1 else { throw Self.unsafePath() }
            } else if errno != ENOENT { throw Self.unavailable() }
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(state.appendingPathComponent("metrics.db").path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw Self.unavailable()
        }
        sqlite3_busy_timeout(handle, 1000)
        // Match V4's event schema so existing daily-metrics queries can read this
        // independent store without a CLI-specific column or nullability contract.
        guard sqlite3_exec(handle, """
                CREATE TABLE IF NOT EXISTS daily_metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, metricType TEXT NOT NULL,
                    timestamp INTEGER NOT NULL, metadata TEXT
                );
                CREATE INDEX IF NOT EXISTS index_daily_metrics_on_type_timestamp
                ON daily_metrics(metricType, timestamp);
                """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw Self.unavailable()
        }
        db = handle
    }

    deinit { sqlite3_close_v2(db) }

    func record(command: String, outcome: String, durationMs: Double? = nil, errorCode: String? = nil,
                truncated: Bool? = nil, bytesUploaded: Int64? = nil, objectsUploaded: Int? = nil,
                deletes: Int? = nil, suppressedCount: Int? = nil) throws {
        struct Metadata: Encodable {
            let command: String
            let outcome: String
            let durationMs: Double?
            let errorCode: String?
            let truncated: Bool?
            let bytesUploaded: Int64?
            let objectsUploaded: Int?
            let deletes: Int?
            let suppressedCount: Int?
        }
        let metadata = try JSONEncoder().encode(Metadata(command: command, outcome: outcome, durationMs: durationMs,
                                                       errorCode: errorCode, truncated: truncated, bytesUploaded: bytesUploaded,
                                                       objectsUploaded: objectsUploaded, deletes: deletes, suppressedCount: suppressedCount))
        let text = String(decoding: metadata, as: UTF8.self)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable()
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, DailyMetricsQueries.MetricType.cliCommand.rawValue, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, Int64(Date().timeIntervalSince1970 * 1000)) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, text, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw Self.unavailable() }
    }

    private static func unsafePath() -> CLIError {
        CLIError("unsafe_state_root", "CLI state must be outside source storage, with no symlink components or hardlinked metric files. Choose another --state-root.", exitCode: 2)
    }

    static func canonicalPath(_ url: URL) throws -> String {
        var path = url.path
        var suffix: [String] = []
        // Resolve the existing ancestor even when the requested source/state is missing.
        // POSIX realpath preserves the physical /private prefix, unlike Foundation here.
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.isEmpty ? base : (base == "/" ? "" : base) + "/" + suffix.reversed().joined(separator: "/")
            }
            guard errno == ENOENT, path != "/" else { throw unsafePath() }
            var item = stat()
            // A dangling source symlink might target the not-yet-created metrics store.
            // Reject it rather than treating its unresolved name as an independent path.
            if lstat(path, &item) == 0, item.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { throw unsafePath() }
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static func unavailable() -> CLIError {
        CLIError("metrics_unavailable", "Independent CLI metrics state could not be opened or written; check --state-root.", exitCode: 5)
    }
}
