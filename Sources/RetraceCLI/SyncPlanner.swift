import Foundation
import CryptoKit
import Storage
import Darwin

struct SyncFileHasher {
    struct Digest: Sendable {
        let sha256: String
        let sha1: String
        let sizeBytes: Int64
        let mtimeNs: Int64
    }

    static func hash(file: URL) async throws -> Digest {
        try await Task.detached {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw failure("chunk_unreadable") }
            defer { close(fd) }
            var attributes = stat()
            guard fstat(fd, &attributes) == 0 else { throw failure("metadata_unreadable") }
            return try hash(fd: fd, expected: attributes)
        }.value
    }

    static func hash(directory: Int32, name: String, expected: stat, deadline: Double) throws -> Digest {
        // O_NONBLOCK ensures a replacement FIFO cannot hang between stat and open.
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("chunk_unreadable") }
        defer { close(fd) }
        let digest = try hash(fd: fd, expected: expected, deadline: deadline)
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameVersion(expected, current) else { throw failure("chunk_changed") }
        return digest
    }

    private static func hash(fd: Int32, expected: stat, deadline: Double? = nil) throws -> Digest {
        var initial = stat()
        guard fstat(fd, &initial) == 0 else { throw failure("metadata_unreadable") }
        guard initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), initial.st_nlink == 1 else { throw failure("unsafe_chunk") }
        guard sameVersion(initial, expected), initial.st_size >= 0 else { throw failure("chunk_changed") }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        // Memory stays bounded regardless of the chunk's size. SHA-1 is only B2's
        // transport checksum; SHA-256 is the manifest's content identity.
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw failure("time_limit") }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("chunk_unreadable")
            }
            if count == 0 { break }
            let addition = total.addingReportingOverflow(Int64(count))
            guard !addition.overflow, addition.partialValue <= initial.st_size else { throw failure("chunk_changed") }
            total = addition.partialValue
            let bytes = Data(buffer.prefix(count))
            sha256.update(data: bytes)
            sha1.update(data: bytes)
        }
        var final = stat()
        guard fstat(fd, &final) == 0, sameVersion(initial, final), total == initial.st_size else { throw failure("chunk_changed") }
        let seconds = Int64(initial.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let nanos = seconds.partialValue.addingReportingOverflow(Int64(initial.st_mtimespec.tv_nsec))
        guard !seconds.overflow, !nanos.overflow else { throw failure("mtime_overflow") }
        return Digest(sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined(),
                      sha1: sha1.finalize().map { String(format: "%02x", $0) }.joined(), sizeBytes: total, mtimeNs: nanos.partialValue)
    }

    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func failure(_ code: String) -> CLIError {
        CLIError(code, "A chunk could not be hashed consistently within the planning limits.", exitCode: 4)
    }
}

struct SyncPlan: Encodable, Sendable {
    struct Object: Encodable, Sendable {
        let key: String
        let sizeBytes: Int64
        let sha256: String
        let revision: Int64
    }

    let schemaVersion = 1
    let command = "sync"
    var status = "complete"
    var exitCode: Int32 = 0
    var wouldUpload: [Object] = []
    var wouldReupload: [Object] = []
    var unchangedCount = 0
    var bytesTotal: Int64 = 0
    var objectsTotal = 0
    var incompleteFileCount: Int64 = 0
    var noncanonicalFileCount: Int64 = 0
    var noncanonicalBytes: Int64 = 0
    var noncanonicalDirectoryCount: Int64 = 0
    var symlinkCount: Int64 = 0
    var otherEntryCount: Int64 = 0
    var visitedEntries = 0
    var errors: [String: Int] = [:]
    var elapsedMs: Double = 0
    var error: CLIError?
}

enum SyncPlanner {
    static func plan(root: URL, state: URL, maxEntries: Int = 100_000, maxSeconds: Double = 10) async throws -> SyncPlan {
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root, readOnly: true)
        do {
            let (inventory, candidates) = await Task.detached {
                var candidates: [(String, SyncFileHasher.Digest)] = []
                let deadline = ProcessInfo.processInfo.systemUptime + maxSeconds
                let inventory = ChunkInventory.scanSynchronously(root: root, maxEntries: maxEntries, maxSeconds: maxSeconds) { fd, name, key, attributes in
                    let digest = try SyncFileHasher.hash(directory: fd, name: name, expected: attributes, deadline: deadline)
                    candidates.append((key, digest))
                }
                return (inventory, candidates)
            }.value
            var result = SyncPlan()
            result.status = inventory.status
            result.incompleteFileCount = inventory.incompleteFileCount
            result.noncanonicalFileCount = inventory.noncanonicalFileCount
            result.noncanonicalBytes = inventory.noncanonicalBytes
            result.noncanonicalDirectoryCount = inventory.noncanonicalDirectoryCount
            result.symlinkCount = inventory.symlinkCount
            result.otherEntryCount = inventory.otherEntryCount
            result.visitedEntries = inventory.visitedEntries
            result.errors = inventory.errors
            for (key, digest) in candidates.sorted(by: { $0.0 < $1.0 }) {
                let previous = try await manifest.lookup(key: key)
                let changed = previous.map { $0.sha256 != digest.sha256 } ?? false
                var revision = previous?.revision ?? 1
                if changed {
                    guard revision > 0, revision < Int64.max else { throw SyncManifestError.invalidRecord }
                    revision += 1
                }
                let object = SyncPlan.Object(key: key, sizeBytes: digest.sizeBytes, sha256: digest.sha256, revision: revision)
                if changed { result.wouldReupload.append(object) }
                else if previous?.uploadState == .uploaded { result.unchangedCount += 1 }
                else { result.wouldUpload.append(object) }
                let total = result.bytesTotal.addingReportingOverflow(digest.sizeBytes)
                guard !total.overflow else { throw CLIError("size_overflow", "Candidate byte count overflowed.", exitCode: 4) }
                result.bytesTotal = total.partialValue
                result.objectsTotal += 1
            }
            try await manifest.close()
            if result.status == "partial" {
                result.exitCode = 4
                result.error = CLIError("inventory_partial", "Sync plan is partial; inspect aggregate errors and rerun on stable files.", exitCode: 4)
            }
            return result
        } catch {
            try? await manifest.close()
            throw error
        }
    }
}
