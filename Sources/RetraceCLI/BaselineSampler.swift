import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Aggregated metrics parsed from retrace.log lines. Every recognized shape is quoted
/// from its production emit site in BaselineSamplerTests.swift so format drift fails
/// tests instead of silently miscounting.
struct HarvestedLogMetrics: Sendable {
    struct LatencySummary: Sendable, Equatable {
        var sampleCount = 0
        var totalCount = 0
        var latestMs = 0.0
        var p50Ms = 0.0
        var p95Ms = 0.0
        var maxMs = 0.0
    }

    var ocrCompletedCount = 0
    var ocrDurationSamplesMs: [Double] = []
    var dedupKeptCount = 0
    var dedupDroppedCount = 0
    var similaritySamplesPercent: [Double] = []
    var latencySummaries: [String: LatencySummary] = [:]
    var slowSampleCounts: [String: Int] = [:]
    var malformedMetricLines = 0
    var linesRead = 0

    static let similarityBucketLabels = [
        "0-9%", "10-19%", "20-29%", "30-39%", "40-49%",
        "50-59%", "60-69%", "70-79%", "80-89%", "90-100%",
    ]

    var similarityHistogram: [String: Int] {
        var buckets: [String: Int] = [:]
        for percent in similaritySamplesPercent {
            let index = max(0, min(9, Int(percent / 10)))
            buckets[Self.similarityBucketLabels[index], default: 0] += 1
        }
        return buckets
    }

    mutating func merge(_ other: HarvestedLogMetrics) {
        ocrCompletedCount += other.ocrCompletedCount
        ocrDurationSamplesMs += other.ocrDurationSamplesMs
        dedupKeptCount += other.dedupKeptCount
        dedupDroppedCount += other.dedupDroppedCount
        similaritySamplesPercent += other.similaritySamplesPercent
        for (metric, summary) in other.latencySummaries { latencySummaries[metric] = summary }
        for (metric, count) in other.slowSampleCounts { slowSampleCounts[metric, default: 0] += count }
        malformedMetricLines += other.malformedMetricLines
        linesRead += other.linesRead
    }
}

/// Pure parsing plus file/tail reading for baseline log harvesting. All line shapes
/// mirror real emit sites; lines carrying a metric marker that fail their pattern are
/// counted as malformed rather than guessed at.
enum BaselineLogHarvester {
    // Processing/FrameProcessingQueue.swift:1156
    private static let queueCompleted = #/\[Queue-DIAG\] Worker (\d+) COMPLETED frame (\S+) in (\d+(?:\.\d+)?)s/#
    // Shared/Logging.swift:266
    private static let perfSummary = #/\[PERF\] (\S+) n=(\d+) total=(\d+) latest=(\d+(?:\.\d+)?)ms p50=(\d+(?:\.\d+)?)ms p95=(\d+(?:\.\d+)?)ms min=(\d+(?:\.\d+)?)ms max=(\d+(?:\.\d+)?)ms/#
    // Shared/Logging.swift:253/258
    private static let perfSlowSample = #/\[PERF\] (\S+) slow sample: (\d+(?:\.\d+)?)ms \((?:warning|critical) >= (\d+(?:\.\d+)?)ms\)/#
    // Capture/CaptureManager.swift:1031. similarity is "xx.xx%" or bare "n/a";
    // threshold is "xx.xx%" or bare "disabled" — percentageLogDescription only
    // appends % to real numbers.
    private static let deduplication = #/Deduplication analysis \(trigger: (\S+), similarity: (\d+(?:\.\d+)?%|n\/a), threshold: (\d+(?:\.\d+)?%|disabled), keepBySimilarity: (n\/a|true|false), keepByMouseMovement: (true|false), outcome: (kept|deduplicated)\)/#

    static func harvest(url: URL) throws -> HarvestedLogMetrics {
        var metrics = HarvestedLogMetrics()
        var streamer = try LineStreamer(url: url)
        while let line = try streamer.next() {
            metrics.merge(harvest(line: line))
        }
        return metrics
    }

    static func harvest(line: Substring) -> HarvestedLogMetrics {
        var metrics = HarvestedLogMetrics()
        metrics.linesRead = 1
        // Cheap marker gate first: a 17MB production log is overwhelmingly ordinary
        // lines, and full regex matching on every one dominates runtime.
        if line.contains("[Queue-DIAG]") && line.contains("COMPLETED") {
            if let match = line.firstMatch(of: queueCompleted), let seconds = Double(String(match.output.3)) {
                metrics.ocrCompletedCount = 1
                metrics.ocrDurationSamplesMs = [seconds * 1000]
            } else {
                metrics.malformedMetricLines = 1
            }
        } else if line.contains("[PERF]") {
            if let match = line.firstMatch(of: perfSummary),
               let sampleCount = Int(String(match.output.2)), let totalCount = Int(String(match.output.3)),
               let latest = Double(String(match.output.4)), let p50 = Double(String(match.output.5)),
               let p95 = Double(String(match.output.6)), let maxMs = Double(String(match.output.8)) {
                metrics.latencySummaries[String(match.output.1)] = HarvestedLogMetrics.LatencySummary(
                    sampleCount: sampleCount, totalCount: totalCount, latestMs: latest,
                    p50Ms: p50, p95Ms: p95, maxMs: maxMs
                )
            } else if let match = line.firstMatch(of: perfSlowSample) {
                metrics.slowSampleCounts[String(match.output.1)] = 1
            } else {
                metrics.malformedMetricLines = 1
            }
        } else if line.contains("Deduplication analysis (") {
            if let match = line.firstMatch(of: deduplication) {
                if match.output.6 == "deduplicated" { metrics.dedupDroppedCount = 1 } else { metrics.dedupKeptCount = 1 }
                var text = String(match.output.2)
                if text.hasSuffix("%") { text.removeLast() }
                if let percent = Double(text) {
                    metrics.similaritySamplesPercent = [percent]
                }
            } else {
                metrics.malformedMetricLines = 1
            }
        }
        return metrics
    }

    /// Nearest-rank percentile on ascending samples, mirroring the app's own
    /// LatencyRecorder (Shared/Logging.swift:373). Nil for an empty sample set so the
    /// report can distinguish "no evidence" from a fabricated zero.
    static func percentile(_ samples: [Double], p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = min(max(p, 0), 1)
        return sorted[Int(round(clamped * Double(sorted.count - 1)))]
    }
}

/// Streams lines in bounded chunks; a trailing fragment without a newline is still
/// emitted as the final line (the file may have been mid-write). Consumption uses a
/// cursor with periodic compaction so a 50MB rotated log stays O(n), not O(n^2).
private struct LineStreamer {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var consumed = 0
    private var done = false

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("log_unreadable", "The requested log file does not exist.", exitCode: 3)
        }
        handle = try FileHandle(forReadingFrom: url)
    }

    mutating func next() throws -> Substring? {
        while true {
            // ArraySlice keeps base indices, so the found index addresses `buffer` directly.
            if let newline = buffer[consumed...].firstIndex(of: 0x0A) {
                let line = trimCarriageReturn(String(decoding: buffer[consumed..<newline], as: UTF8.self))[...]
                consumed = newline + 1
                if consumed > (1 << 20) { buffer.removeFirst(consumed); consumed = 0 }
                return line
            }
            guard !done else {
                guard consumed < buffer.count else { return nil }
                let line = trimCarriageReturn(String(decoding: buffer[consumed...], as: UTF8.self))[...]
                buffer.removeAll(keepingCapacity: true)
                consumed = 0
                return line
            }
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { done = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    private func trimCarriageReturn(_ text: String) -> String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }
}

/// One JSON report for both `baseline --session` and `baseline --harvest-log`. Nil
/// fields encode as explicit JSON nulls, never as invented zeros.
struct BaselineReport: Encodable {
    struct DedupCounts: Encodable { var kept: Int; var dropped: Int }
    struct LatencySummaryLine: Encodable {
        var metric: String
        var sampleCount: Int
        var totalCount: Int
        var p50Ms: Double
        var p95Ms: Double
        var maxMs: Double
        var slowSampleCount: Int
    }

    let schemaVersion = 1
    let command = "baseline"
    var status = "complete"
    var exitCode: Int32 = 0
    var elapsedMs = 0.0
    var mode = "session"
    var sampledSeconds: Int?
    var logPresent = true
    var processFound: Bool?
    var processSampleCount = 0
    /// Percent of a single core; can exceed 100 with multiple busy threads.
    var cpuP50Percent: Double?
    var cpuP95Percent: Double?
    var memFootprintP50Bytes: Double?
    var memFootprintP95Bytes: Double?
    var memFootprintMaxBytes: Double?
    var ocrCompletedCount = 0
    var ocrDurationP50Ms: Double?
    var ocrDurationP95Ms: Double?
    var dedupKeptVsDropped = DedupCounts(kept: 0, dropped: 0)
    var similarityHistogram: [String: Int] = [:]
    var latencySummaries: [LatencySummaryLine] = []
    var storageGrowthBytes: Int64?
    var logLinesRead = 0
    var malformedMetricLines = 0
    let note = "observational"
    var error: CLIError?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, command, status, exitCode, elapsedMs, mode, sampledSeconds, logPresent
        case processFound, processSampleCount, cpuP50Percent, cpuP95Percent
        case memFootprintP50Bytes, memFootprintP95Bytes, memFootprintMaxBytes
        case ocrCompletedCount, ocrDurationP50Ms, ocrDurationP95Ms, dedupKeptVsDropped
        case similarityHistogram, latencySummaries, storageGrowthBytes
        case logLinesRead, malformedMetricLines, note, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(command, forKey: .command)
        try c.encode(status, forKey: .status)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(elapsedMs, forKey: .elapsedMs)
        try c.encode(mode, forKey: .mode)
        try encodeNulling(sampledSeconds, key: .sampledSeconds, in: &c)
        try c.encode(logPresent, forKey: .logPresent)
        try encodeNulling(processFound, key: .processFound, in: &c)
        try c.encode(processSampleCount, forKey: .processSampleCount)
        try encodeNulling(cpuP50Percent, key: .cpuP50Percent, in: &c)
        try encodeNulling(cpuP95Percent, key: .cpuP95Percent, in: &c)
        try encodeNulling(memFootprintP50Bytes, key: .memFootprintP50Bytes, in: &c)
        try encodeNulling(memFootprintP95Bytes, key: .memFootprintP95Bytes, in: &c)
        try encodeNulling(memFootprintMaxBytes, key: .memFootprintMaxBytes, in: &c)
        try c.encode(ocrCompletedCount, forKey: .ocrCompletedCount)
        try encodeNulling(ocrDurationP50Ms, key: .ocrDurationP50Ms, in: &c)
        try encodeNulling(ocrDurationP95Ms, key: .ocrDurationP95Ms, in: &c)
        try c.encode(dedupKeptVsDropped, forKey: .dedupKeptVsDropped)
        try c.encode(similarityHistogram, forKey: .similarityHistogram)
        try c.encode(latencySummaries, forKey: .latencySummaries)
        try encodeNulling(storageGrowthBytes, key: .storageGrowthBytes, in: &c)
        try c.encode(logLinesRead, forKey: .logLinesRead)
        try c.encode(malformedMetricLines, forKey: .malformedMetricLines)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(error, forKey: .error)
    }

    private func encodeNulling<T: Encodable>(_ value: T?, key: CodingKeys, in c: inout KeyedEncodingContainer<CodingKeys>) throws {
        if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
    }

    static func summarizing(mode: String, metrics: HarvestedLogMetrics) -> BaselineReport {
        var report = BaselineReport()
        report.mode = mode
        report.ocrCompletedCount = metrics.ocrCompletedCount
        report.ocrDurationP50Ms = BaselineLogHarvester.percentile(metrics.ocrDurationSamplesMs, p: 0.5)
        report.ocrDurationP95Ms = BaselineLogHarvester.percentile(metrics.ocrDurationSamplesMs, p: 0.95)
        report.dedupKeptVsDropped = DedupCounts(kept: metrics.dedupKeptCount, dropped: metrics.dedupDroppedCount)
        report.similarityHistogram = metrics.similarityHistogram
        report.latencySummaries = metrics.latencySummaries
            .map { LatencySummaryLine(metric: $0.key, sampleCount: $0.value.sampleCount, totalCount: $0.value.totalCount,
                                      p50Ms: $0.value.p50Ms, p95Ms: $0.value.p95Ms, maxMs: $0.value.maxMs,
                                      slowSampleCount: metrics.slowSampleCounts[$0.key] ?? 0) }
            .sorted { $0.metric < $1.metric }
        report.logLinesRead = metrics.linesRead
        report.malformedMetricLines = metrics.malformedMetricLines
        return report
    }
}

/// Real-session sampling: process CPU/memory on a 1s cadence, rotation-aware log
/// tailing, and a canonical-chunk byte delta. The recorded app itself is out of scope;
/// this only observes it. Process disappearance mid-session yields fewer samples, not
/// an error, because the report is explicitly observational.
enum BaselineSampler {
    struct ProcessSample: Sendable {
        let totalCPUSeconds: Double
        let physFootprintBytes: Double
    }

    enum ProcessTarget: Sendable {
        case pid(Int32)
        case retraceApp
    }

    static let defaultLogURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Retrace/retrace.log").expandingTildeInPath)
    /// Shared/Logging.swift:438 rotates retrace.log to retrace.old.log.
    static let defaultRotatedLogURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Retrace/retrace.old.log").expandingTildeInPath)

    static func sampleProcess(pid: Int32) -> ProcessSample? {
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        // Footprint follows the app's own diagnostics (Processing/FrameProcessingQueue.swift
        // dlsyms proc_pid_rusage and reads ri_phys_footprint); CPU comes from the same
        // proc_taskinfo totals those diagnostics use. Either source failing drops the
        // sample rather than reporting a fabricated zero footprint.
        guard let footprint = Self.physFootprint(pid: pid) else { return nil }
        return ProcessSample(
            totalCPUSeconds: (Double(info.pti_total_user) + Double(info.pti_total_system)) / 1_000_000_000,
            physFootprintBytes: footprint
        )
    }

    private static let procPidRusage: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32).self)
    }()

    private static func physFootprint(pid: Int32) -> Double? {
        guard let procPidRusage else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            procPidRusage(pid, Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0))
        }
        guard result == 0 else { return nil }
        return Double(info.ri_phys_footprint)
    }

    /// Lowest PID whose executable name matches, so a relaunched app is preferred over
    /// any stale duplicate. p_comm is truncated to 16 bytes by the kernel.
    static func findProcessID(named name: String) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let entryStride = MemoryLayout<kinfo_proc>.stride
        var found: Int32?
        for offset in stride(from: 0, to: size, by: entryStride) where offset + entryStride <= size {
            let entry = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: kinfo_proc.self) }
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if comm == name {
                let pid = entry.kp_proc.p_pid
                if let current = found { found = min(current, pid) } else { found = pid }
            }
        }
        return found
    }

    static func harvestOffline(logURL: URL, requireExists: Bool) -> BaselineReport {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            if requireExists {
                var report = BaselineReport.summarizing(mode: "harvest-log", metrics: HarvestedLogMetrics())
                report.logPresent = false
                report.status = "failed"
                report.exitCode = 3
                report.error = CLIError("log_unreadable", "The requested log file does not exist.", exitCode: 3)
                return report
            }
            // The default log simply has not been written yet; absence is evidence, not failure.
            var report = BaselineReport.summarizing(mode: "harvest-log", metrics: HarvestedLogMetrics())
            report.logPresent = false
            return report
        }
        do {
            var report = BaselineReport.summarizing(mode: "harvest-log", metrics: try BaselineLogHarvester.harvest(url: logURL))
            report.logPresent = true
            return report
        } catch {
            var report = BaselineReport.summarizing(mode: "harvest-log", metrics: HarvestedLogMetrics())
            report.logPresent = true
            report.status = "failed"
            report.exitCode = 3
            report.error = (error as? CLIError) ?? CLIError("log_unreadable", "The requested log file could not be read.", exitCode: 3)
            return report
        }
    }

    static func runSession(seconds: Int, storageRoot: URL, logURL: URL,
                           rotatedLogURL: URL? = nil,
                           target: ProcessTarget = .retraceApp) async throws -> BaselineReport {
        let started = ProcessInfo.processInfo.systemUptime
        let before = canonicalBytes(ChunkInventory.scanSynchronously(root: storageRoot))
        let pid: Int32? = {
            switch target {
            case .pid(let pid): return pid
            case .retraceApp: return findProcessID(named: "Retrace")
            }
        }()
        var metrics = HarvestedLogMetrics()
        var tail = LogTail(url: logURL, rotatedURL: rotatedLogURL)
        var cpuPercentSamples: [Double] = []
        var footprintSamples: [Double] = []
        var processSamples = 0
        var previous: ProcessSample?
        var previousWall = started

        while true {
            if let pid, let sample = sampleProcess(pid: pid) {
                let wall = ProcessInfo.processInfo.systemUptime
                if let previous, wall > previousWall {
                    // Percent of one core over the interval since the previous sample.
                    let delta = sample.totalCPUSeconds - previous.totalCPUSeconds
                    cpuPercentSamples.append(max(0, delta / (wall - previousWall) * 100))
                }
                footprintSamples.append(sample.physFootprintBytes)
                processSamples += 1
                previous = sample
                previousWall = wall
            }
            metrics.merge(tail.poll())
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= Double(seconds) { break }
            let remaining = Double(seconds) - elapsed
            try await Task.sleep(for: .seconds(min(1, remaining)), clock: .continuous)
        }

        let after = canonicalBytes(ChunkInventory.scanSynchronously(root: storageRoot))
        var report = BaselineReport.summarizing(mode: "session", metrics: metrics)
        report.sampledSeconds = seconds
        report.processFound = pid != nil
        report.processSampleCount = processSamples
        report.cpuP50Percent = BaselineLogHarvester.percentile(cpuPercentSamples, p: 0.5)
        report.cpuP95Percent = BaselineLogHarvester.percentile(cpuPercentSamples, p: 0.95)
        report.memFootprintP50Bytes = BaselineLogHarvester.percentile(footprintSamples, p: 0.5)
        report.memFootprintP95Bytes = BaselineLogHarvester.percentile(footprintSamples, p: 0.95)
        report.memFootprintMaxBytes = footprintSamples.max()
        report.storageGrowthBytes = after - before
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return report
    }

    private static func canonicalBytes(_ inventory: ChunkInventory) -> Int64 {
        inventory.months.reduce(0) { $0 + $1.bytes }
    }
}

/// Rotation-aware incremental reader. When the live file shrinks past our offset it was
/// rotated away: drain what remains of the rotated sibling from the old offset first,
/// then restart at zero of the fresh file. A double rotation inside one interval loses
/// lines; the report is observational, and logLinesRead reflects exactly what was seen.
private struct LogTail {
    private let url: URL
    private let rotatedURL: URL?
    private var offset: UInt64 = 0
    private var pending: [UInt8] = []

    init(url: URL, rotatedURL: URL?) {
        self.url = url
        self.rotatedURL = rotatedURL
    }

    mutating func poll() -> HarvestedLogMetrics {
        var newBytes: [UInt8] = []
        if let size = fileSize(url), size < offset {
            if let rotatedURL, let rotatedSize = fileSize(rotatedURL), rotatedSize > offset,
               let handle = try? FileHandle(forReadingFrom: rotatedURL) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                if let remainder = try? handle.read(upToCount: Int(rotatedSize - offset)) { newBytes.append(contentsOf: remainder) }
            }
            offset = 0
            pending.removeAll(keepingCapacity: true)
        }
        if let size = fileSize(url), size > offset,
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            if let chunk = try? handle.read(upToCount: Int(size - offset)) {
                newBytes.append(contentsOf: chunk)
                offset = size
            }
        }
        pending.append(contentsOf: newBytes)
        var metrics = HarvestedLogMetrics()
        var consumed = 0
        while let newline = pending[consumed...].firstIndex(of: 0x0A) {
            let text = String(decoding: pending[consumed..<newline], as: UTF8.self)
            consumed = newline + 1
            var line = text[...]
            if line.hasSuffix("\r") { line = line.dropLast() }
            metrics.merge(BaselineLogHarvester.harvest(line: line))
        }
        if consumed > 0 {
            pending.removeFirst(consumed)
        }
        return metrics
    }

    private func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
    }
}
