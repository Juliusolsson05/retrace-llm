import Foundation
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      DISK SPACE MONITOR TESTS                                ║
// ║                                                                              ║
// ║  • Verify a volume with real free space never reports zero available bytes   ║
// ║  • Pin the rule for choosing between the two capacity readings               ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class DiskSpaceMonitorTests: XCTestCase {

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │  End-to-end against the live volume.                                     │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// The regression that motivated this suite.
    ///
    /// On macOS 26.x `volumeAvailableCapacityForImportantUsage` returns a *present*
    /// zero on every APFS volume — including a freshly created, completely empty one.
    /// `DiskSpaceMonitor` used a plain `if let`, which binds that zero happily, so the
    /// `systemFreeSize` fallback beneath it was unreachable and capture was halted on
    /// machines with hundreds of gigabytes free.
    ///
    /// This asserts the only thing that actually matters to callers: if the filesystem
    /// says there is real free space, we must not claim there is none.
    func testVolumeWithRealFreeSpaceNeverReportsZeroAvailableBytes() throws {
        let url = FileManager.default.temporaryDirectory

        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let systemFree = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw XCTSkip("Filesystem did not report systemFreeSize; nothing to compare against.")
        }
        // Only meaningful on a volume that genuinely has room. A truly full disk
        // reporting zero is correct behaviour, not the bug under test.
        try XCTSkipUnless(systemFree > 1_073_741_824, "Volume has under 1 GB free; cannot distinguish bug from truth.")

        let available = try DiskSpaceMonitor.availableBytes(at: url)

        XCTAssertGreaterThan(
            available,
            0,
            "DiskSpaceMonitor reported \(available) bytes available while the filesystem "
                + "reports \(systemFree) bytes free. A present-but-zero importantUsage reading "
                + "must fall through to systemFreeSize instead of being returned verbatim."
        )
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │  Deterministic coverage of the reading-selection rule.                   │
    // │                                                                          │
    // │  The test above only fails on an OS that actually exhibits the           │
    // │  present-but-zero behaviour. Once Apple fixes it, that test passes       │
    // │  trivially and would not notice `cap > 0` being refactored back into a   │
    // │  plain `if let`. These pin the rule itself, on every OS, forever.        │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testPresentButZeroImportantUsageFallsBackToSystemFreeSize() {
        let resolved = DiskSpaceMonitor.resolveAvailableBytes(importantUsage: 0, systemFree: 124_013_424_640)
        XCTAssertEqual(resolved, 124_013_424_640, "A zero importantUsage reading must not mask a healthy volume.")
    }

    func testMissingImportantUsageFallsBackToSystemFreeSize() {
        let resolved = DiskSpaceMonitor.resolveAvailableBytes(importantUsage: nil, systemFree: 5_000_000_000)
        XCTAssertEqual(resolved, 5_000_000_000)
    }

    func testPositiveImportantUsageIsPreferredOverSystemFreeSize() {
        // importantUsage is the better number when it is trustworthy: it accounts for
        // purgeable content the OS would evict on demand. Keep preferring it.
        let resolved = DiskSpaceMonitor.resolveAvailableBytes(importantUsage: 9_000_000_000, systemFree: 5_000_000_000)
        XCTAssertEqual(resolved, 9_000_000_000)
    }

    func testGenuinelyFullVolumeStillReportsZero() {
        // The fix must not invent free space. Zero from both sources stays zero, so the
        // critical-storage stop path still fires on a genuinely full disk.
        let resolved = DiskSpaceMonitor.resolveAvailableBytes(importantUsage: 0, systemFree: 0)
        XCTAssertEqual(resolved, 0)
    }
}
