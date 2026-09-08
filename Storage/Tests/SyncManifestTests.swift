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
}
