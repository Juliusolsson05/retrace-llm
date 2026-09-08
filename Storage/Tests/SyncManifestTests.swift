import Foundation
import XCTest
import SQLCipher
@testable import Storage

final class SyncManifestTests: XCTestCase {
    private var sandbox: URL!
    private var state: URL { sandbox.appendingPathComponent("state") }
    private var source: URL { sandbox.appendingPathComponent("source") }
    private let firstHash = String(repeating: "a", count: 64)
    private let secondHash = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        sandbox = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("SyncManifestTests-\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: sandbox) }

    func testRecordLookupPendingAndUploadedSurviveSequentialConnections() async throws {
        let first = try await SyncManifest.open(root: state, sourceRoot: source)
        let missing = try await first.lookup(key: "chunks/202609/08/1")
        XCTAssertNil(missing)
        let recorded = try await first.record(key: "chunks/202609/08/1", sha256: firstHash, sizeBytes: 42, mtimeNs: 123)
        XCTAssertEqual(recorded.revision, 1)
        let pending = try await first.listPending()
        XCTAssertEqual(pending.map(\.key), [recorded.key])
        try await first.markUploaded(key: recorded.key, revision: 1, uploadedAt: 456, contentTag: "provider-version")
        try await first.close()

        // A fresh SQLite connection must recover committed state without an in-memory cache.
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        let lookup = try await reopened.lookup(key: recorded.key)
        let loaded = try XCTUnwrap(lookup)
        XCTAssertEqual(loaded.sha256, firstHash)
        XCTAssertEqual(loaded.sizeBytes, 42)
        XCTAssertEqual(loaded.mtimeNs, 123)
        XCTAssertEqual(loaded.uploadState, .uploaded)
        XCTAssertEqual(loaded.uploadedAt, 456)
        XCTAssertEqual(loaded.contentTag, "provider-version")
        let remaining = try await reopened.listPending()
        XCTAssertTrue(remaining.isEmpty)
        try await reopened.close()
    }

    func testHashChangesAndExplicitRevisionInvalidateUploadAcknowledgement() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        let entry = try await manifest.record(key: "chunks/202609/08/1", sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        try await manifest.markUploaded(key: entry.key, revision: 1, uploadedAt: 10, contentTag: "old")
        let unchanged = try await manifest.record(key: entry.key, sha256: firstHash, sizeBytes: 3, mtimeNs: 2)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertEqual(unchanged.uploadState, .uploaded)
        let changed = try await manifest.record(key: entry.key, sha256: secondHash, sizeBytes: 4, mtimeNs: 3)
        XCTAssertEqual(changed.revision, 2)
        XCTAssertEqual(changed.uploadState, .pending)
        XCTAssertNil(changed.uploadedAt)
        XCTAssertNil(changed.contentTag)
        do {
            try await manifest.markUploaded(key: entry.key, revision: 1, uploadedAt: 11, contentTag: "stale")
            XCTFail("An upload of old bytes must not acknowledge the new revision")
        } catch { XCTAssertEqual(error as? SyncManifestError, .staleRevision) }
        let incremented = try await manifest.incrementRevision(key: entry.key)
        XCTAssertEqual(incremented.revision, 3)
        let persisted = try await manifest.lookup(key: entry.key)
        XCTAssertEqual(persisted, incremented)
        try await manifest.close()
    }

    func testFailedRecordLeavesCommittedObjectIntact() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        let entry = try await manifest.record(key: "one", sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        do {
            _ = try await manifest.record(key: "one", sha256: secondHash, sizeBytes: -1, mtimeNs: 2)
            XCTFail("Invalid metadata must not replace the committed object")
        } catch { XCTAssertEqual(error as? SyncManifestError, .invalidRecord) }
        try await manifest.close()
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        let loaded = try await reopened.lookup(key: "one")
        XCTAssertEqual(loaded, entry)
        try await reopened.close()
    }

    func testReadOnlyMissingManifestCreatesNothingAndRejectsWrites() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        let missing = try await manifest.lookup(key: "one")
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        do {
            _ = try await manifest.record(key: "one", sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
            XCTFail("A dry-run handle cannot write")
        } catch { XCTAssertEqual(error as? SyncManifestError, .readOnly) }
        try await manifest.close()
    }

    func testSQLiteFailureRollsBackPartialUpdateAndReleasesTransaction() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        let original = try await manifest.record(key: "one", sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        // RAISE(FAIL) in an AFTER trigger leaves the statement's earlier row change in
        // place unless the manifest explicitly rolls back the enclosing transaction.
        XCTAssertEqual(sqlite3_exec(writer, "CREATE TRIGGER fail_update AFTER UPDATE ON objects BEGIN SELECT RAISE(FAIL,'fixture'); END", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await manifest.record(key: "one", sha256: secondHash, sizeBytes: 4, mtimeNs: 2)
            XCTFail("Injected SQLite error was swallowed")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        let unchanged = try await manifest.lookup(key: "one")
        XCTAssertEqual(unchanged, original)
        XCTAssertEqual(sqlite3_exec(writer, "DROP TRIGGER fail_update", nil, nil, nil), SQLITE_OK)
        let changed = try await manifest.record(key: "one", sha256: secondHash, sizeBytes: 4, mtimeNs: 2)
        XCTAssertEqual(changed.revision, 2)
        try await manifest.close()
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        let loaded = try await reopened.lookup(key: "one")
        XCTAssertEqual(loaded, changed)
        try await reopened.close()
    }

    func testReadOnlyWALWithoutSidecarsFailsWithoutCreatingThem() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.record(key: "one", sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        try await manifest.close()
        let path = state.appendingPathComponent(SyncManifest.filename)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        let before = try Data(contentsOf: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
        do {
            let readonly = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
            try await readonly.close()
            XCTFail("Must not repair a WAL manifest during dry-run")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: state.path).sorted(), names)
    }

    func testRejectsSourceSymlinkHardlinkAndInverseAliases() async throws {
        for location in [source, source.appendingPathComponent("state")] {
            await assertUnsafe(location)
        }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let alias = sandbox.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state)
        await assertUnsafe(alias)
        let db = source.appendingPathComponent("retrace.db")
        try Data("source sentinel".utf8).write(to: db)
        let manifest = state.appendingPathComponent(SyncManifest.filename)
        try FileManager.default.linkItem(at: db, to: manifest)
        await assertUnsafe(state)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: db)
        await assertUnsafe(state)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.moveItem(at: db, to: manifest)
        try FileManager.default.createSymbolicLink(at: db, withDestinationURL: manifest)
        await assertUnsafe(state)
        XCTAssertEqual(try Data(contentsOf: manifest), Data("source sentinel".utf8))
    }

    private func assertUnsafe(_ location: URL) async {
        do {
            _ = try await SyncManifest.open(root: location, sourceRoot: source)
            XCTFail("Unsafe state root was accepted")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unsafeStateRoot) }
    }

    func testDeletionLedgerPersistsIdempotentlyAndSuppressesQueueAfterLocalApply() async throws {
        let key = "chunks/202603/07/1772928000000"
        let other = "chunks/202603/08/1773014400000"
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.record(key: key, sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        let recorded = try await manifest.recordPendingDeletions(keys: [key, key, other], reason: "purge-day:2026-03-08")
        XCTAssertEqual(recorded, 2)
        try await manifest.markAppliedLocal(keys: [key])
        let pending = try await manifest.pendingDeletionKeys()
        XCTAssertEqual(pending, Set([key, other]), "Local application must not acknowledge cloud deletion")
        let queued = try await manifest.listPending()
        XCTAssertTrue(queued.isEmpty)
        let retained = try await manifest.lookup(key: key)
        XCTAssertNotNil(retained, "Keep revision/provider history for future all-version deletion")
        let repeated = try await manifest.recordPendingDeletions(keys: [key, other], reason: "purge-day:2026-03-08")
        XCTAssertEqual(repeated, 0)
        try await manifest.close()
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        let found = try await reopened.isPendingDeletion(key: key)
        let missing = try await reopened.isPendingDeletion(key: "absent")
        XCTAssertTrue(found)
        XCTAssertFalse(missing)
        try await reopened.close()
        XCTAssertEqual(try ledgerScalar("SELECT count(*) FROM deletions"), 2)
        XCTAssertEqual(try ledgerScalar("SELECT sum(appliedLocal) FROM deletions"), 0)
    }

    func testDeletionLedgerRejectsRequeueRevisionAndLateUploadAcknowledgement() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        let key = "chunks/202603/08/1"
        _ = try await manifest.record(key: key, sha256: firstHash, sizeBytes: 3, mtimeNs: 1)
        _ = try await manifest.recordPendingDeletions(keys: [key], reason: "fixture")
        for operation in 0..<3 {
            do {
                switch operation {
                case 0: _ = try await manifest.record(key: key, sha256: secondHash, sizeBytes: 3, mtimeNs: 2)
                case 1: _ = try await manifest.incrementRevision(key: key)
                default: try await manifest.markUploaded(key: key, revision: 1, uploadedAt: 10, contentTag: "late")
                }
                XCTFail("A purged key must never reenter the upload queue")
            } catch { XCTAssertEqual(error as? SyncManifestError, .pendingDeletion) }
        }
        try await manifest.close()
    }

    func testDeletionTransactionsRollbackOnSQLiteFailureAndReopenAfterInterruptedWrite() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.recordPendingDeletions(keys: ["a"], reason: "fixture")
        try await manifest.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE; INSERT INTO deletions VALUES('interrupted',1,'fixture',0)", nil, nil, nil), SQLITE_OK)
        // Closing without COMMIT simulates interruption at SQLite's transaction boundary.
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        let pending = try await reopened.pendingDeletionKeys()
        XCTAssertEqual(pending, ["a"])
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_delete AFTER INSERT ON deletions WHEN NEW.objectKey='c' BEGIN SELECT RAISE(FAIL,'fixture'); END", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await reopened.recordPendingDeletions(keys: ["b", "c"], reason: "fixture")
            XCTFail("Partial ledger transaction succeeded")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        let after = try await reopened.pendingDeletionKeys()
        XCTAssertEqual(after, ["a"])
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try await reopened.close()
    }

    func testDeletionMigrationReadOnlyLegacyAndCorruptSchemaFailClosed() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        try await manifest.close()
        var db: OpaquePointer?
        let path = state.appendingPathComponent(SyncManifest.filename)
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE deletions; PRAGMA user_version=0", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try Data(contentsOf: path)
        let legacy = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        let empty = try await legacy.pendingDeletionKeys()
        XCTAssertTrue(empty.isEmpty)
        try await legacy.close()
        XCTAssertEqual(try Data(contentsOf: path), before)
        let migrated = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await migrated.recordPendingDeletions(keys: ["one"], reason: "fixture")
        try await migrated.close()
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE deletions RENAME COLUMN appliedLocal TO broken", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        for readOnly in [true, false] {
            do {
                let broken = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: readOnly)
                _ = try await broken.pendingDeletionKeys()
                try await broken.close()
                XCTFail("Corrupt ledger was accepted")
            } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        }
    }

    private func ledgerScalar(_ sql: String) throws -> Int64 {
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

    func testDeletionMissingTableAndInvalidValuesNeverBecomeEmptySuccess() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.recordPendingDeletions(keys: ["one"], reason: "fixture")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE deletions SET appliedLocal=2", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await manifest.listPending()
            XCTFail("Invalid acknowledgement must stop queue reads")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE deletions", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try await manifest.close()
        for readOnly in [true, false] {
            do {
                let reopened = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: readOnly)
                try await reopened.close()
                XCTFail("A migrated ledger must not silently disappear")
            } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        }
    }

    func testDeletionApplyFailureRollsBackWholeBatchAndReadOnlyCannotAcknowledge() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.recordPendingDeletions(keys: ["a", "b"], reason: "fixture")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent(SyncManifest.filename).path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_apply AFTER UPDATE ON deletions WHEN NEW.objectKey='b' BEGIN SELECT RAISE(FAIL,'fixture'); END", nil, nil, nil), SQLITE_OK)
        do {
            try await manifest.markAppliedLocal(keys: ["a", "b"])
            XCTFail("Apply accepted a partial transaction")
        } catch { XCTAssertEqual(error as? SyncManifestError, .unavailable) }
        XCTAssertEqual(try ledgerScalar("SELECT sum(appliedLocal) FROM deletions"), 0)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try await manifest.close()
        let readonly = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        for operation in 0..<2 {
            do {
                if operation == 0 { _ = try await readonly.recordPendingDeletions(keys: ["c"], reason: "fixture") }
                else { try await readonly.markAppliedLocal(keys: ["a"]) }
                XCTFail("Read-only ledger accepted a write")
            } catch { XCTAssertEqual(error as? SyncManifestError, .readOnly) }
        }
        try await readonly.close()
    }

    func testDeletionLedgerRecoversCommittedIntentAfterWriterIsKilled() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.recordPendingDeletions(keys: ["committed"], reason: "fixture")
        try await manifest.close()
        let file = state.appendingPathComponent(SyncManifest.filename)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-init", "/dev/null", file.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        // Small page cache forces dirty pages into the DB while the undo journal
        // remains hot. stdin stays open so the child cannot exit/rollback gracefully.
        let sql = """
            PRAGMA cache_size=1;
            PRAGMA main.cache_spill=2;
            BEGIN IMMEDIATE;
            WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<2000)
            INSERT INTO deletions SELECT 'uncommitted-'||n,1,'fixture',0 FROM ids;

            """
        try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
        let journal = URL(fileURLWithPath: file.path + "-journal")
        var hot = false
        var journalDescription = "absent"
        for _ in 0..<250 {
            if let bytes = try? Data(contentsOf: journal) {
                journalDescription = "\(bytes.count) bytes, header \(Array(bytes.prefix(8)))"
            }
            if let bytes = try? Data(contentsOf: journal), bytes.count > 512,
               bytes.prefix(8).contains(where: { $0 != 0 }) { hot = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        let diagnostics = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(hot, "Fixture writer must create a hot rollback journal (\(journalDescription)): \(diagnostics)")
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        let keys = try await reopened.pendingDeletionKeys()
        XCTAssertEqual(keys, ["committed"])
        try await reopened.close()
    }

    func testSnapshotLineageMigrationPreservesLegacyObjectsAndPersistsRows() async throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let path = state.appendingPathComponent(SyncManifest.filename)
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &legacy), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(legacy, """
            CREATE TABLE objects(key TEXT PRIMARY KEY,sha256 TEXT,sizeBytes INTEGER,mtimeNs INTEGER,
                revision INTEGER,uploadState TEXT,uploadedAt INTEGER,contentTag TEXT);
            INSERT INTO objects VALUES('one','\(firstHash)',42,123,1,'uploaded',456,'tag');
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacy), SQLITE_OK)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        let object = try await manifest.lookup(key: "one")
        XCTAssertEqual(object?.uploadState, .uploaded)
        XCTAssertEqual(object?.sizeBytes, 42)
        try await manifest.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let insert = "INSERT INTO snapshots(createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath) VALUES(123,42,'\(firstHash)',2,1,'sqlite-online-backup-v1','/fixture/123.db')"
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE snapshots SET frameCount=-1", nil, nil, nil), SQLITE_CONSTRAINT)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let reopened = try await SyncManifest.open(root: state, sourceRoot: source)
        try await reopened.close()
        XCTAssertEqual(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(db, "SELECT createdMs,sizeBytes,sha256,frameCount,videoCount,lineageTag,snapshotPath FROM snapshots", -1, &statement, nil)
        XCTAssertEqual(prepared, SQLITE_OK)
        guard prepared == SQLITE_OK else { return }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 123)
        XCTAssertEqual(sqlite3_column_int64(statement, 1), 42)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 2)), firstHash)
        XCTAssertEqual(sqlite3_column_int64(statement, 3), 2)
        XCTAssertEqual(sqlite3_column_int64(statement, 4), 1)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 5)), "sqlite-online-backup-v1")
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 6)), "/fixture/123.db")
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testSnapshotLookupPrefersLatestPathThenFallsBackToHashAcrossReopen() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        _ = try await manifest.recordSnapshot(createdMs: 100, sizeBytes: 42, sha256: firstHash,
            frameCount: 2, videoCount: 1, lineageTag: "test", snapshotPath: "/fixture/one.db")
        _ = try await manifest.recordSnapshot(createdMs: 200, sizeBytes: 50, sha256: secondHash,
            frameCount: 3, videoCount: 1, lineageTag: "test", snapshotPath: "/fixture/one.db")
        let latest = try await manifest.recordSnapshot(createdMs: 200, sizeBytes: 51, sha256: secondHash,
            frameCount: 4, videoCount: 2, lineageTag: "test", snapshotPath: "/fixture/one.db")
        let other = try await manifest.recordSnapshot(createdMs: 300, sizeBytes: 42, sha256: firstHash,
            frameCount: 2, videoCount: 1, lineageTag: "test", snapshotPath: "/fixture/two.db")
        try await manifest.close()
        let readonly = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        let pathMatch = try await readonly.lookupSnapshot(sha256: firstHash, snapshotPath: "/fixture/one.db")
        XCTAssertEqual(pathMatch, latest)
        let hashMatch = try await readonly.lookupSnapshot(sha256: firstHash, snapshotPath: "/fixture/moved.db")
        XCTAssertEqual(hashMatch, other)
        do {
            _ = try await readonly.recordSnapshot(createdMs: 400, sizeBytes: 42, sha256: firstHash,
                frameCount: 2, videoCount: 1, lineageTag: "test", snapshotPath: "/fixture/three.db")
            XCTFail("Read-only lineage accepted a write")
        } catch { XCTAssertEqual(error as? SyncManifestError, .readOnly) }
        try await readonly.close()
    }

    func testSnapshotLookupDoesNotMigrateLegacyReadOnlyManifest() async throws {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: source)
        try await manifest.close()
        let path = state.appendingPathComponent(SyncManifest.filename)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE snapshots", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let before = try Data(contentsOf: path)
        let readonly = try await SyncManifest.open(root: state, sourceRoot: source, readOnly: true)
        let missing = try await readonly.lookupSnapshot(sha256: firstHash, snapshotPath: "/fixture/one.db")
        XCTAssertNil(missing)
        try await readonly.close()
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
}
