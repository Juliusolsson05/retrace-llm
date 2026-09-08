import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ChunkInventory: Encodable, Sendable {
    struct Month: Encodable, Sendable {
        let month: String
        var fileCount: Int64 = 0
        var bytes: Int64 = 0
    }

    var status = "complete"
    var chunksPresent = false
    let observational = true
    var elapsedMs: Double = 0
    var visitedEntries = 0
    var entryLimit = 100_000
    var timeLimitMs: Double = 10_000
    let depthLimit = 4
    var months: [Month] = []
    var incompleteFileCount: Int64 = 0
    var noncanonicalFileCount: Int64 = 0
    var noncanonicalBytes: Int64 = 0
    var noncanonicalDirectoryCount: Int64 = 0
    var symlinkCount: Int64 = 0
    var otherEntryCount: Int64 = 0
    var errors: [String: Int] = [:]

    static func scan(root: URL, maxEntries: Int = 100_000, maxSeconds: Double = 10) async throws -> ChunkInventory {
        await Task.detached { scanSynchronously(root: root, maxEntries: maxEntries, maxSeconds: maxSeconds) }.value
    }

    static func scanSynchronously(root: URL, maxEntries: Int = 100_000, maxSeconds: Double = 10) -> ChunkInventory {
        let started = ProcessInfo.processInfo.systemUptime
        var result = ChunkInventory()
        result.entryLimit = maxEntries
        result.timeLimitMs = maxSeconds * 1000
        var byMonth: [String: Month] = [:]
        var stopped = false
        func failure(_ code: String) { result.errors[code, default: 0] += 1; result.status = "partial" }
        func withinBudget() -> Bool {
            guard !stopped else { return false }
            if result.visitedEntries >= maxEntries { failure("entry_limit"); stopped = true }
            else if ProcessInfo.processInfo.systemUptime - started >= maxSeconds { failure("time_limit"); stopped = true }
            return !stopped
        }
        // Descriptor-relative traversal never follows a directory or file symlink, even if
        // a directory entry is replaced between readdir and openat. No recording is opened.
        func walk(_ fd: Int32, components: [String]) {
            guard let directory = fdopendir(fd) else { close(fd); failure("directory_unreadable"); return }
            defer { closedir(directory) }
            while !stopped {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { failure("directory_read_failed") }
                    return
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard withinBudget() else { return }
                result.visitedEntries += 1
                var attributes = stat()
                guard fstatat(fd, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { failure("metadata_unreadable"); continue }
                let kind = attributes.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFLNK) { result.symlinkCount += 1; continue }
                if kind == mode_t(S_IFDIR) {
                    let next = components + [name]
                    let canonical = next.count == 1 ? validMonth(name) : (next.count == 2 && validDay(month: next[0], day: name))
                    if !canonical { result.noncanonicalDirectoryCount += 1 }
                    // Inspect irregular trees too, within a small explicit depth bound, so
                    // artifacts are separate aggregates instead of silently disappearing.
                    guard next.count <= 4 else { failure("depth_limit"); continue }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { failure("directory_unreadable"); continue }
                    walk(child, components: next)
                } else if kind == mode_t(S_IFREG) {
                    let bytes = max(0, Int64(attributes.st_size))
                    let canonical = components.count == 2 && validDay(month: components[0], day: components[1]) && validVideoID(name)
                    if canonical && bytes == 0 {
                        result.incompleteFileCount += 1
                    } else if canonical {
                        let month = String(components[0].prefix(4)) + "-" + String(components[0].suffix(2))
                        var total = byMonth[month] ?? Month(month: month)
                        let sum = total.bytes.addingReportingOverflow(bytes)
                        guard !sum.overflow else { failure("size_overflow"); stopped = true; return }
                        total.fileCount += 1
                        total.bytes = sum.partialValue
                        byMonth[month] = total
                    } else {
                        result.noncanonicalFileCount += 1
                        let sum = result.noncanonicalBytes.addingReportingOverflow(bytes)
                        guard !sum.overflow else { failure("size_overflow"); stopped = true; return }
                        result.noncanonicalBytes = sum.partialValue
                    }
                } else { result.otherEntryCount += 1 }
            }
        }

        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD < 0 { failure("root_unreadable") }
        else {
            defer { close(rootFD) }
            var attributes = stat()
            if fstatat(rootFD, "chunks", &attributes, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno != ENOENT { failure("chunks_unreadable") }
            } else {
                result.chunksPresent = true
                if attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    result.symlinkCount += 1
                    failure("chunks_symlink")
                } else {
                    let chunks = openat(rootFD, "chunks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if chunks < 0 { failure("chunks_unreadable") }
                    else { walk(chunks, components: []) }
                }
            }
        }
        result.months = byMonth.values.sorted { $0.month < $1.month }
        result.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }

    private static func validVideoID(_ name: String) -> Bool {
        guard let id = Int64(name), id > 0 else { return false }
        return String(id) == name
    }

    private static func validMonth(_ month: String) -> Bool {
        month.utf8.count == 6 && month.utf8.allSatisfy { (48...57).contains($0) }
            && (1...9999).contains(Int(month.prefix(4)) ?? 0) && (1...12).contains(Int(month.suffix(2)) ?? 0)
    }

    private static func validDay(month: String, day: String) -> Bool {
        guard validMonth(month), day.utf8.count == 2, day.utf8.allSatisfy({ (48...57).contains($0) }),
              let year = Int(month.prefix(4)), let monthNumber = Int(month.suffix(2)), let dayNumber = Int(day) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[monthNumber - 1]).contains(dayNumber)
    }
}
