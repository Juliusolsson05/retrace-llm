import Foundation
import SQLCipher
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RetraceKit

/// SQLITE_TRANSIENT — SQLite copies bound strings; Swift bridges call-scoped buffers.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One classified stretch of work. Deterministic identity: only the recording's frame
/// ids and bounds — a re-run classifying the same evidence replaces, never duplicates.
public struct AttributionRecord: Sendable, Equatable {
    public let id: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let appBundleId: String?
    public let windowName: String?
    public let browserUrl: String?
    public let frameIds: [Int64]
    public let project: String
    public let activity: String
    public let confidence: Double
    public let model: String
    public let classifiedAtMs: Int64

    public var durationMs: Int64 { max(0, endedAtMs - startedAtMs) }

    public init(id: String, startedAtMs: Int64, endedAtMs: Int64, appBundleId: String?, windowName: String?,
                browserUrl: String?, frameIds: [Int64], project: String, activity: String,
                confidence: Double, model: String, classifiedAtMs: Int64) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.appBundleId = appBundleId
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.frameIds = frameIds
        self.project = project
        self.activity = activity
        self.confidence = confidence
        self.model = model
        self.classifiedAtMs = classifiedAtMs
    }
}

/// The harness's own state: classifications plus its resume checkpoint, in a SQLite
/// store under a state root that must live outside the recording source — mirroring
/// RetraceKit's CLIStateMetrics ownership rules. The recorder's data stays read-only;
/// everything the harness believes lives here.
public final class AttributionStore: Sendable {
    private let db: OpaquePointer

    public init(stateRoot: URL, sourceRoot: URL) throws {
        let source = try CLIStateMetrics.canonicalPath(sourceRoot)
        let state = try CLIStateMetrics.canonicalPath(stateRoot)
        guard state != source, !state.hasPrefix(source + "/") else {
            throw CLIError("unsafe_state_root", "Attribution state must live outside the recording source; choose another state root.", exitCode: 2)
        }
        // Walk components with O_NOFOLLOW so state never aliases source via symlinks.
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CLIError("state_unavailable", "Could not open attribution state root.", exitCode: 3) }
        defer { close(directory) }
        for component in stateRoot.pathComponents.dropFirst() {
            if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                throw CLIError("state_unavailable", "Could not create attribution state root.", exitCode: 3)
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw CLIError("unsafe_state_root", "Attribution state root must not contain symlink components.", exitCode: 2) }
            close(directory)
            directory = next
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(stateRoot.appendingPathComponent("attribution.db").path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw CLIError("state_unavailable", "Could not open attribution.db.", exitCode: 3)
        }
        sqlite3_busy_timeout(handle, 1000)
        guard sqlite3_exec(handle, """
                CREATE TABLE IF NOT EXISTS blocks (
                    id TEXT PRIMARY KEY,
                    startedAtMs INTEGER NOT NULL,
                    endedAtMs INTEGER NOT NULL,
                    appBundleId TEXT,
                    windowName TEXT,
                    browserUrl TEXT,
                    frameIds TEXT NOT NULL,
                    project TEXT NOT NULL,
                    activity TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    model TEXT NOT NULL,
                    classifiedAtMs INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS index_blocks_on_started ON blocks(startedAtMs);
                CREATE TABLE IF NOT EXISTS checkpoint (
                    name TEXT PRIMARY KEY,
                    frameId INTEGER NOT NULL
                );
                """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw CLIError("state_unavailable", "Attribution schema could not be created.", exitCode: 3)
        }
        db = handle
    }

    deinit { sqlite3_close_v2(db) }

    public func loadCheckpoint(name: String = "live") throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT frameId FROM checkpoint WHERE name = ?", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, name, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    public func saveCheckpoint(frameId: Int64, name: String = "live") throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO checkpoint(name, frameId) VALUES(?, ?) ON CONFLICT(name) DO UPDATE SET frameId = excluded.frameId", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, name, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, frameId) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CLIError("state_unavailable", "Could not persist the attribution checkpoint.", exitCode: 3)
        }
    }

    /// Idempotent append: replaying the same block after a crash is a no-op.
    public func append(_ record: AttributionRecord) throws {
        let frameIds = String(decoding: try JSONEncoder().encode(record.frameIds), as: UTF8.self)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, """
                INSERT INTO blocks(id, startedAtMs, endedAtMs, appBundleId, windowName, browserUrl,
                                   frameIds, project, activity, confidence, model, classifiedAtMs)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO NOTHING
                """, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, record.id, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, record.startedAtMs) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, record.endedAtMs) == SQLITE_OK,
              sqlite3_bind_text(statement, 4, record.appBundleId, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 5, record.windowName, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 6, record.browserUrl, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 7, frameIds, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 8, record.project, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 9, record.activity, -1, transient) == SQLITE_OK,
              sqlite3_bind_double(statement, 10, record.confidence) == SQLITE_OK,
              sqlite3_bind_text(statement, 11, record.model, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 12, record.classifiedAtMs) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CLIError("state_unavailable", "Could not persist an attribution block.", exitCode: 3)
        }
    }

    public func blocks(sinceMs: Int64) throws -> [AttributionRecord] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, """
                SELECT id, startedAtMs, endedAtMs, appBundleId, windowName, browserUrl, frameIds,
                       project, activity, confidence, model, classifiedAtMs
                FROM blocks WHERE endedAtMs > ? ORDER BY startedAtMs
                """, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_int64(statement, 1, sinceMs) == SQLITE_OK else {
            throw CLIError("state_unavailable", "Could not read attribution blocks.", exitCode: 3)
        }
        var records: [AttributionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ index: Int32) -> String? {
                guard let value = sqlite3_column_text(statement, index) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
            }
            let frameIds = (try? JSONDecoder().decode([Int64].self, from: Data((text(6) ?? "[]").utf8))) ?? []
            records.append(AttributionRecord(
                id: text(0) ?? "", startedAtMs: sqlite3_column_int64(statement, 1), endedAtMs: sqlite3_column_int64(statement, 2),
                appBundleId: text(3), windowName: text(4), browserUrl: text(5), frameIds: frameIds,
                project: text(7) ?? "unknown", activity: text(8) ?? "", confidence: sqlite3_column_double(statement, 9),
                model: text(10) ?? "", classifiedAtMs: sqlite3_column_int64(statement, 11)))
        }
        return records
    }

    /// Deterministic per-project totals — plain sums over stored blocks; no model math.
    public func totals(sinceMs: Int64) throws -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for record in try blocks(sinceMs: sinceMs) {
            totals[record.project, default: 0] += record.durationMs
        }
        return totals
    }
}
