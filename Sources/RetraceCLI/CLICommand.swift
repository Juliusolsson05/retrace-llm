import Foundation
import Database
import Shared

struct CLIResult: Sendable {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
}

struct CLIError: Error, Encodable, Sendable {
    let code: String
    let message: String
    let exitCode: Int32

    init(_ code: String, _ message: String, exitCode: Int32 = 3) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }
}

private struct CLIReport: Encodable {
    let schemaVersion = 1
    var command: String
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs: Double = 0
    var database: DatabaseSummary?
    var inventory: ChunkInventory?
    var error: CLIError?
    var help: [String]?
}

private struct CLIExportSummary: Encodable {
    let schemaVersion = 1
    let command = "export"
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs: Double = 0
    var day: String?
    var limitApplied = 5000
    var frameCount = 0
    var videoCount = 0
    var segmentCount = 0
    var truncated = false
    var error: CLIError?
}

enum CLICommand {
    // Keep the human explanation in the executable so the JSON contract travels with it.
    private static let help = [
        "swift run retrace-cli help",
        "swift run retrace-cli status [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli baseline [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli export --day YYYY-MM-DD [--storage-root PATH] [--state-root PATH] [--limit N]",
        "Build: swift build --product retrace-cli -j 4. Executable: .build/debug/retrace-cli. The installed command alias retrace is a later packaging step; the existing app product Retrace is separate.",
        "stdout: one JSON object for help/status/baseline, schemaVersion=1; diagnostics: stderr. Export streams JSONL frames to stdout and one summary JSON object to stderr, including on failure. No prompts or application startup.",
        "Exit codes: 0 complete, 2 invalid arguments/unsafe state path, 3 unavailable or unsupported source, 4 partial inventory, 5 metrics/output failure.",
        "Storage defaults to Shared.AppPaths configured root; only an existing retrace.db is opened read-only. Paths may be relative or use ~; empty, memory and URI paths are rejected.",
        "Status counts native frame/video/node rows and frame timestamp coverage in Unix milliseconds. These are aggregate physical rows, including hidden/redacted rows, not a visibility-aware export API.",
        "Export requires a real date in strict YYYY-MM-DD format. It reads the local-calendar day, including its start and excluding next midnight, hidden segments, unsegmented frames, and deletion rewrites. Redacted frames remain visible. Rows are ordered by timestamp then frame ID; no OCR text or media paths are exported.",
        "Export frame keys: schemaVersion=1, frameId, timestampMs, videoId, videoFrameIndex, segmentId, appBundleId, appName, windowName, browserUrl. IDs/timestamps/indexes are integers; missing video references and metadata are explicit null. appName is the bundle-ID suffix used by DataAdapter, not an installed-app display-name lookup.",
        "Export defaults to --limit 5000 (allowed 1...50000). Summary frameCount, videoCount and segmentCount describe emitted frames and their distinct non-null video/segment IDs; limitApplied is the numeric limit. One visible lookahead row determines truncated. Truncation and empty days exit 0. On failure, already emitted lines remain valid but the export is incomplete; check exitCode/status. Counts and memory are bounded; SQLite may scan additional hidden/deleted rows.",
        "Baseline also inventories chunks/YYYYMM/DD/positive-decimal-videoID (no extension). Nonempty regular files are canonical candidates; zero-byte candidates are incomplete. Other files, directories, symlinks and errors are reported separately, without individual names.",
        "File bytes are logical sizes, not allocated disk space. Month is the validated calendar directory label, not a timestamp or timezone inference. Files may be orphaned or unfinished; no decoding, hashing or DB-to-file reconciliation occurs. File counts do not equal frame counts; many frames share a video.",
        "Inventory is bounded to 100000 entries and 10 seconds between metadata operations. A filesystem call itself may take longer. A limit or I/O error returns partial counts and exit 4. Missing chunks is empty only when the database has no video rows.",
        "Live results are observational, not an atomic database/filesystem snapshot. Elapsed time measures this command only, not OCR, compression or a performance improvement.",
        "The source VFS forbids creation/deletion and uses readonly_shm. WAL databases need existing readable WAL/SHM sidecars; otherwise access fails without repairing or creating them. No immutable mode is used, so live WAL data is not silently ignored.",
        "Encryption-enabled app configuration is rejected before Keychain access; this stage does not request or load keys.",
        "Command metrics use an independent daily_metrics table in ~/Library/Application Support/RetraceCLI/metrics.db (override with --state-root). Metadata: command, outcome (started/succeeded/failed/partial), durationMs?, errorCode?, truncated (export only). No paths/content/keys. Source-contained, symlink or hardlink state aliases are rejected. Help/usage errors do not write metrics."
    ]

    static func run(arguments: [String], writeFrame: (@Sendable (Data) throws -> Void)? = nil) async -> CLIResult {
        // This executable never bootstraps an application. Blocking SQLite/POSIX work stays
        // on a worker even when the command runner is called from another async context.
        await Task.detached {
            if arguments.first == "export" { return executeExport(arguments: Array(arguments.dropFirst()), writeFrame: writeFrame) }
            return execute(arguments: arguments)
        }.value
    }

    private static func execute(arguments: [String]) -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIReport(command: "unknown")
        var metrics: CLIStateMetrics?
        do {
            guard let command = arguments.first, ["help", "status", "baseline"].contains(command) else {
                throw CLIError("usage", "Use swift run retrace-cli help, status, baseline, or export.", exitCode: 2)
            }
            report.command = command
            if command == "help" {
                guard arguments.count == 1 else { throw usage() }
                report.help = help
            } else {
                let options = try parseOptions(Array(arguments.dropFirst()))
                let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot)
                    .resolvingSymlinksInPath()
                let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
                metrics = try CLIStateMetrics(root: state, sourceRoot: root)
                try metrics?.record(command: command, outcome: "started")
                report.database = try SourceDatabase.withConnection(root: root) { try SourceDatabase.aggregate($0) }
                if command == "baseline" {
                    var inventory = ChunkInventory.scanSynchronously(root: root)
                    if !inventory.chunksPresent, report.database!.videoCount > 0 {
                        inventory.errors["chunks_missing_with_video_rows", default: 0] += 1
                        inventory.status = "partial"
                    }
                    report.inventory = inventory
                    if inventory.status == "partial" {
                        report.status = "partial"
                        report.exitCode = 4
                        report.error = CLIError("inventory_partial", "Inventory is partial; inspect aggregate inventory errors and limits.", exitCode: 4)
                    }
                }
            }
        } catch {
            let failure = error as? CLIError ?? CLIError("database_unreadable", "Could not read source metadata; no repair or migration was attempted.")
            report.status = "failed"
            report.error = failure
            report.exitCode = failure.exitCode
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: report.command, outcome: report.status == "complete" ? "succeeded" : report.status,
                                   durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch {
                report.status = "failed"
                report.exitCode = 5
                report.error = CLIError("metrics_unavailable", "Could not persist command outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\",\"message\":\"JSON encoding failed.\"}}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    private static func executeExport(arguments: [String], writeFrame: (@Sendable (Data) throws -> Void)?) -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var summary = CLIExportSummary()
        var metrics: CLIStateMetrics?
        var stdout = Data()
        var videos: Set<Int64> = []
        var segments: Set<Int64> = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let options = try parseOptions(arguments, export: true)
            guard let label = options["--day"] else { throw exportUsage() }
            let day = try parseDay(label)
            summary.day = label
            if let value = options["--limit"] {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let limit = Int(value), (1...50000).contains(limit) else { throw exportUsage() }
                summary.limitApplied = limit
            }
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: "export", outcome: "started", truncated: false)
            let limit = summary.limitApplied
            summary.truncated = try SourceDatabase.withConnection(root: root) { connection in
                try SourceDatabase.exportFrames(connection, config: .retrace(storageRoot: root.path), day: day, limit: limit) { frame in
                    do {
                        var line = try encoder.encode(frame)
                        line.append(0x0A)
                        // Production supplies a writer; only in-process callers that omit
                        // it collect the bounded output for inspection.
                        if let writeFrame { try writeFrame(line) } else { stdout.append(line) }
                    } catch {
                        throw CLIError("output_failed", "Could not encode or write frame JSONL.", exitCode: 5)
                    }
                    summary.frameCount += 1
                    if let videoID = frame.videoId { videos.insert(videoID) }
                    segments.insert(frame.segmentId)
                }
            }
        } catch {
            let failure = error as? CLIError ?? CLIError("database_unreadable", "Could not read source evidence; no repair or migration was attempted.")
            summary.status = "failed"
            summary.error = failure
            summary.exitCode = failure.exitCode
        }
        summary.videoCount = videos.count
        summary.segmentCount = segments.count
        summary.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: "export", outcome: summary.status == "complete" ? "succeeded" : "failed",
                                   durationMs: summary.elapsedMs, errorCode: summary.error?.code, truncated: summary.truncated)
            } catch {
                summary.status = "failed"
                summary.exitCode = 5
                summary.error = CLIError("metrics_unavailable", "Could not persist command outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let bytes = try encoder.encode(summary)
            return CLIResult(stdout: stdout, stderr: String(decoding: bytes, as: UTF8.self) + "\n", exitCode: summary.exitCode)
        } catch {
            return CLIResult(stdout: stdout,
                             stderr: "{\"schemaVersion\":1,\"command\":\"export\",\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\",\"message\":\"JSON encoding failed.\"}}\n",
                             exitCode: 5)
        }
    }

    private static func exportUsage() -> CLIError {
        CLIError("usage", "Expected export --day YYYY-MM-DD [--storage-root PATH] [--state-root PATH] [--limit 1...50000], each option at most once.", exitCode: 2)
    }

    private static func parseDay(_ value: String) throws -> Date {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), year > 0,
              let month = Int(value.dropFirst(5).prefix(2)), let day = Int(value.suffix(2)) else { throw exportUsage() }
        // YYYY-MM-DD uses Gregorian components in the local timezone. Round-tripping
        // rejects Foundation's normalization of impossible dates (such as February 30).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { throw exportUsage() }
        return date
    }

    private static func usage() -> CLIError {
        CLIError("usage", "Expected each of --storage-root PATH and --state-root PATH at most once; see swift run retrace-cli help.", exitCode: 2)
    }

    private static func parseOptions(_ arguments: [String], export: Bool = false) throws -> [String: String] {
        let allowed = ["--storage-root", "--state-root"] + (export ? ["--day", "--limit"] : [])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option), values[option] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw export ? exportUsage() : usage()
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        return values
    }

    static func localPath(_ path: String) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.contains("\0"), !path.contains(":memory:"), !path.contains("mode=memory"),
              path.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else {
            throw CLIError("invalid_path", "Supply a nonempty filesystem directory path; memory and URI paths are not supported.", exitCode: 2)
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var components: [Substring] = []
        for component in absolute.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        // Foundation standardization can rewrite an existing /private/var path as /var
        // (a symlink on macOS). Preserve the caller's lexical path for no-follow state I/O.
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }
}
