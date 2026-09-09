import Foundation
import RetraceKit
import Attribution
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Database
import Shared
import Storage
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CLIResult: Sendable {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
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

private struct CLIPurgeReport: Encodable {
    let schemaVersion = 1
    let command: String
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs: Double = 0
    var purgeDay: String?
    var frameCount = 0
    var affectedKeys: [String] = []
    var recordedDeletions = 0
    var appliedLocal = 0
    let note = "Ledger acknowledgement only; no file deletion. Local deletion remains the app retention path. Cloud propagation executes when uploads are enabled and must delete every prior version; local acknowledgement does not clear upload suppression."
    var error: CLIError?
}

private struct CLIFrameReport: Encodable {
    struct Video: Encodable { var videoId: Int64; var videoFrameIndex: Int?; var chunkKey: String; var frameRate: Double? }
    struct Segment: Encodable {
        var segmentId: Int64; var appBundleId: String?; var appName: String?; var windowName: String?; var browserUrl: String?
        private enum CodingKeys: String, CodingKey { case segmentId, appBundleId, appName, windowName, browserUrl }
        // appName matches export's DataAdapter suffix semantics: derived, never a display-name lookup.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(segmentId, forKey: .segmentId)
            try container.encode(appBundleId, forKey: .appBundleId)
            try container.encodeIfPresent(appBundleId?.components(separatedBy: ".").last, forKey: .appName)
            try container.encodeIfPresent(windowName, forKey: .windowName)
            try container.encodeIfPresent(browserUrl, forKey: .browserUrl)
        }
    }
    struct OCRRegion: Encodable { var nodeOrder: Int; var text: String; var leftX: Double; var topY: Double; var width: Double; var height: Double; var windowIndex: Int? }
    struct ExtractedImage: Encodable { var pngPath: String; var byteCount: Int }

    let schemaVersion = 1
    let command = "frame"
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs = 0.0
    var frameId: Int64?
    var timestampMs: Int64?
    var textAvailable: Bool?
    var video: Video?
    var segment: Segment?
    var ocrRegionCount = 0
    var encryptedRegionCount = 0
    var ocrRegions: [OCRRegion] = []
    var image: ExtractedImage?
    var error: CLIError?
}

enum CLICommand {
    // Keep the human explanation in the executable so the JSON contract travels with it.
    private static let help = [
        "swift run retrace-cli help",
        "swift run retrace-cli status [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli baseline [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli baseline --session SECONDS [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli baseline --harvest-log [PATH] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli frame --frame-id N [--png PATH] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli classify --live [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli now [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli report [--day YYYY-MM-DD] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli sync --dry-run [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli sync --apply --phrase-from-stdin [--snapshot-current PATH] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli sync-plan --purge-day YYYY-MM-DD [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli purge-apply --day YYYY-MM-DD [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli key init|status|rotate [--state-root PATH] [--storage-root PATH]",
        "swift run retrace-cli key unwrap --phrase-from-stdin [--state-root PATH] [--storage-root PATH]",
        "swift run retrace-cli snapshot [--encrypt --phrase-from-stdin] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli verify --snapshot PATH [--phrase-from-stdin] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli restore --snapshot PATH --to DIR [--phrase-from-stdin] [--storage-root PATH] [--state-root PATH]",
        "swift run retrace-cli export --day YYYY-MM-DD [--storage-root PATH] [--state-root PATH] [--limit N]",
        "Key init explicitly creates a random backup key wrapped with AES-256-GCM by a NEW recovery master key. Its 22-word phrase is printed ONCE to stderr: save it privately offline. Only wrapped material is saved in state-root/backup-key.json. No app Keychain or credential access. Shared MasterKeyManager's custom syllabic recovery encoding is reused directly; it is not BIP39 and uses no PBKDF2, HKDF or salt. Key status prints presence/keyId/createdAtMs; key unwrap verifies stdin and prints status only. No phrase arguments or environment variables are accepted.",
        "Encrypted snapshot requires prior key init and --phrase-from-stdin. Pipe the phrase on stdin for snapshot --encrypt, verify, and restore; no prompts or persistent unlocked-key cache. RBC1 magic auto-detects encrypted inputs regardless of extension. Its authenticated 1 MiB AES-GCM chunks bind header/keyId, logical object key, index and total length. Snapshot AAD uses the stable logical key snapshots/database so moved copies remain recoverable. sha256 identifies ciphertext; plainSha256 records plaintext in lineage. format reports RBC1 or sqlite. Only validated plaintext is restored to retrace.db.",
        "Key rotate replaces the active key/phrase and invalidates prior objects for that active key. Old wrapped entries remain in backup-key-<keyId>.json and require their OLD phrase; new phrases cannot recover old objects. To recover old objects, copy their archived wrapped entry to backup-key.json in separate safe CLI state and supply the old phrase. Keep wrapped entries with backups. Restore does not require the old manifest or Keychain. sync --apply always encrypts uploads. Existing cloud objects encrypted by an older key still require its archived wrapped entry and old phrase.",
        "Build: swift build --product retrace-cli -j 4. Executable: .build/debug/retrace-cli. The installed command alias retrace is a later packaging step; the existing app product Retrace is separate.",
        "stdout: one JSON object for help/status/baseline/sync/sync-plan/purge-apply/key/snapshot/verify/restore, schemaVersion=1; diagnostics: stderr. Export streams JSONL frames to stdout and one summary JSON object to stderr, including on failure. No prompts or application startup.",
        "Exit codes: 0 complete, 2 invalid arguments/unsafe state path, 3 unavailable source/manifest/transfer, 4 partial inventory/plan, 5 metrics/output failure, 6 upload_disabled or sync_gate_missing (missingGates lists distinct gate codes).",
        "Sync without --apply or --dry-run exits 6 upload_disabled with missing gates. sync --apply requires key init, --phrase-from-stdin that unwraps the key, runtime B2_KEY_ID/B2_APPLICATION_KEY, a readable deletion ledger and current snapshot lineage. It implicitly creates and uploads an encrypted snapshot first; --snapshot-current explicitly asserts an existing verified snapshot is current and records fresh run lineage. --apply --dry-run remains plan-only and reads neither stdin nor credentials.",
        "Snapshot uses SQLite online backup from the read-only source connection into CLI state snapshots/<utc-ms>.db, including committed WAL rows. It pins a read transaction, copies 256 pages per step with bounded lock retries, and writes a standalone DELETE-mode database. It checks integrity, streams SHA-256 and records physical frame/video counts and lineage in sync-manifest.db. stdout includes absolute snapshotPath, sha256, sizeBytes, frameCount, videoCount, integrity, lineageId and elapsedMs.",
        "Verify recomputes integrity/counts/SHA-256 without writing the snapshot or manifest. The latest lineage for the snapshot path takes precedence; SHA-256 fallback supports moved copies. checks reports match/mismatch/unavailable per field and missing for an absent manifest row. Any mismatch, unavailable field or missing lineage exits 3. SQLite corruption still reports the hash comparison when the bytes are readable.",
        "Restore copies a standalone snapshot into an empty --to directory as retrace.db, then checks it read-only. A missing target is created. Nonempty targets, symlink components, hardlinked snapshots and source-contained paths are refused. --storage-root identifies the protected source for verify/restore and defaults to configured app storage; --state-root selects independent metrics/lineage state. Restore does not require lineage. Snapshots contain the whole database, including OCR; only metadata is printed. Media files, cloud recovery, encrypted sources and retention are outside this local database-only slice.",
        "Sync dry-run hashes canonical nonempty chunks with SHA-256 and B2 SHA-1 in 1 MiB reads. It reads the manifest without creating or migrating it; only independent metrics are written. Apply requires a bucket-restricted B2 application key with listFiles/writeFiles/deleteFiles and no name-prefix restriction. One independent state root is intended for one source and destination.",
        "Sync stdout is one schemaVersion=1 JSON object: wouldUpload (new/pending), wouldReupload (changed SHA-256, revision+1), unchangedCount (already uploaded), bytesTotal/objectsTotal (successfully hashed, unsuppressed candidates), suppressedPendingPurges (number of suppressed canonical nonempty files encountered), purgeKeysAffected (their sorted keys), noncanonical/incomplete/symlink counts, errors and elapsedMs. Purged keys are skipped before hashing and checked again after scanning. Object keys are relative canonical chunk paths; no file contents are emitted. The scan is bounded to 100000 entries and 10 seconds, including checks between 1 MiB reads. Filesystem calls can exceed that bound. Plans are observational, not a backup recovery point or proof of finalized media.",
        "sync-plan --purge-day records durable deletion intent in independent sync-manifest.db; this command writes ledger rows. It uses export's strict local day and visible-frame rules, including redacted frames. At most 50000 visible frames are resolved, with one lookahead; exceeding the bound or failing to resolve a key fails before recording any rows. JSON includes purgeDay, frameCount, affectedKeys (sorted canonical chunk keys), recordedDeletions (new rows only), status and note. Repeating a day reuses key/reason rows and resets their appliedLocal acknowledgement to 0.",
        "Purge keys use video.path (or relativePath when present), preserving the segment creation day and actual filename even when the DB video ID or frame day differs. Without a stored path, only plausible epoch-millisecond video IDs (2000...9999) use DirectoryManager's Calendar.current creation-day format; small sequence IDs or invalid/conflicting paths fail closed. The fallback assumes the original creation timezone/calendar. Frames without a video reference count toward frameCount but have no chunk key. Missing chunk files still receive ledger intent.",
        "purge-apply --day marks only recorded ledger rows appliedLocal=1; no file deletion is performed by purge-apply. Local deletion remains app retention. sync --apply lists and durably queues every cloud version of ledger keys, including keys whose local files are gone, then executes deleteFileVersion. Ledger suppression is permanent. Old database snapshots may still contain purged metadata; snapshot retention/redaction is not implemented.",
        "Storage defaults to Shared.AppPaths configured root; only an existing retrace.db is opened read-only. Paths may be relative or use ~; empty, memory and URI paths are rejected.",
        "Status counts native frame/video/node rows and frame timestamp coverage in Unix milliseconds. These are aggregate physical rows, including hidden/redacted rows, not a visibility-aware export API.",
        "Export requires a real date in strict YYYY-MM-DD format. It reads the local-calendar day, including its start and excluding next midnight, hidden segments, unsegmented frames, and deletion rewrites. Redacted frames remain visible. Rows are ordered by timestamp then frame ID; no OCR text or media paths are exported.",
        "Export frame keys: schemaVersion=1, frameId, timestampMs, videoId, videoFrameIndex, segmentId, appBundleId, appName, windowName, browserUrl. IDs/timestamps/indexes are integers; missing video references and metadata are explicit null. appName is the bundle-ID suffix used by DataAdapter, not an installed-app display-name lookup.",
        "Export defaults to --limit 5000 (allowed 1...50000). Summary frameCount, videoCount and segmentCount describe emitted frames and their distinct non-null video/segment IDs; limitApplied is the numeric limit. One visible lookahead row determines truncated. Truncation and empty days exit 0. On failure, already emitted lines remain valid but the export is incomplete; check exitCode/status. Counts and memory are bounded; SQLite may scan additional hidden/deleted rows.",
        "Baseline also inventories chunks/YYYYMM/DD/positive-decimal-videoID (no extension). Nonempty regular files are canonical candidates; zero-byte candidates are incomplete. Other files, directories, symlinks and errors are reported separately, without individual names.",
        "Baseline --session SECONDS (1...3600) samples the running Retrace process on a 1s cadence (proc_pidinfo CPU as percent of one core, phys_footprint bytes), tails ~/Library/Logs/Retrace/retrace.log with rotation awareness, and reports the canonical chunk byte delta between the start and end scans. If Retrace is not running, process fields are null with processFound=false; sampling disappearance is evidence, never a failure. CPU percent of one core can exceed 100 with multiple busy threads.",
        "Baseline --harvest-log [PATH] parses an existing log offline (default ~/Library/Logs/Retrace/retrace.log; a missing default reports logPresent=false, a missing explicit PATH exits 3 log_unreadable). Harvested shapes mirror the production emit sites: [Queue-DIAG] Worker COMPLETED durations, [PERF] p50/p95 summaries and slow samples, and Deduplication analysis outcomes with a decile similarity histogram (n/a similarities count toward outcomes only). Lines carrying one of those markers but failing the real emit format count as malformedMetricLines and are skipped. Percentiles are nearest-rank like the app's LatencyRecorder; absent evidence encodes as JSON null, not zero.",
        "Frame returns single-frame evidence INCLUDING OCR text and geometry — this is the inspection command, unlike export which is metadata-only by privacy design. Output: frameId, timestampMs, textAvailable (FTS ingestion can lag processing), video {videoId, videoFrameIndex, chunkKey, frameRate}, segment lineage with appName derived as export's bundle-ID suffix, and ocrRegions ordered by nodeOrder with text sliced exactly like the app's NodeQueries (SUBSTR over searchRanking_content c0||c1 via doc_segment; encrypted regions return same-length spaces and count in encryptedRegionCount). --png PATH additionally decodes the frame from its HEVC chunk read-only via the Storage extractor and writes a PNG that must live OUTSIDE the source storage root; decode failures exit 3 image_unavailable. All reads use the strict read-only source VFS; nothing in the source tree is modified.",
        "Attribution commands run the realtime project classifier progressively: no day dump, blocks classify as work changes. classify --live watches new frames through RetraceKit (read-only, WAL-safe), closes a block on app/window switch, capture gap or max span, enriches it with recent OCR text and ≤768px JPEGs of its boundary frames, and asks Gemini Flash-Lite (GEMINI_API_KEY env, never stored; model override RETRACE_LLM_MODEL is a later option) for {project, activity, confidence}, storing the result in independent attribution state (default ~/Library/Application Support/RetraceAttribution). A per-frame checkpoint makes restarts resume exactly; classification failures are logged and skipped, never fatal. now reports the latest classified block and today's per-project totals; report --day lists blocks and totals. Recorder data stays read-only; the harness never writes inside the storage root.",
        "Baseline file bytes are logical sizes, not allocated disk space. Month is the validated calendar directory label, not a timestamp or timezone inference. Files may be orphaned or unfinished; baseline performs no decoding, hashing or DB-to-file reconciliation. File counts do not equal frame counts; many frames share a video.",
        "Inventory is bounded to 100000 entries and 10 seconds between metadata operations. A filesystem call itself may take longer. A limit or I/O error returns partial counts and exit 4. Missing chunks is empty only when the database has no video rows.",
        "Live results are observational, not an atomic database/filesystem snapshot. Elapsed time measures this command only, not OCR, compression or a performance improvement.",
        "The source VFS forbids creation/deletion and uses readonly_shm. WAL databases need existing readable WAL/SHM sidecars; otherwise access fails without repairing or creating them. No immutable mode is used, so live WAL data is not silently ignored.",
        "Encryption-enabled source app configuration is still rejected before Keychain access. Backup object encryption is independent of SQLCipher and OCR protection.",
        "Command metrics use independent daily_metrics in CLI state. Metadata: command, outcome, durationMs?, errorCode?, truncated (export only); sync also records bytesUploaded, objectsUploaded, deletes and suppressedCount. No paths, content, phrases or credentials. Upload failures preserve per-object progress and retained ciphertext for explicit reruns; successful replacement uploads queue obsolete versions before acknowledging completion.",
    ]

    static func run(arguments: [String], writeFrame: (@Sendable (Data) throws -> Void)? = nil) async -> CLIResult {
        await run(arguments: arguments, readPhrase: { try CLIKeyCommand.readStdin() }, writeFrame: writeFrame)
    }

    static func run(arguments: [String], readPhrase: @escaping @Sendable () throws -> String,
                    b2Client: B2Client? = nil,
                    writeFrame: (@Sendable (Data) throws -> Void)? = nil) async -> CLIResult {
        // This executable never bootstraps an application. Blocking SQLite/POSIX work stays
        // on a worker even when the command runner is called from another async context.
        await Task.detached {
            if arguments.first == "key" { return await CLIKeyCommand.execute(arguments: Array(arguments.dropFirst()), readPhrase: readPhrase) }
            if arguments.first == "sync" {
                return await executeSync(arguments: Array(arguments.dropFirst()), readPhrase: readPhrase, b2Client: b2Client)
            }
            if let command = arguments.first, ["sync-plan", "purge-apply"].contains(command) {
                return await executePurge(command: command, arguments: Array(arguments.dropFirst()))
            }
            if arguments.first == "export" { return executeExport(arguments: Array(arguments.dropFirst()), writeFrame: writeFrame) }
            if let command = arguments.first, ["snapshot", "verify", "restore"].contains(command) {
                return await executeSnapshotCommand(command: command, arguments: Array(arguments.dropFirst()), readPhrase: readPhrase)
            }
            if arguments.first == "baseline",
               arguments.dropFirst().contains(where: { $0 == "--session" || $0.hasPrefix("--session") || $0 == "--harvest-log" }) {
                return await executeBaselineSampling(arguments: Array(arguments.dropFirst()))
            }
            if arguments.first == "frame" { return await executeFrame(arguments: Array(arguments.dropFirst())) }
            if let command = arguments.first, ["classify", "now", "report"].contains(command) {
                return await executeAttribution(command: command, arguments: Array(arguments.dropFirst()))
            }
            return execute(arguments: arguments)
        }.value
    }

    private static func executeAttribution(command: String, arguments: [String]) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any?] = [
            "schemaVersion": 1, "command": command, "status": "complete",
            "exitCode": Int32(0), "elapsedMs": 0.0,
        ]
        var exitCode: Int32 = 0
        var reportError: CLIError?
        do {
            let options = try parseOptions(arguments, attributionCommand: command)
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            // Attribution state is deliberately independent from CLI sync state.
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceAttribution")
            if command == "classify" {
                guard options["--live"] != nil else { throw usage() }
                guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
                    throw CLIError("llm_key_missing", "Export GEMINI_API_KEY before running the realtime classifier (BYO key; it is never stored).", exitCode: 3)
                }
                try await LiveClassifier.run(storageRoot: root, stateRoot: state, config: .init(apiKey: apiKey)) { line in
                    FileHandle.standardError.write(Data(("retrace: \(line)\n").utf8))
                }
                report["note"] = "classifier stopped; checkpoint persisted"
            } else if command == "now" {
                let store = try AttributionStore(stateRoot: state, sourceRoot: root)
                let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
                let blocks = try store.blocks(sinceMs: Int64(dayStart))
                report["latestBlock"] = blocks.last.map { b in
                    ["project": b.project, "activity": b.activity, "startedAtMs": b.startedAtMs,
                     "endedAtMs": b.endedAtMs, "confidence": b.confidence, "app": b.appBundleId ?? NSNull()] as [String: Any?]
                } ?? NSNull()
                report["todayMsByProject"] = try store.totals(sinceMs: Int64(dayStart))
                report["blockCount"] = blocks.count
            } else {
                let store = try AttributionStore(stateRoot: state, sourceRoot: root)
                let day: Date
                if let label = options["--day"] { day = try parseDay(label) } else { day = Date() }
                let dayStart = Int64(Calendar.current.startOfDay(for: day).timeIntervalSince1970 * 1000)
                let dayEnd = dayStart + 86_400_000
                let blocks = try store.blocks(sinceMs: dayStart).filter { $0.endedAtMs <= dayEnd }
                report["day"] = dayString(day)
                report["msByProject"] = blocks.reduce(into: [String: Int64]()) { totals, b in
                    totals[b.project, default: 0] += b.durationMs
                }
                report["blocks"] = blocks.map { b in
                    ["id": b.id, "project": b.project, "activity": b.activity, "startedAtMs": b.startedAtMs,
                     "endedAtMs": b.endedAtMs, "app": b.appBundleId ?? NSNull(), "window": b.windowName ?? NSNull()] as [String: Any?]
                }
            }
        } catch {
            let failure = error as? CLIError ?? CLIError("attribution_unavailable", "Attribution command failed.", exitCode: 3)
            report["status"] = "failed"
            exitCode = failure.exitCode
            reportError = failure
        }
        report["exitCode"] = exitCode
        report["elapsedMs"] = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        report["error"] = reportError.map { ["code": $0.code, "message": $0.message] as [String: String] }
        do {
            let value = try JSONSerialization.data(withJSONObject: report.compactMapValues { $0 ?? NSNull() })
            var bytes = value
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: reportError.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func executeFrame(arguments: [String]) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIFrameReport()
        var metrics: CLIStateMetrics?
        do {
            let options = try parseOptions(arguments, frameCommand: true)
            guard let idText = options["--frame-id"], let frameId = Int64(idText) else { throw usage() }
            report.frameId = frameId
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: "frame", outcome: "started")
            guard let evidence = try SourceDatabase.withConnection(root: root, {
                try SourceDatabase.frameEvidence($0, frameId: frameId)
            }) else {
                throw CLIError("frame_not_found", "No frame with the supplied id exists in this source database.", exitCode: 3)
            }
            report.timestampMs = evidence.timestampMs
            report.textAvailable = evidence.textAvailable
            report.video = evidence.video.map { CLIFrameReport.Video(videoId: $0.videoId, videoFrameIndex: $0.videoFrameIndex, chunkKey: $0.chunkKey, frameRate: $0.frameRate) }
            report.segment = evidence.segment.map { CLIFrameReport.Segment(segmentId: $0.segmentId, appBundleId: $0.appBundleId, appName: nil, windowName: $0.windowName, browserUrl: $0.browserUrl) }
            report.ocrRegionCount = evidence.regions.count
            report.encryptedRegionCount = evidence.encryptedRegionCount
            report.ocrRegions = evidence.regions.map { CLIFrameReport.OCRRegion(nodeOrder: $0.nodeOrder, text: $0.text, leftX: $0.leftX, topY: $0.topY, width: $0.width, height: $0.height, windowIndex: $0.windowIndex) }
            if let png = options["--png"] {
                report.image = try await extractFramePNG(target: try localPath(png), evidence: evidence, root: root)
            }
        } catch {
            let failure = error as? CLIError ?? CLIError("frame_unavailable", "Frame evidence could not be read.", exitCode: 3)
            report.status = "failed"
            report.exitCode = failure.exitCode
            report.error = failure
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: "frame", outcome: report.status == "complete" ? "succeeded" : report.status,
                                   durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch {
                report.status = "failed"
                report.exitCode = 5
                report.error = CLIError("metrics_unavailable", "Could not persist frame command outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\"}}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    /// Decodes the frame's HEVC chunk read-only and writes a PNG outside the source tree.
    private static func extractFramePNG(target: URL, evidence: SourceDatabase.FrameEvidence, root: URL) async throws -> CLIFrameReport.ExtractedImage {
        let rootCanonical = try CLIStateMetrics.canonicalPath(root)
        let targetCanonical = try CLIStateMetrics.canonicalPath(target)
        guard targetCanonical != rootCanonical, !targetCanonical.hasPrefix(rootCanonical + "/") else {
            throw CLIError("invalid_path", "--png must write outside the source storage root; extraction never modifies recordings.", exitCode: 2)
        }
        guard let video = evidence.video, !video.chunkKey.isEmpty else {
            throw CLIError("image_unavailable", "This frame has no video chunk reference to decode.", exitCode: 3)
        }
        let chunk = root.appendingPathComponent(video.chunkKey)
        var attributes = stat()
        guard lstat(chunk.path, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CLIError("image_unavailable", "The frame's video chunk is missing or not a regular file.", exitCode: 3)
        }
        do {
            let extractor = HEVCStorageExtractor(storageRoot: root.path)
            let image = try await extractor.extractFrameCGImage(videoPath: chunk.path, frameIndex: video.videoFrameIndex ?? 0, frameRate: video.frameRate)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CLIError("image_unavailable", "Decoded frame could not be encoded as PNG.", exitCode: 3)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CLIError("image_unavailable", "Decoded frame could not be encoded as PNG.", exitCode: 3)
            }
            try (data as Data).write(to: target)
            return CLIFrameReport.ExtractedImage(pngPath: target.path, byteCount: (data as Data).count)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("image_unavailable", "Frame image could not be decoded from its video chunk.", exitCode: 3)
        }
    }

    private static func executeBaselineSampling(arguments: [String]) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report: BaselineReport
        var metrics: CLIStateMetrics?
        do {
            let options = try parseOptions(arguments, baselineCommand: true)
            let session = options["--session"]
            let harvest = options["--harvest-log"]
            guard session == nil || harvest == nil else { throw usage() }
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: "baseline", outcome: "started")
            if let harvest {
                // An explicit path must exist; the default log merely may not have been
                // written yet, and absence is recorded rather than failing the report.
                if harvest == "true" {
                    report = BaselineSampler.harvestOffline(logURL: BaselineSampler.defaultLogURL, requireExists: false)
                } else {
                    report = BaselineSampler.harvestOffline(logURL: try localPath(harvest), requireExists: true)
                }
            } else {
                guard let text = session, let seconds = Int(text), (1...3600).contains(seconds) else { throw usage() }
                report = try await BaselineSampler.runSession(
                    seconds: seconds, storageRoot: root,
                    logURL: BaselineSampler.defaultLogURL,
                    rotatedLogURL: BaselineSampler.defaultRotatedLogURL,
                    target: .retraceApp
                )
            }
        } catch {
            let failure = error as? CLIError ?? CLIError("baseline_unavailable", "Baseline sampling could not be completed.", exitCode: 3)
            report = BaselineReport.summarizing(mode: "unknown", metrics: HarvestedLogMetrics())
            report.status = "failed"
            report.exitCode = failure.exitCode
            report.error = failure
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: "baseline", outcome: report.status == "complete" ? "succeeded" : report.status,
                                   durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch {
                report.status = "failed"
                report.exitCode = 5
                report.error = CLIError("metrics_unavailable", "Could not persist baseline outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\"}}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    private static func execute(arguments: [String]) -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIReport(command: "unknown")
        var metrics: CLIStateMetrics?
        do {
            guard let command = arguments.first, ["help", "status", "baseline"].contains(command) else {
                throw CLIError("usage", "Use swift run retrace-cli help, status, baseline, export, sync --dry-run, sync-plan --purge-day, purge-apply --day, snapshot, verify, or restore.", exitCode: 2)
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

    private static func executeSync(arguments: [String], readPhrase: @Sendable () throws -> String,
                                    b2Client: B2Client?) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = SyncPlan()
        var metrics: CLIStateMetrics?
        do {
            let options = try parseOptions(arguments, sync: true)
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            var currentSnapshot: URL?
            if options["--apply"] != nil, options["--dry-run"] == nil, let path = options["--snapshot-current"] {
                currentSnapshot = try localPath(path)
                // Match verify/restore: metrics must never alter the supplied input.
                do { try SnapshotStore.validateMetricsSeparation(currentSnapshot!, state: state) }
                catch { throw SyncEngine.gateError(["snapshot_current_missing"]) }
            }
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: "sync", outcome: "started")
            if options["--dry-run"] != nil {
                report = try await SyncPlanner.plan(root: root, state: state)
            } else {
                let client = b2Client ?? B2Client(enabled: options["--apply"] != nil)
                let apply = options["--apply"] != nil
                let (key, missing) = await SyncEngine.checkGates(root: root, state: state,
                    fromStdin: apply && options["--phrase-from-stdin"] != nil, readPhrase: readPhrase, client: client)
                guard apply else {
                    throw SyncEngine.gateError(missing + ["apply_required", "snapshot_current_missing"], disabled: true)
                }
                guard let key, missing.isEmpty else { throw SyncEngine.gateError(missing + ["snapshot_current_missing"]) }
                try await SyncEngine.apply(root: root, state: state, key: key, client: client,
                    currentSnapshot: currentSnapshot, report: &report)
            }
        } catch {
            let failure: CLIError
            if let cliError = error as? CLIError { failure = cliError }
            else if error is B2ClientError {
                failure = CLIError("sync_transport_failed", "B2 operation failed. Rerun sync --apply to resume durable uploads and deletions.")
            } else if error is ObjectCryptoError {
                failure = CLIError("sync_crypto_failed", "Upload ciphertext could not be authenticated or prepared.")
            } else if error as? SyncManifestError == .unsafeStateRoot {
                failure = CLIError("unsafe_state_root", "Manifest state must be outside source storage, without symlink or hardlink aliases; choose another --state-root.", exitCode: 2)
            } else { failure = CLIError("manifest_unavailable", "Could not read the independent sync manifest; no repair or migration was attempted.") }
            report.status = "failed"
            report.error = failure
            report.exitCode = failure.exitCode
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: "sync", outcome: report.status == "complete" ? "succeeded" : report.status,
                                   durationMs: report.elapsedMs, errorCode: report.error?.code,
                                   bytesUploaded: report.bytesUploaded, objectsUploaded: report.objectsUploaded,
                                   deletes: report.deletes, suppressedCount: report.suppressedPendingPurges)
            } catch {
                report.status = "failed"
                report.exitCode = 5
                report.error = CLIError("metrics_unavailable", "Could not persist sync outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\"}}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    private static func executePurge(command: String, arguments: [String]) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIPurgeReport(command: command)
        var metrics: CLIStateMetrics?
        do {
            let options = try parseOptions(arguments, purgeCommand: command)
            guard let label = options[command == "sync-plan" ? "--purge-day" : "--day"] else { throw usage() }
            let day: Date
            do { day = try parseDay(label) } catch { throw usage() }
            report.purgeDay = label
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: command, outcome: "started")
            // Complete every bounded source read before the ledger transaction. Apply
            // deliberately consults only recorded intent: retention may have run already.
            let evidence: SourceDatabase.PurgeEvidence?
            if command == "sync-plan" {
                evidence = try SourceDatabase.withConnection(root: root, allowMissingVideoPath: true) {
                    try SourceDatabase.purgeEvidence($0, config: .retrace(storageRoot: root.path), day: day)
                }
            } else { evidence = nil }
            let manifest = try await SyncManifest.open(root: state, sourceRoot: root)
            do {
                let reason = "purge-day:\(label)"
                let recordedKeys = try await manifest.deletionKeys(reason: reason)
                let keys = recordedKeys.union(evidence?.keys ?? []).sorted()
                if let evidence {
                    report.recordedDeletions = try await manifest.recordPendingDeletions(keys: keys, reason: reason)
                    report.frameCount = evidence.frameCount
                } else {
                    report.appliedLocal = try await manifest.markAppliedLocal(keys: keys, reason: reason)
                }
                report.affectedKeys = keys
                try await manifest.close()
            } catch {
                try? await manifest.close()
                throw error
            }
        } catch {
            let failure: CLIError
            if let cliError = error as? CLIError { failure = cliError }
            else if error as? SyncManifestError == .unsafeStateRoot {
                failure = CLIError("unsafe_state_root", "Purge ledger state must be outside source storage without symlink or hardlink aliases.", exitCode: 2)
            } else if error is SyncManifestError {
                failure = CLIError("manifest_unavailable", "Could not read or persist the deletion ledger; purge suppression fails closed.")
            } else {
                failure = CLIError("database_unreadable", "Could not read source evidence; no deletion rows were recorded.")
            }
            report.status = "failed"
            report.exitCode = failure.exitCode
            report.error = failure
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: command, outcome: report.status == "complete" ? "succeeded" : "failed",
                                   durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch {
                report.status = "failed"
                report.exitCode = 5
                report.error = CLIError("metrics_unavailable", "Could not persist purge command outcome in independent CLI state.", exitCode: 5)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\"}}\n".utf8),
                             stderr: "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    private static func executeSnapshotCommand(command: String, arguments: [String], readPhrase: @Sendable () throws -> String) async -> CLIResult {
        let started = ProcessInfo.processInfo.systemUptime
        var report = SnapshotReport(command: command)
        var metrics: CLIStateMetrics?
        do {
            let options = try parseOptions(arguments, snapshotCommand: command)
            guard command == "snapshot" || options["--snapshot"] != nil,
                  command != "restore" || options["--to"] != nil else { throw usage() }
            let root = try localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            let file = try options["--snapshot"].map { try localPath($0) }
            let target = try options["--to"].map { try localPath($0) }
            if let file { try SnapshotStore.validateMetricsSeparation(file, state: state) }
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: command, outcome: "started")
            if let file { try SnapshotStore.validateInput(file, root: root) }
            let encrypted: Bool
            if let file { encrypted = try await ObjectCrypto.isEncrypted(file) }
            else { encrypted = options["--encrypt"] != nil }
            report.format = encrypted ? "RBC1" : "sqlite"
            var key: ObjectCrypto.Key?
            if encrypted {
                key = try await CLIKeyCommand.unlock(state: state, root: root, fromStdin: options["--phrase-from-stdin"] != nil, readPhrase: readPhrase)
            } else if options["--phrase-from-stdin"] != nil { throw usage() }
            switch command {
            case "snapshot": report = try await SnapshotStore.create(root: root, state: state, key: key)
            case "verify": report = try await SnapshotStore.verify(file: file!, root: root, state: state, key: key)
            default: report = try await SnapshotStore.restore(file: file!, target: target!, root: root, key: key)
            }
        } catch {
            let failure: CLIError
            if let cliError = error as? CLIError { failure = cliError }
            else if error is BackupKeyError { failure = CLIKeyCommand.failure(error) }
            else if error is ObjectCryptoError { failure = CLIError("object_authentication_failed", "Encrypted object could not be authenticated or read.") }
            else if error as? SyncManifestError == .unsafeStateRoot {
                failure = CLIError("unsafe_state_root", "Snapshot lineage state must be outside source storage without symlink or hardlink aliases.", exitCode: 2)
            } else if error is SyncManifestError {
                failure = CLIError("manifest_unavailable", "Could not read or persist independent snapshot lineage.")
            } else {
                failure = CLIError("snapshot_unavailable", "Local snapshot operation failed; no source repair or migration was attempted.")
            }
            report.fail(failure)
        }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let metrics {
            do {
                try metrics.record(command: command, outcome: report.status == "complete" ? "succeeded" : "failed",
                                   durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch {
                report.fail(CLIError("metrics_unavailable", "Could not persist snapshot command outcome in independent CLI state.", exitCode: 5))
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(report)
            bytes.append(0x0A)
            return CLIResult(stdout: bytes, stderr: report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? "", exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5,\"error\":{\"code\":\"output_failed\"}}\n".utf8),
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

    static func usage() -> CLIError {
        CLIError("usage", "Expected required command arguments and each supported option at most once; see swift run retrace-cli help.", exitCode: 2)
    }

    static func parseOptions(_ arguments: [String], export: Bool = false, sync: Bool = false,
                             snapshotCommand: String? = nil, purgeCommand: String? = nil, keyCommand: String? = nil,
                             baselineCommand: Bool = false, frameCommand: Bool = false,
                             attributionCommand: String? = nil) throws -> [String: String] {
        var allowed = ["--storage-root", "--state-root"]
        if export { allowed += ["--day", "--limit"] }
        if sync { allowed.append("--snapshot-current") }
        if snapshotCommand == "verify" || snapshotCommand == "restore" { allowed.append("--snapshot") }
        if snapshotCommand == "restore" { allowed.append("--to") }
        if purgeCommand == "sync-plan" { allowed.append("--purge-day") }
        if purgeCommand == "purge-apply" { allowed.append("--day") }
        if baselineCommand { allowed.append("--session") }
        if frameCommand { allowed += ["--frame-id", "--png"] }
        if attributionCommand == "report" { allowed.append("--day") }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if attributionCommand == "classify", option == "--live", values[option] == nil {
                values[option] = "true"
                index += 1
                continue
            }
            // --harvest-log may stand alone (default log) or take an explicit path.
            if baselineCommand, option == "--harvest-log", values[option] == nil {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[option] = arguments[index + 1]
                    index += 2
                } else {
                    values[option] = "true"
                    index += 1
                }
                continue
            }
            let flag = (sync && ["--dry-run", "--apply", "--phrase-from-stdin"].contains(option))
                || (snapshotCommand == "snapshot" && option == "--encrypt")
                || ((snapshotCommand != nil || keyCommand == "unwrap") && option == "--phrase-from-stdin")
            if flag, values[option] == nil {
                values[option] = "true"
                index += 1
                continue
            }
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
