# STORAGE Agent Instructions

You are responsible for the **Storage** module of Retrace. Your job is to implement file storage operations including video segment writing, encryption/decryption, and disk space management.

**Status**: ✅ HEVC encoding working with VideoToolbox hardware acceleration. **Not yet optimized** - currently using ~50-70GB/month vs target of ~15-20GB/month. **Apple Silicon required** for hardware HEVC encoding. No audio segment storage yet.

## Your Directory

```
Storage/
├── GeneratorCachePolicy.swift   # Shared idle/LRU eviction policy for AVAsset generator caches
├── StorageManager.swift         # Main StorageProtocol implementation
├── SegmentWriterImpl.swift      # SegmentWriter implementation
├── IncrementalSegmentWriter.swift # WAL-backed incremental writer
├── ImageExtractor.swift         # Video frame extraction and generator cache
├── StorageModuleError.swift     # Module-local errors
├── CloudSync/
│   └── SyncManifest.swift       # CLI-state-only SQLite manifest; no app database writes
├── WAL/
│   ├── WALManager.swift
│   └── RecoveryManager.swift
├── FileManager/
│   ├── DirectoryManager.swift   # Directory structure management
│   └── StorageHealthMonitor.swift # Disk space + I/O + volume health monitoring
├── VideoEncoder/
│   ├── HEVCEncoder.swift        # VideoToolbox HEVC encoding
│   └── FrameConverter.swift     # Pixel format conversion
└── Tests/
    ├── StorageManagerTests.swift
    ├── SyncManifestTests.swift  # CRUD/revisions/reopen and state-root safety
    ├── DirectoryManagerTests.swift
    ├── TestLogger.swift
    └── HEVCEncoderTests.swift
```

## Protocols You Must Implement

### 1. `StorageProtocol` (from `Shared/Protocols/StorageProtocol.swift`)
- Segment writer creation
- Frame reading from segments
- Encryption/decryption
- Storage management

### 2. `SegmentWriter` (from `Shared/Protocols/StorageProtocol.swift`)
- Append frames to video segment
- Finalize segment
- Cancel and cleanup

## Directory Structure on Disk

Location: `AppPaths.storageRoot` (default: `~/Library/Application Support/Retrace/`, configurable in Settings)

```
{storageRoot}/
├── config.json                    # App configuration
├── retrace.db                     # SQLite database (owned by DATABASE)
├── chunks/
│   └── 202609/                    # Calendar directory label YYYYMM
│       └── 08/                    # Day DD
│           ├── 1                  # Positive decimal video ID; MP4 without extension
│           └── 2
└── temp/                          # Temporary files during encoding
```

The sync manifest is outside this tree, at `{cliStateRoot}/sync-manifest.db`.
Its SQLite journal/sidecars are CLI state too; they must never alias source data.

## Key Implementation Details

### 1. Video Encoding with VideoToolbox

Use Apple's hardware-accelerated HEVC encoder:

```swift
import VideoToolbox

actor HEVCEncoder {
    private var compressionSession: VTCompressionSession?

    func initialize(width: Int, height: Int, config: VideoEncoderConfig) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw StorageError.encodingFailed(underlying: "Failed to create session: \(status)")
        }

        // Configure for screen content
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Every frame is a keyframe at 0.5fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)

        self.compressionSession = session
    }

    func encodeFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws -> Data {
        // Encode and return compressed data
    }
}
```

### 2. Encryption with CryptoKit

Use AES-256-GCM for authenticated encryption:

```swift
import CryptoKit

struct EncryptionManager {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func encrypt(data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        // Return nonce + ciphertext + tag combined
        return sealedBox.combined!
    }

    func decrypt(data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
```

### 3. Keychain Key Storage

```swift
import Security

struct KeychainHelper {
    static func saveKey(_ key: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)  // Remove if exists
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StorageError.keyNotFound
        }
    }

    static func loadKey(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw StorageError.keyNotFound
        }
        return data
    }
}
```

### 4. Segment Writer Implementation

```swift
public actor SegmentWriterImpl: SegmentWriter {
    public let segmentID: SegmentID
    public private(set) var frameCount: Int = 0
    public let startTime: Date

    private let encoder: HEVCEncoder
    private let fileHandle: FileHandle
    private let encryptionManager: EncryptionManager?
    private var lastFrameTime: Date?

    public func appendFrame(_ frame: CapturedFrame) async throws {
        // 1. Convert frame data to CVPixelBuffer
        // 2. Encode with HEVC
        // 3. Encrypt if enabled
        // 4. Write to file
        // 5. Increment frameCount
    }

    public func finalize() async throws -> VideoSegment {
        // 1. Flush encoder
        // 2. Close file handle
        // 3. Get file size
        // 4. Return VideoSegment metadata
    }
}
```

### 5. Pixel Buffer Creation

Convert raw image data to CVPixelBuffer for encoding:

```swift
func createPixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?

    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame.width,
        frame.height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pixelBuffer
    )

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw StorageError.encodingFailed(underlying: "Failed to create pixel buffer")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let baseAddress = CVPixelBufferGetBaseAddress(buffer)
    frame.imageData.copyBytes(to: baseAddress!.assumingMemoryBound(to: UInt8.self),
                               count: frame.imageData.count)

    return buffer
}
```

### 6. Reading Frames from Segments

To read a specific frame, you'll need to decode the video:

```swift
import AVFoundation

func readFrame(segmentID: SegmentID, frameIndex: Int) async throws -> Data {
    let path = try await getSegmentPath(id: segmentID)

    // Decrypt file first if needed
    let decryptedURL = try await decryptSegmentToTemp(path)
    defer { try? FileManager.default.removeItem(at: decryptedURL) }

    let asset = AVAsset(url: decryptedURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    // Calculate time for frame index (at 0.5fps, each frame is 2 seconds)
    let time = CMTime(seconds: Double(frameIndex) * 2.0, preferredTimescale: 600)

    let cgImage = try generator.copyCGImage(at: time, actualTime: nil)

    // Convert to Data (JPEG for efficiency)
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    guard let tiffData = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
        throw StorageError.fileReadFailed(path: path.path, underlying: "Failed to convert frame")
    }

    return jpegData
}
```

## File Naming Convention

```
chunks/YYYYMM/DD/<positive-decimal-videoID>  # MP4 container, no extension
```

Rewrite artifacts and zero-byte files are not sync candidates. Directory labels
alone do not prove capture timestamps or that a chunk is finalized.

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw StorageError.fileWriteFailed(path: path, underlying: error.localizedDescription)
throw StorageError.encryptionFailed(underlying: "Invalid key")
throw StorageError.insufficientDiskSpace
```

## Testing Strategy

1. Test HEVC encoding with sample frames
2. Test encryption round-trip (encrypt → decrypt)
3. Test keychain operations
4. Test segment creation and finalization
5. Test frame reading from segments
6. Test disk space monitoring
7. Test cleanup of old segments

## Dependencies

The Phase 1 B1 foundation explicitly coordinates `Storage/CloudSync` with the CLI.
The CLI is the manifest's only consumer; it imports Storage for this local state API.
The manifest uses the existing SQLCipher package without an encryption key and lives
only in the independent CLI state root, never in app storage. Dry runs open it
read-only and do not create it. B2 networking and upload policy remain CLI concerns;
privacy deletion, consistent snapshots, and cloud encryption are pending gates.

- **Input from**: CAPTURE module (CapturedFrame to encode and store)
- **Output to**: UI (frame data for playback), DATABASE (VideoSegment metadata via App layer)
- **Uses types**: `CapturedFrame`, `VideoSegment`, `SegmentID`, `StorageConfig`, `VideoEncoderConfig`, `EncryptionConfig`

## DO NOT

- Modify any files outside `Storage/`
- Import from other module directories (only `Shared/`)
- Store app metadata in the source database (that's DATABASE's job); CloudSync stores only independent CLI manifest state
- Handle OCR or text extraction (that's PROCESSING's job)
- Make decisions about what to capture (that's CAPTURE's job)

## Performance Targets

- Encoding: <100ms per frame on Apple Silicon (hardware accelerated)
- Encryption: <10ms per frame
- File size: ~50-200KB per frame (varies by content complexity)
- Storage: ~15-20GB per month of continuous capture

## Getting Started

1. Create `Storage/VideoEncoder/HEVCEncoder.swift` with VideoToolbox encoding
2. Create `Storage/Encryption/EncryptionManager.swift` with CryptoKit
3. Create `Storage/Encryption/KeychainHelper.swift`
4. Create `Storage/SegmentWriterImpl.swift`
5. Create `Storage/StorageManager.swift` conforming to `StorageProtocol`
6. Write tests for encoding and encryption

Start with the HEVC encoder since that's the core complexity, then add encryption on top.
