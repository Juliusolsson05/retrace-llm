import CryptoKit
import Foundation
import Darwin

public enum ObjectCryptoError: Error, Sendable { case invalidContainer, authenticationFailed, unavailable, changedInput }

/// RBC1 wire format (all integers unsigned big endian): magic[4], version[1],
/// canonical UUID keyId[36], totalLength[8], chunkCount[8], then nonce[12] +
/// ciphertext[inferred plaintext length] + tag[16] for each 1 MiB chunk.
/// Even empty objects have one sealed empty chunk, authenticating their header.
/// AAD = domain + header + objectKey byte length[8] + objectKey UTF-8 + index[8].
/// This binds every header field, object identity, ordering and final length.
public enum ObjectCrypto {
    public struct Key: Sendable {
        public let keyId: String
        public let material: SymmetricKey
        public init(keyId: String, material: SymmetricKey) { self.keyId = keyId; self.material = material }
    }

    private static let chunkSize = 1_048_576
    private static let headerSize = 57

    public static func encryptFile(_ file: URL, objectKey: String, key: Key, temporaryDirectory: URL? = nil) async throws -> URL {
        try await Task.detached { try transform(file, objectKey: objectKey, key: key, encrypt: true, directory: temporaryDirectory) }.value
    }

    public static func decryptFile(_ file: URL, objectKey: String, key: Key) async throws -> URL {
        try await Task.detached { try transform(file, objectKey: objectKey, key: key, encrypt: false, directory: nil) }.value
    }

    public static func isEncrypted(_ file: URL) async throws -> Bool {
        try await Task.detached {
            let (input, _) = try CryptoFileIO.input(file)
            defer { try? input.close() }
            return try input.read(upToCount: 4) == Data("RBC1".utf8)
        }.value
    }

    /// Hashes every container byte, including its authenticated header and tags.
    public static func sha256(file: URL) async throws -> String {
        try await Task.detached {
            let (input, before) = try CryptoFileIO.input(file)
            defer { try? input.close() }
            var digest = SHA256()
            while let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty {
                try Task.checkCancellation()
                digest.update(data: bytes)
            }
            try CryptoFileIO.requireUnchanged(input, before: before)
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func transform(_ file: URL, objectKey: String, key: Key, encrypt: Bool, directory: URL?) throws -> URL {
        guard key.material.bitCount == 256, UUID(uuidString: key.keyId)?.uuidString == key.keyId,
              !objectKey.isEmpty, objectKey.utf8.count <= 4096 else { throw ObjectCryptoError.invalidContainer }
        let (input, before) = try CryptoFileIO.input(file)
        defer { try? input.close() }
        let header: Data
        let length: UInt64
        let count: UInt64
        if encrypt {
            length = UInt64(before.st_size)
            count = max(1, length / UInt64(chunkSize) + (length % UInt64(chunkSize) == 0 ? 0 : 1))
            header = Data("RBC1".utf8) + Data([1]) + Data(key.keyId.utf8) + integer(length) + integer(count)
        } else {
            header = try CryptoFileIO.readExactly(input, count: headerSize)
            guard header.prefix(5) == Data("RBC1".utf8) + Data([1]),
                  Data(header[5..<41]) == Data(key.keyId.utf8) else { throw ObjectCryptoError.authenticationFailed }
            length = number(header[41..<49])
            count = number(header[49..<57])
            let expected = max(1, length / UInt64(chunkSize) + (length % UInt64(chunkSize) == 0 ? 0 : 1))
            guard count == expected, length <= UInt64(Int64.max),
                  count <= (UInt64.max - length - UInt64(headerSize)) / 28,
                  UInt64(before.st_size) == UInt64(headerSize) + length + count * 28 else {
                throw ObjectCryptoError.invalidContainer
            }
        }
        let (url, output) = try CryptoFileIO.temporary(in: directory)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: url) }
        }
        if encrypt { try output.write(contentsOf: header) }
        let aadPrefix = Data("retrace-object-rbc1".utf8) + header + integer(UInt64(objectKey.utf8.count)) + Data(objectKey.utf8)
        for index in 0..<count {
            try Task.checkCancellation()
            let size = Int(min(UInt64(chunkSize), length - min(length, index * UInt64(chunkSize))))
            let aad = aadPrefix + integer(index)
            if encrypt {
                let bytes = try CryptoFileIO.readExactly(input, count: size)
                let box = try AES.GCM.seal(bytes, using: key.material, authenticating: aad)
                guard let combined = box.combined else { throw ObjectCryptoError.unavailable }
                try output.write(contentsOf: combined)
            } else {
                let bytes = try CryptoFileIO.readExactly(input, count: size + 28)
                do {
                    let box = try AES.GCM.SealedBox(combined: bytes)
                    try output.write(contentsOf: AES.GCM.open(box, using: key.material, authenticating: aad))
                } catch { throw ObjectCryptoError.authenticationFailed }
            }
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw ObjectCryptoError.changedInput }
        try CryptoFileIO.requireUnchanged(input, before: before)
        try output.synchronize()
        try output.close()
        complete = true
        return url
    }

    private static func integer(_ value: UInt64) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
    private static func number(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// Descriptor-based I/O shared only within CloudSync. All callers run on workers.
enum CryptoFileIO {
    static func directory(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectCryptoError.unavailable }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw SyncManifestError.unsafeStateRoot }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SyncManifestError.unsafeStateRoot }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    static func input(_ url: URL) throws -> (FileHandle, stat) {
        let directory = try directory(url.deletingLastPathComponent())
        defer { close(directory) }
        let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectCryptoError.unavailable }
        var item = stat()
        guard fstat(fd, &item) == 0, item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              item.st_nlink == 1, item.st_size >= 0 else {
            close(fd)
            throw SyncManifestError.unsafeStateRoot
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), item)
    }

    static func readExactly(_ input: FileHandle, count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let next = try input.read(upToCount: count - bytes.count), !next.isEmpty else {
                throw ObjectCryptoError.invalidContainer
            }
            bytes.append(next)
        }
        return bytes
    }

    static func requireUnchanged(_ input: FileHandle, before: stat) throws {
        var after = stat()
        guard fstat(input.fileDescriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ObjectCryptoError.changedInput
        }
    }

    static func temporary(in supplied: URL?) throws -> (URL, FileHandle) {
        let root: URL
        if let supplied { root = supplied }
        else {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ObjectCryptoError.unavailable }
            defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical))
        }
        let directory = try directory(root)
        defer { close(directory) }
        let name = ".retrace-crypto-\(UUID().uuidString)"
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ObjectCryptoError.unavailable }
        return (root.appendingPathComponent(name), FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}
