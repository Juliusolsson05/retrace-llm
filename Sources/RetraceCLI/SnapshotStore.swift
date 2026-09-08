import Foundation
import SQLCipher
import Storage
import Darwin

struct SnapshotReport: Encodable, Sendable {
    let schemaVersion = 1
    let command: String
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs: Double = 0
    var snapshotPath: String?
    var restoredPath: String?
    var sha256: String?
    var plainSha256: String?
    var format = "sqlite"
    var sizeBytes: Int64?
    var frameCount: Int64?
    var videoCount: Int64?
    var integrity: String?
    var lineageId: Int64?
    var checks: [String: String]?
    var error: CLIError?

    mutating func fail(_ failure: CLIError) {
        status = "failed"
        exitCode = failure.exitCode
        error = failure
    }
}

/// Local database recovery points only. All work runs on the command worker; the
/// source connection and its VFS retain the same no-write policy as evidence reads.
enum SnapshotStore {
    // Logical identity is independent of local placement so copied/moved containers
    // remain recoverable without the original manifest. Content identity is SHA256.
    private static let objectKey = "snapshots/database"

    static func create(root: URL, state: URL, key: ObjectCrypto.Key? = nil) async throws -> SnapshotReport {
        let directoryURL = state.appendingPathComponent("snapshots", isDirectory: true)
        try outsideSource(directoryURL, root: root, code: "unsafe_state_root")
        let directory = try openDirectory(directoryURL, create: true, code: "unsafe_state_root")
        defer { close(directory) }
        let createdMs = Int64(Date().timeIntervalSince1970 * 1000)
        // O_EXCL prevents an existing snapshot, alias, or simultaneous command from
        // being overwritten. Collisions keep the required numeric UTC-ms filename.
        var name: String?
        for offset in 0..<1000 {
            let candidate = "\(createdMs + Int64(offset)).db"
            let fd = openat(directory, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { close(fd); name = candidate; break }
            guard errno == EEXIST else { throw unavailable() }
        }
        guard let name else { throw unavailable() }
        let file = directoryURL.appendingPathComponent(name)
        var complete = false
        defer { if !complete { removeDatabase(directory: directory, name: name) } }
        try backup(root: root, destination: file)
        var measurement = try await measure(file)
        guard measurement.integrity == "ok", let frames = measurement.frameCount,
              let videos = measurement.videoCount else { throw integrityFailure() }
        if let key {
            let encrypted = try await ObjectCrypto.encryptFile(file, objectKey: objectKey, key: key, temporaryDirectory: directoryURL)
            defer { unlinkat(directory, encrypted.lastPathComponent, 0) }
            guard renameat(directory, encrypted.lastPathComponent, directory, name) == 0 else { throw unavailable() }
            let plainHash = measurement.sha256
            let encryptedDigest = try await digest(file)
            measurement.sha256 = encryptedDigest.sha256
            measurement.sizeBytes = encryptedDigest.sizeBytes
            measurement.plainSha256 = plainHash
            measurement.format = "RBC1"
        }
        // Persist the new directory entry before committing lineage that refers to it.
        guard fsync(directory) == 0 else { throw unavailable() }
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        let row: SyncManifest.Snapshot
        do {
            row = try await manifest.recordSnapshot(createdMs: createdMs, sizeBytes: measurement.sizeBytes!,
                sha256: measurement.sha256!, frameCount: frames, videoCount: videos,
                lineageTag: key == nil ? "sqlite-online-backup-v1" : "sqlite-online-backup-rbc1-v1",
                snapshotPath: file.path, plainSha256: measurement.plainSha256)
            try await manifest.close()
        } catch {
            try? await manifest.close()
            throw error
        }
        complete = true
        var report = measurement
        report.snapshotPath = file.path
        report.lineageId = row.id
        return report
    }

    static func verify(file: URL, root: URL, state: URL, key: ObjectCrypto.Key? = nil) async throws -> SnapshotReport {
        var report = try await measure(file, command: "verify", key: key)
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root, readOnly: true)
        let row: SyncManifest.Snapshot?
        do {
            row = try await manifest.lookupSnapshot(sha256: report.sha256!, snapshotPath: file.path)
            try await manifest.close()
        } catch {
            try? await manifest.close()
            throw error
        }
        func match<T: Equatable>(_ observed: T?, _ expected: T?) -> String {
            guard let observed, let expected else { return "unavailable" }
            return observed == expected ? "match" : "mismatch"
        }
        report.lineageId = row?.id
        report.checks = [
            "manifest": row == nil ? "missing" : "match",
            "sha256": match(report.sha256, row?.sha256),
            "sizeBytes": match(report.sizeBytes, row?.sizeBytes),
            "frameCount": match(report.frameCount, row?.frameCount),
            "videoCount": match(report.videoCount, row?.videoCount),
            "integrity": report.integrity == "ok" ? "match" : "mismatch"
        ]
        if report.format == "RBC1" || row?.plainSha256 != nil {
            report.checks?["plainSha256"] = match(report.plainSha256, row?.plainSha256)
        }
        if row == nil {
            report.fail(CLIError("snapshot_lineage_missing", "No matching snapshot lineage exists in this CLI state."))
        } else if report.checks!.values.contains(where: { $0 != "match" }) {
            report.fail(CLIError("snapshot_mismatch", "Snapshot verification failed; inspect the per-field checks."))
        }
        return report
    }

    static func restore(file: URL, target: URL, root: URL, key: ObjectCrypto.Key? = nil) async throws -> SnapshotReport {
        try outsideSource(target, root: root, code: "unsafe_restore_target")
        // Check existing directories before any copy and again after validating the
        // input. Exclusive creation below also refuses a racing retrace.db file.
        let directory = try openDirectory(target, create: true, code: "unsafe_restore_target")
        defer { close(directory) }
        try requireEmpty(directory)
        let original = try await measure(file, command: "restore", key: key)
        guard original.integrity == "ok" else { throw integrityFailure() }
        var plaintext: URL?
        defer { if let plaintext { try? FileManager.default.removeItem(at: plaintext) } }
        if original.format == "RBC1" {
            guard let key else { throw CLIError("phrase_required", "Encrypted restore requires the recovery phrase on stdin.", exitCode: 2) }
            plaintext = try await ObjectCrypto.decryptFile(file, objectKey: objectKey, key: key)
        }
        try requireEmpty(directory)
        let output = openat(directory, "retrace.db", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw unavailable() }
        var complete = false
        defer {
            close(output)
            if !complete { removeDatabase(directory: directory, name: "retrace.db") }
        }
        try copy(plaintext ?? file, to: output)
        guard fsync(output) == 0 else { throw unavailable() }
        let destination = target.appendingPathComponent("retrace.db")
        var report = try await measure(destination, command: "restore")
        guard report.integrity == "ok", report.sha256 == (original.plainSha256 ?? original.sha256),
              (original.format == "RBC1" || report.sizeBytes == original.sizeBytes), report.frameCount == original.frameCount,
              report.videoCount == original.videoCount else { throw integrityFailure() }
        guard fsync(directory) == 0 else { throw unavailable() }
        complete = true
        if original.format == "RBC1" {
            report.format = original.format
            report.plainSha256 = report.sha256
            report.sha256 = original.sha256
            report.sizeBytes = original.sizeBytes
        }
        report.restoredPath = destination.path
        return report
    }

    static func validateInput(_ file: URL, root: URL) throws {
        try outsideSource(file, root: root, code: "unsafe_snapshot")
        let directory = try openDirectory(file.deletingLastPathComponent(), create: false, code: "unsafe_snapshot")
        defer { close(directory) }
        var item = stat()
        guard fstatat(directory, file.lastPathComponent, &item, AT_SYMLINK_NOFOLLOW) == 0,
              item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), item.st_nlink == 1 else {
            throw unsafe("unsafe_snapshot")
        }
    }

    /// Validate before metrics initialization: a supplied snapshot may itself be a
    /// CLI database. Opening that path for metrics would change the input to verify.
    /// Other input failures are checked after started so their outcomes are recorded.
    static func validateMetricsSeparation(_ file: URL, state: URL) throws {
        let path = try CLIStateMetrics.canonicalPath(file)
        for name in ["metrics.db", SyncManifest.filename, BackupKeyStore.filename] {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                guard try CLIStateMetrics.canonicalPath(state.appendingPathComponent(name + suffix)) != path else {
                    throw unsafe("unsafe_snapshot")
                }
            }
        }
    }

    private static func backup(root: URL, destination: URL) throws {
        try SourceDatabase.withConnection(root: root) { connection in
            guard let source = connection.getConnection() else { throw unavailable() }
            // Pin a read transaction so continuous WAL commits cannot restart a paged
            // backup forever. Lock acquisition is bounded; this never takes a write lock.
            sqlite3_busy_timeout(source, 1000)
            guard sqlite3_exec(source, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
                throw CLIError("snapshot_busy", "Could not acquire a source read snapshot within the lock timeout.")
            }
            defer { sqlite3_exec(source, "ROLLBACK", nil, nil, nil) }
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
            guard sqlite3_open_v2(destination.path, &db, flags, nil) == SQLITE_OK, let db else {
                sqlite3_close_v2(db)
                throw unavailable()
            }
            defer { sqlite3_close_v2(db) }
            sqlite3_busy_timeout(db, 100)
            guard sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK,
                  let backup = sqlite3_backup_init(db, "main", source, "main") else { throw unavailable() }
            var finished = false
            defer { if !finished { sqlite3_backup_finish(backup) } }
            var busyAttempts = 0
            while true {
                try Task.checkCancellation()
                let result = sqlite3_backup_step(backup, 256)
                if result == SQLITE_DONE { break }
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    busyAttempts += 1
                    guard busyAttempts <= 10 else {
                        throw CLIError("snapshot_busy", "SQLite backup exhausted its bounded lock retries.")
                    }
                    sqlite3_sleep(10) // Command worker only; never a UI path.
                } else if result != SQLITE_OK { throw unavailable() }
            }
            let result = sqlite3_backup_finish(backup)
            finished = true
            guard result == SQLITE_OK else { throw unavailable() }
            // Backup copies the source's WAL header too. Convert only the destination
            // to DELETE so the recovery point is one standalone file without sidecars.
            guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else { throw unavailable() }
        }
    }

    private static func measure(_ file: URL, command: String = "snapshot", key: ObjectCrypto.Key? = nil) async throws -> SnapshotReport {
        let before = try await digest(file)
        var report = SnapshotReport(command: command)
        report.sha256 = before.sha256
        report.sizeBytes = before.sizeBytes
        var plaintext: URL?
        defer { if let plaintext { try? FileManager.default.removeItem(at: plaintext) } }
        if try await ObjectCrypto.isEncrypted(file) {
            report.format = "RBC1"
            guard let key else { throw CLIError("phrase_required", "Encrypted snapshot requires the recovery phrase on stdin.", exitCode: 2) }
            // Keep the ciphertext identity available when authentication fails, just
            // as plaintext verification keeps its digest when SQLite is corrupt.
            do {
                let decrypted = try await ObjectCrypto.decryptFile(file, objectKey: objectKey, key: key)
                plaintext = decrypted
                report.plainSha256 = try await digest(decrypted).sha256
            } catch { report.integrity = "failed" }
        }
        // Keep the byte digest even if SQLite cannot parse a tampered file. Verify
        // must report the SHA mismatch instead of hiding it behind an open error.
        do {
            guard report.integrity != "failed" else { throw integrityFailure() }
            let counts = try inspect(plaintext ?? file)
            report.integrity = "ok"
            report.frameCount = counts.0
            report.videoCount = counts.1
        } catch {
            report.integrity = "failed"
        }
        let after = try await digest(file)
        guard before.sha256 == after.sha256, before.sizeBytes == after.sizeBytes,
              before.mtimeNs == after.mtimeNs else {
            throw CLIError("snapshot_changed", "Snapshot changed while it was being inspected.")
        }
        return report
    }

    private static func digest(_ file: URL) async throws -> SyncFileHasher.Digest {
        do { return try await SyncFileHasher.hash(file: file) }
        catch { throw CLIError("snapshot_unreadable", "Snapshot could not be hashed consistently.") }
    }

    private static func inspect(_ file: URL) throws -> (Int64, Int64) {
        guard ReadOnlySourceVFS.registration == SQLITE_OK else { throw unavailable() }
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = file.path
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "readonly_shm", value: "1"),
                          URLQueryItem(name: "vfs", value: ReadOnlySourceVFS.name)]
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard let path = uri.string, sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw integrityFailure()
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 1000)
        func scalarText(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw integrityFailure() }
            let value = String(cString: text)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw integrityFailure() }
            return value
        }
        // A WAL-dependent DB is not a standalone snapshot; never silently verify just
        // its base file's hash against counts obtained from a separate WAL.
        guard sqlite3_db_readonly(db, "main") == 1,
              try scalarText("PRAGMA journal_mode") == "delete",
              try scalarText("PRAGMA integrity_check") == "ok" else { throw integrityFailure() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT (SELECT COUNT(*) FROM frame), (SELECT COUNT(*) FROM video)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw integrityFailure() }
        let result = (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw integrityFailure() }
        return result
    }

    private static func outsideSource(_ candidate: URL, root: URL, code: String) throws {
        do {
            let source = try CLIStateMetrics.canonicalPath(root)
            let path = try CLIStateMetrics.canonicalPath(candidate)
            let sourceDB = try CLIStateMetrics.canonicalPath(root.appendingPathComponent("retrace.db"))
            guard source != "/", path != source, !path.hasPrefix(source + "/"), path != sourceDB else { throw unsafe(code) }
        } catch { throw unsafe(code) }
    }

    private static func openDirectory(_ url: URL, create: Bool, code: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw unavailable() }
        do {
            for component in url.pathComponents.dropFirst() {
                if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST { throw unavailable() }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw unsafe(code) }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func requireEmpty(_ directory: Int32) throws {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw unavailable() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw unavailable() }
        defer { closedir(stream) }
        rewinddir(stream)
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw unavailable() }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name == "." || name == ".." else {
                throw CLIError("target_not_empty", "Restore requires an empty target directory.", exitCode: 2)
            }
        }
    }

    private static func copy(_ file: URL, to output: Int32) throws {
        let input = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw unavailable() }
        defer { close(input) }
        var item = stat()
        guard fstat(input, &item) == 0, item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), item.st_nlink == 1 else { throw unsafe("unsafe_snapshot") }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total: Int64 = 0
        while total < item.st_size {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, Int(min(Int64($0.count), item.st_size - total))) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw unavailable() }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw unavailable() }
                offset += written
            }
            total += Int64(count)
        }
    }

    private static func removeDatabase(directory: Int32, name: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] { unlinkat(directory, name + suffix, 0) }
    }

    private static func unsafe(_ code: String) -> CLIError {
        CLIError(code, "Snapshot and restore paths must be outside source storage, without symlink components or hardlinked files.", exitCode: 2)
    }

    private static func unavailable() -> CLIError {
        CLIError("snapshot_unavailable", "Local snapshot or restore I/O failed; no source repair or migration was attempted.")
    }

    private static func integrityFailure() -> CLIError {
        CLIError("snapshot_integrity_failed", "Snapshot must be a standalone database with integrity_check=ok and readable frame/video counts.")
    }
}
