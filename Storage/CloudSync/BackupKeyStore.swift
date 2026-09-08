import CryptoKit
import Foundation
import Security
import Shared
import Darwin

public enum BackupKeyError: Error, Sendable, Equatable { case missing, exists, invalidStore, unlockFailed, randomFailed, unavailable }

/// Independent backup key, wrapped by a newly generated recovery master key. Never
/// calls Shared's Keychain/defaults APIs and never persists unwrapped material.
public enum BackupKeyStore {
    public static let filename = "backup-key.json"

    public struct Status: Encodable, Sendable {
        public let present: Bool
        public let keyId: String?
        public let createdAtMs: Int64?
    }

    public struct Creation: Sendable {
        public let status: Status
        public let recoveryPhrase: String
    }

    struct KDFParams: Codable, Equatable, Sendable {
        let algorithm: String
        let wordCount: Int
        let keyBytes: Int
        let checksum: String
        let salt: String
        let iterations: Int
        static let current = KDFParams(algorithm: "retrace-master-key-recovery-v1", wordCount: 22,
            keyBytes: 32, checksum: "SHA256-first-byte", salt: "", iterations: 0)
    }

    struct Record: Codable, Sendable {
        let version: Int
        let wrappedKey: Data // Ciphertext + 16-byte GCM tag, never plaintext.
        let nonce: Data
        let kdfParams: KDFParams
        let createdAtMs: Int64
        let keyId: String

        func authenticatedData() throws -> Data {
            struct Header: Encodable {
                let version: Int
                let kdfParams: KDFParams
                let createdAtMs: Int64
                let keyId: String
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Data("retrace-backup-key-v1".utf8) + (try encoder.encode(Header(version: version,
                kdfParams: kdfParams, createdAtMs: createdAtMs, keyId: keyId)))
        }
        var status: Status { Status(present: true, keyId: keyId, createdAtMs: createdAtMs) }
    }

    /// Reuses Shared/MasterKeyManager.swift recoveryPhrase(for:) and
    /// keyData(fromRecoveryPhrase:) (lines 190–224, syllables 68–87,
    /// packing/checksum 477–534 at implementation). This is NOT BIP39: 4096 syllabic words encode
    /// 32 random bytes + one SHA256 checksum byte directly. No PBKDF2/HKDF or salt.
    static func wrappingKey(from phrase: String) throws -> SymmetricKey {
        do { return SymmetricKey(data: try MasterKeyManager.keyData(fromRecoveryPhrase: phrase)) }
        catch { throw BackupKeyError.unlockFailed } // Shared's errors can contain phrase words.
    }

    public static func status(root: URL, sourceRoot: URL) async throws -> Status {
        try await Task.detached {
            guard try SyncManifest.validateState(root: root, sourceRoot: sourceRoot, create: false, filenames: [filename]) else {
                return Status(present: false, keyId: nil, createdAtMs: nil)
            }
            return try load(root: root)?.status ?? Status(present: false, keyId: nil, createdAtMs: nil)
        }.value
    }

    public static func initialize(root: URL, sourceRoot: URL, rotate: Bool = false) async throws -> Creation {
        try await Task.detached {
            _ = try SyncManifest.validateState(root: root, sourceRoot: sourceRoot, create: true, filenames: [filename])
            let directory = try CryptoFileIO.directory(root)
            defer { close(directory) }
            // Serialize init/rotate across CLI processes. Reads see an atomic rename.
            guard flock(directory, LOCK_EX) == 0 else { throw BackupKeyError.unavailable }
            defer { flock(directory, LOCK_UN) }
            let old = try load(root: root)
            if !rotate, old != nil { throw BackupKeyError.exists }
            if rotate, old == nil { throw BackupKeyError.missing }
            let raw = try randomBytes()
            let phrase = MasterKeyManager.recoveryPhrase(for: try randomBytes())
            let wrapping = try wrappingKey(from: phrase)
            let keyID = UUID().uuidString
            let created = Int64(Date().timeIntervalSince1970 * 1000)
            let header = Record(version: 1, wrappedKey: Data(), nonce: Data(), kdfParams: .current, createdAtMs: created, keyId: keyID)
            let sealed = try AES.GCM.seal(raw, using: wrapping, authenticating: header.authenticatedData())
            let record = Record(version: 1, wrappedKey: sealed.ciphertext + sealed.tag,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) }, kdfParams: .current, createdAtMs: created, keyId: keyID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let old {
                // Rotation invalidates old objects for the active key. Preserve ONLY
                // their wrapped entry: recovery needs this archive AND the old phrase.
                let archive = "backup-key-\(old.keyId).json"
                _ = try SyncManifest.validateState(root: root, sourceRoot: sourceRoot, create: false, filenames: [archive])
                let original = try read(root.appendingPathComponent(filename))
                var item = stat()
                if fstatat(directory, archive, &item, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard try read(root.appendingPathComponent(archive)) == original else { throw BackupKeyError.invalidStore }
                } else {
                    guard errno == ENOENT else { throw BackupKeyError.unavailable }
                    try save(original, root: root, directory: directory, name: archive, replace: false)
                }
            }
            try save(encoder.encode(record), root: root, directory: directory, name: filename, replace: rotate)
            return Creation(status: record.status, recoveryPhrase: phrase)
        }.value
    }

    public static func unwrap(root: URL, sourceRoot: URL, phrase: String) async throws -> ObjectCrypto.Key {
        try await Task.detached {
            guard try SyncManifest.validateState(root: root, sourceRoot: sourceRoot, create: false, filenames: [filename]),
                  let record = try load(root: root) else { throw BackupKeyError.missing }
            do {
                let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: record.nonce),
                    ciphertext: record.wrappedKey.dropLast(16), tag: record.wrappedKey.suffix(16))
                let raw = try AES.GCM.open(sealed, using: wrappingKey(from: phrase), authenticating: record.authenticatedData())
                guard raw.count == 32 else { throw BackupKeyError.unlockFailed }
                return ObjectCrypto.Key(keyId: record.keyId, material: SymmetricKey(data: raw))
            } catch { throw BackupKeyError.unlockFailed }
        }.value
    }

    private static func randomBytes() throws -> Data {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw BackupKeyError.randomFailed }
        return bytes
    }

    private static func load(root: URL) throws -> Record? {
        let file = root.appendingPathComponent(filename)
        var item = stat()
        if lstat(file.path, &item) != 0 {
            guard errno == ENOENT else { throw BackupKeyError.unavailable }
            return nil
        }
        let bytes = try read(file)
        do {
            let keys = (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?.keys
            guard Set(keys.map(Array.init) ?? []) == ["version", "wrappedKey", "nonce", "kdfParams", "createdAtMs", "keyId"] else {
                throw BackupKeyError.invalidStore
            }
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.version == 1, record.kdfParams == .current, record.wrappedKey.count == 48,
                  record.nonce.count == 12, record.createdAtMs >= 0,
                  UUID(uuidString: record.keyId)?.uuidString == record.keyId else { throw BackupKeyError.invalidStore }
            return record
        } catch { throw BackupKeyError.invalidStore }
    }

    private static func read(_ file: URL) throws -> Data {
        let (input, before) = try CryptoFileIO.input(file)
        defer { try? input.close() }
        guard before.st_size <= 4096 else { throw BackupKeyError.invalidStore }
        let bytes = try CryptoFileIO.readExactly(input, count: Int(before.st_size))
        try CryptoFileIO.requireUnchanged(input, before: before)
        return bytes
    }

    private static func save(_ bytes: Data, root: URL, directory: Int32, name: String, replace: Bool) throws {
        let (temporary, output) = try CryptoFileIO.temporary(in: root)
        defer { try? output.close(); unlinkat(directory, temporary.lastPathComponent, 0) }
        try output.write(contentsOf: bytes)
        try output.synchronize()
        try output.close()
        guard renameatx_np(directory, temporary.lastPathComponent, directory, name, replace ? 0 : UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw BackupKeyError.unavailable }
    }
}
