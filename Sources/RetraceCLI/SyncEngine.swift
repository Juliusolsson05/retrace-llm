import Foundation
import Storage
import Darwin

/// Command-worker orchestration. Local commits precede provider side effects so a
/// rerun can recover after either an interrupted process or a lost HTTP response.
enum SyncEngine {
    static func gateError(_ missing: [String], disabled: Bool = false) -> CLIError {
        let gates = Array(Set(missing)).sorted()
        return CLIError(disabled ? "upload_disabled" : "sync_gate_missing",
            "Sync requires explicit --apply, encryption unlock, privacy-deletion ledger consultation and a current snapshot. Missing gates: "
                + gates.joined(separator: ", ") + ". Use sync --dry-run for local planning.",
            exitCode: 6, missingGates: gates)
    }

    static func checkGates(root: URL, state: URL, fromStdin: Bool,
                           readPhrase: @Sendable () throws -> String, client: B2Client) async -> (ObjectCrypto.Key?, [String]) {
        var missing: [String] = []
        var key: ObjectCrypto.Key?
        var present = false
        do { present = try await BackupKeyStore.status(root: state, sourceRoot: root).present }
        catch { missing.append("backup_key_invalid") }
        if !present { missing.append("backup_key_missing") }
        if !fromStdin { missing.append("phrase_required") }
        else if present {
            do { key = try await CLIKeyCommand.unlock(state: state, root: root, fromStdin: true, readPhrase: readPhrase) }
            catch { missing.append("backup_key_unlock_failed") }
        }
        if !client.hasCredentials() { missing.append("b2_credentials_missing") }
        do {
            let manifest = try await SyncManifest.open(root: state, sourceRoot: root, readOnly: true)
            do { _ = try await manifest.pendingDeletionKeys(); try await manifest.close() }
            catch { try? await manifest.close(); throw error }
        } catch { missing.append("deletion_ledger_unavailable") }
        return (key, missing)
    }

    static func apply(root: URL, state: URL, key: ObjectCrypto.Key, client: B2Client,
                      currentSnapshot: URL?, report: inout SyncPlan) async throws {
        // Foundation's resolvingSymlinksInPath can abbreviate /private/var to
        // /var on macOS. Preserve realpath's physical spelling for crypto's
        // descriptor-relative O_NOFOLLOW traversal of every input component.
        let root = URL(fileURLWithPath: try CLIStateMetrics.canonicalPath(root))
        // Hold the directory lock across awaits, not a thread-affine lock. Nonblocking
        // acquisition prevents two CLI processes from preparing different ciphertext
        // for one revision and serializes key rotation with the entire transfer run.
        let directory = try openDirectory(state)
        defer { close(directory) }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
            throw CLIError("sync_busy", "Another sync or key update owns this CLI state; retry after it completes.")
        }
        defer { flock(directory, LOCK_UN) }
        guard try await BackupKeyStore.status(root: state, sourceRoot: root).keyId == key.keyId else {
            throw gateError(["backup_key_unlock_failed"])
        }
        report = try await SyncPlanner.plan(root: root, state: state)
        guard report.exitCode == 0 else { return } // Partial inventory never authorizes a transfer.
        let lineageTag = "sync-" + UUID().uuidString
        report.lineageTag = lineageTag
        let snapshot: SnapshotReport
        do {
            snapshot = try await prepareSnapshot(root: root, state: state, key: key,
                current: currentSnapshot, lineageTag: lineageTag)
        } catch { throw gateError(["snapshot_current_missing"]) }
        report.snapshot = snapshot
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        do {
            let row = try await requireSnapshot(snapshot, lineageTag: lineageTag, manifest: manifest)
            // Credentials are read lazily again by authorize; missing/empty runtime
            // credentials never fall through to URLSession.
            let authorization: B2Client.Authorization
            do { authorization = try await client.authorize() }
            catch B2ClientError.missingCredentials { throw gateError(["b2_credentials_missing"]) }
            let api = authorization.apiInfo.storageApi
            guard let bucket = api.bucketId, !bucket.isEmpty else { throw gateError(["b2_bucket_missing"]) }
            guard Set(api.capabilities).isSuperset(of: ["listFiles", "writeFiles", "deleteFiles"]),
                  api.namePrefix == nil || api.namePrefix == "" else { throw gateError(["b2_capabilities_missing"]) }

            try await purge(manifest: manifest, client: client, authorization: authorization, bucket: bucket, report: &report)
            let snapshotFile = URL(fileURLWithPath: row.snapshotPath)
            let numericName = snapshotFile.lastPathComponent.components(separatedBy: ".").first ?? ""
            let timestamp = !numericName.isEmpty && numericName.utf8.allSatisfy({ (48...57).contains($0) })
                ? numericName : String(row.createdMs)
            let snapshotKey = "snapshots/\(timestamp).db.rbc1"
            try await upload(file: snapshotFile, objectKey: snapshotKey, expectedHash: row.sha256, encrypted: true,
                root: root, state: state, directory: directory, key: key, client: client, authorization: authorization,
                bucket: bucket, manifest: manifest, snapshot: snapshot, lineageTag: lineageTag, report: &report)
            let candidates = (report.wouldUpload + report.wouldReupload).sorted { $0.key < $1.key }
            for object in candidates {
                if try await manifest.isPendingDeletion(key: object.key) {
                    suppress(object.key, report: &report)
                    continue
                }
                try await upload(file: root.appendingPathComponent(object.key), objectKey: object.key,
                    expectedHash: object.sha256, encrypted: false, root: root, state: state, directory: directory,
                    key: key, client: client, authorization: authorization, bucket: bucket, manifest: manifest,
                    snapshot: snapshot, lineageTag: lineageTag, report: &report)
            }
            // Reconsult after network awaits: a purge recorded during a transfer wins
            // even if the provider accepted the bytes just before the local guard ran.
            try await purge(manifest: manifest, client: client, authorization: authorization, bucket: bucket, report: &report)
            try await manifest.close()
        } catch {
            try? await manifest.close()
            throw error
        }
    }

    private static func prepareSnapshot(root: URL, state: URL, key: ObjectCrypto.Key,
                                         current: URL?, lineageTag: String) async throws -> SnapshotReport {
        guard let current else { return try await SnapshotStore.create(root: root, state: state, key: key, lineageTag: lineageTag) }
        try SnapshotStore.validateMetricsSeparation(current, state: state)
        try SnapshotStore.validateInput(current, root: root)
        var verified = try await SnapshotStore.verify(file: current, root: root, state: state, key: key)
        guard verified.exitCode == 0 else { throw gateError(["snapshot_current_missing"]) }
        if verified.format != "RBC1" {
            // Explicitly supplied verified plaintext snapshots are sealed before
            // entering the upload set, retaining normal verify/restore semantics.
            let sealed = try await SnapshotStore.create(root: root, state: state, key: key, lineageTag: lineageTag, copying: current)
            guard sealed.plainSha256 == verified.sha256 else { throw gateError(["snapshot_current_missing"]) }
            return sealed
        }
        let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
        do {
            guard let old = try await manifest.lookupSnapshot(sha256: verified.sha256!, snapshotPath: current.path) else {
                throw gateError(["snapshot_current_missing"])
            }
            let row = try await manifest.recordSnapshot(createdMs: old.createdMs, sizeBytes: old.sizeBytes, sha256: old.sha256,
                frameCount: old.frameCount, videoCount: old.videoCount, lineageTag: lineageTag,
                snapshotPath: current.path, plainSha256: old.plainSha256)
            verified.snapshotPath = current.path
            verified.lineageId = row.id
            try await manifest.close()
            return verified
        } catch { try? await manifest.close(); throw error }
    }

    @discardableResult
    static func requireSnapshot(_ snapshot: SnapshotReport, lineageTag: String, manifest: SyncManifest) async throws -> SyncManifest.Snapshot {
        guard let hash = snapshot.sha256, let path = snapshot.snapshotPath,
              let row = try await manifest.lookupSnapshot(sha256: hash, snapshotPath: path),
              row.lineageTag == lineageTag, row.id == snapshot.lineageId, row.sha256 == hash,
              row.plainSha256 != nil, row.sizeBytes == snapshot.sizeBytes else {
            throw gateError(["snapshot_current_missing"])
        }
        return row
    }

    private static func upload(file: URL, objectKey: String, expectedHash: String, encrypted: Bool,
                               root: URL, state: URL, directory: Int32, key: ObjectCrypto.Key,
                               client: B2Client, authorization: B2Client.Authorization, bucket: String,
                               manifest: SyncManifest, snapshot: SnapshotReport, lineageTag: String,
                               report: inout SyncPlan) async throws {
        _ = try await requireSnapshot(snapshot, lineageTag: lineageTag, manifest: manifest)
        // ObjectCrypto traverses every input directory without following symlinks;
        // the planner's digest is checked against the actual sealed plaintext too.
        let digest = try await SyncFileHasher.hash(file: file)
        guard digest.sha256 == expectedHash else { throw CLIError("chunk_changed", "A planned object changed; rerun sync.", exitCode: 4) }
        let row: SyncManifest.Object
        do { row = try await manifest.record(key: objectKey, sha256: digest.sha256, sizeBytes: digest.sizeBytes, mtimeNs: digest.mtimeNs) }
        catch SyncManifestError.pendingDeletion { suppress(objectKey, report: &report); return }
        if row.uploadState == .uploaded { report.uploadsSkipped += 1; return }
        let ciphertext: URL
        let cipherDigest: SyncFileHasher.Digest
        if let attempt = try await manifest.uploadAttempt(key: objectKey), attempt.keyID == key.keyId {
            ciphertext = URL(fileURLWithPath: attempt.filePath)
            guard encrypted ? ciphertext.path == file.path :
                    (ciphertext.deletingLastPathComponent().path == state.path && ciphertext.lastPathComponent.hasPrefix(".retrace-crypto-")) else {
                throw CLIError("sync_resume_invalid", "Upload staging identity is invalid; no transfer was attempted.")
            }
            try SnapshotStore.validateInput(ciphertext, root: root)
            cipherDigest = try await SyncFileHasher.hash(file: ciphertext)
            guard cipherDigest.sha1 == attempt.sha1, cipherDigest.sizeBytes == attempt.sizeBytes else {
                throw CLIError("sync_resume_invalid", "Retained upload ciphertext changed; no transfer was attempted.")
            }
        } else {
            ciphertext = encrypted ? file : try await ObjectCrypto.encryptFile(file, objectKey: objectKey, key: key, temporaryDirectory: state)
            cipherDigest = try await SyncFileHasher.hash(file: ciphertext)
            guard fsync(directory) == 0 else { throw SyncManifestError.unavailable }
        }
        // Authenticating retained bytes also catches rotated keys, corrupt staging,
        // and source rewrites between planning and encryption.
        let plaintext = try await ObjectCrypto.decryptFile(ciphertext,
            objectKey: encrypted ? SnapshotStore.objectKey : objectKey, key: key)
        defer { try? FileManager.default.removeItem(at: plaintext) }
        let plainHash = try await SyncFileHasher.hash(file: plaintext).sha256
        guard plainHash == (encrypted ? snapshot.plainSha256 : expectedHash) else {
            throw CLIError("chunk_changed", "Object bytes no longer match this plan; rerun sync.", exitCode: 4)
        }
        do {
            try await manifest.beginUpload(key: objectKey, revision: row.revision, keyID: key.keyId,
                filePath: ciphertext.path, sha1: cipherDigest.sha1, sizeBytes: cipherDigest.sizeBytes)
        } catch SyncManifestError.pendingDeletion { suppress(objectKey, report: &report); return }
        let versions = try await client.listFileVersions(authorization: authorization, bucketID: bucket, key: objectKey)
        let uploaded: B2Client.FileVersion
        if let match = versions.first(where: { $0.action == "upload" && $0.contentSha1 == cipherDigest.sha1 && $0.contentLength == cipherDigest.sizeBytes }) {
            uploaded = match
            report.uploadsSkipped += 1
        } else {
            let uploadURL = try await client.getUploadURL(authorization: authorization, bucketID: bucket)
            guard uploadURL.bucketId == bucket else { throw B2ClientError.invalidResponse }
            _ = try await requireSnapshot(snapshot, lineageTag: lineageTag, manifest: manifest)
            if try await manifest.isPendingDeletion(key: objectKey) { suppress(objectKey, report: &report); return }
            uploaded = try await client.uploadFile(upload: uploadURL, fileName: objectKey, file: ciphertext,
                sizeBytes: cipherDigest.sizeBytes, sha1: cipherDigest.sha1)
            report.bytesUploaded += cipherDigest.sizeBytes
            report.objectsUploaded += 1
        }
        guard uploaded.fileName == objectKey, uploaded.action == "upload", !uploaded.fileId.isEmpty,
              uploaded.contentSha1 == cipherDigest.sha1, uploaded.contentLength == cipherDigest.sizeBytes else {
            throw B2ClientError.invalidResponse
        }
        // Queue replacement cleanup before acknowledging the upload: interruption
        // cannot leave an uploaded row whose obsolete versions were forgotten.
        for old in versions where old.fileId != uploaded.fileId {
            try await manifest.queueCloudDeletion(bucketID: bucket, key: objectKey, fileID: old.fileId)
        }
        do {
            try await manifest.markUploaded(key: objectKey, revision: row.revision,
                uploadedAt: Int64(Date().timeIntervalSince1970 * 1000), contentTag: uploaded.fileId)
        } catch SyncManifestError.pendingDeletion {
            suppress(objectKey, report: &report)
            try await manifest.queueCloudDeletion(bucketID: bucket, key: objectKey, fileID: uploaded.fileId)
        }
        if !encrypted { unlinkat(directory, ciphertext.lastPathComponent, 0) }
        try await drainDeletions(manifest: manifest, client: client, authorization: authorization, bucket: bucket, report: &report)
    }

    private static func suppress(_ key: String, report: inout SyncPlan) {
        if !report.purgeKeysAffected.contains(key) {
            report.purgeKeysAffected.append(key)
            report.purgeKeysAffected.sort()
            report.suppressedPendingPurges += 1
        }
    }

    private static func purge(manifest: SyncManifest, client: B2Client, authorization: B2Client.Authorization,
                               bucket: String, report: inout SyncPlan) async throws {
        for key in try await manifest.pendingDeletionKeys().sorted() {
            let versions = try await client.listFileVersions(authorization: authorization, bucketID: bucket, key: key)
            for version in versions {
                try await manifest.queueCloudDeletion(bucketID: bucket, key: key, fileID: version.fileId)
            }
        }
        try await drainDeletions(manifest: manifest, client: client, authorization: authorization, bucket: bucket, report: &report)
    }

    private static func drainDeletions(manifest: SyncManifest, client: B2Client, authorization: B2Client.Authorization,
                                        bucket: String, report: inout SyncPlan) async throws {
        for deletion in try await manifest.pendingCloudDeletions(bucketID: bucket) {
            // Reconcile before delete too: a crash can lose a successful delete response.
            let versions = try await client.listFileVersions(authorization: authorization, bucketID: bucket, key: deletion.key)
            if versions.contains(where: { $0.fileId == deletion.fileID }) {
                do {
                    let deleted = try await client.deleteFileVersion(authorization: authorization,
                        fileID: deletion.fileID, fileName: deletion.key)
                    guard deleted.fileId == deletion.fileID, deleted.fileName == deletion.key else { throw B2ClientError.invalidResponse }
                    report.deletes += 1
                } catch B2ClientError.fileNotPresent { /* Already deleted by a previous attempt. */ }
            }
            try await manifest.acknowledgeCloudDeletion(bucketID: bucket, key: deletion.key, fileID: deletion.fileID)
        }
    }

    private static func openDirectory(_ root: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SyncManifestError.unavailable }
        do {
            for component in root.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SyncManifestError.unsafeStateRoot }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
}
