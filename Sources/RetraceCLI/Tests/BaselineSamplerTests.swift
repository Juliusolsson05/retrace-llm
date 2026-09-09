import Foundation
import XCTest
@testable import RetraceKit
@testable import RetraceCLI

/// Fixtures quote the production emit sites verbatim so the parser tracks real formats:
///
/// Line wrapper — Shared/Logging.swift:305
///   "[\(timestamp())] [\(level)] [\(category.rawValue)] \(filename):\(line) - \(message)"
///
/// OCR queue completion — Processing/FrameProcessingQueue.swift:1156
///   Log.info("[Queue-DIAG] Worker \(id) COMPLETED frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", ...)
///
/// Latency summaries — Shared/Logging.swift:266
///   Log.info("[PERF] \(metric) n=\(snapshot.sampleCount) total=\(snapshot.totalCount) latest=\(...)ms p50=\(...)ms p95=\(...)ms min=\(...)ms max=\(...)ms", ...)
/// Slow samples — Shared/Logging.swift:253/258
///   "[PERF] \(metric) slow sample: \(latest)ms (critical >= \(...)ms)" / "(warning >= \(...)ms)"
///
/// Deduplication — Capture/CaptureManager.swift:1031
///   "Deduplication analysis (trigger: \(triggerDescription), similarity: \(similarityDescription), threshold: \(thresholdDescription), keepBySimilarity: \(keepBySimilarityDescription), keepByMouseMovement: \(keepByMouseMovement), outcome: \(outcome))"
///   where similarity is String(format: "%.2f%%", value * 100) or "n/a", threshold likewise or "disabled",
///   and outcome is "kept" or "deduplicated" (CaptureManager.swift:895/919/949).
///
/// Percentile semantics mirror the app's own LatencyRecorder (Shared/Logging.swift:373):
///   index = Int(round(p * Double(sorted.count - 1))) on ascending samples.
final class BaselineSamplerTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL { sandbox.appendingPathComponent("recordings") }
    private var state: URL { sandbox.appendingPathComponent("cli-state") }

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        sandbox = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("BaselineSamplerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func writeLog(_ lines: [String], name: String = "fixture.log") throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func json(_ result: CLIResult) throws -> [String: Any] {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        return value
    }

    private func run(_ command: String = "baseline", extra: [String]) async -> CLIResult {
        await CLICommand.run(arguments: [command, "--storage-root", root.path, "--state-root", state.path] + extra)
    }

    // MARK: - Log harvesting

    func testHarvestParsesRealQueueDiagCompletedLines() throws {
        let log = try writeLog([
            "[2026-09-08T10:00:00.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045031 in 0.45s",
            "[2026-09-08T10:00:01.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 1 COMPLETED frame 51045032 in 1.20s",
            "[2026-09-08T10:00:02.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1133 - [Queue-DIAG] Worker 1 dequeued frame 51045033 for processing",
        ])
        let metrics = try BaselineLogHarvester.harvest(url: log)
        XCTAssertEqual(metrics.ocrCompletedCount, 2)
        XCTAssertEqual(metrics.ocrDurationSamplesMs, [450, 1200])
        XCTAssertEqual(metrics.malformedMetricLines, 0)
    }

    func testHarvestParsesRealDeduplicationAnalysisLines() throws {
        let log = try writeLog([
            "[2026-09-08T10:00:00.000Z] [INFO] [Capture] CaptureManager.swift:889 - Deduplication analysis (trigger: interval, similarity: 98.75%, threshold: 97.00%, keepBySimilarity: false, keepByMouseMovement: false, outcome: deduplicated)",
            "[2026-09-08T10:00:02.000Z] [INFO] [Capture] CaptureManager.swift:889 - Deduplication analysis (trigger: mouse_click, similarity: 42.10%, threshold: 97.00%, keepBySimilarity: true, keepByMouseMovement: false, outcome: kept)",
            "[2026-09-08T10:00:04.000Z] [INFO] [Capture] CaptureManager.swift:943 - Deduplication analysis (trigger: interval, similarity: n/a, threshold: disabled, keepBySimilarity: n/a, keepByMouseMovement: false, outcome: kept)",
        ])
        let metrics = try BaselineLogHarvester.harvest(url: log)
        XCTAssertEqual(metrics.dedupKeptCount, 2)
        XCTAssertEqual(metrics.dedupDroppedCount, 1)
        XCTAssertEqual(metrics.similaritySamplesPercent, [98.75, 42.10])
        XCTAssertEqual(metrics.malformedMetricLines, 0)
    }

    func testHarvestParsesRealPerfSummaryAndSlowSampleLines() throws {
        let log = try writeLog([
            "[2026-09-08T10:00:10.000Z] [INFO] [App] Logging.swift:266 - [PERF] timeline.open.first-frame n=10 total=40 latest=180.2ms p50=150.1ms p95=300.9ms min=90.0ms max=310.5ms",
            "[2026-09-08T10:00:11.000Z] [⚠️ WARN] [UI] Logging.swift:257 - [PERF] dashboard.query.storage_single_day_ms slow sample: 269.8ms (warning >= 250.0ms)",
        ])
        let metrics = try BaselineLogHarvester.harvest(url: log)
        XCTAssertEqual(metrics.latencySummaries.count, 1)
        let summary = try XCTUnwrap(metrics.latencySummaries["timeline.open.first-frame"])
        XCTAssertEqual(summary.sampleCount, 10)
        XCTAssertEqual(summary.totalCount, 40)
        XCTAssertEqual(summary.p50Ms, 150.1)
        XCTAssertEqual(summary.p95Ms, 300.9)
        XCTAssertEqual(summary.maxMs, 310.5)
        XCTAssertEqual(metrics.slowSampleCounts["dashboard.query.storage_single_day_ms"], 1)
        XCTAssertEqual(metrics.malformedMetricLines, 0)
    }

    func testHarvestHistogramBucketEdges() throws {
        // percentageLogDescription (CaptureManager.swift:1045) formats %.2f%% of a 0...1 similarity.
        let lines = ["0.00%", "5.99%", "9.99%", "10.00%", "87.43%", "99.99%", "100.00%"]
            .map { similarity in
                "[2026-09-08T10:00:00.000Z] [INFO] [Capture] CaptureManager.swift:889 - Deduplication analysis (trigger: interval, similarity: \(similarity), threshold: 97.00%, keepBySimilarity: false, keepByMouseMovement: false, outcome: deduplicated)"
            }
        let metrics = try BaselineLogHarvester.harvest(url: try writeLog(lines))
        XCTAssertEqual(metrics.similarityHistogram, [
            "0-9%": 3, "10-19%": 1, "80-89%": 1, "90-100%": 2,
        ])
    }

    func testHarvestCountsMalformedMetricLinesAndSkipsThem() throws {
        let log = try writeLog([
            "[2026-09-08T10:00:00.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045031 in 0.45s",
            "[2026-09-08T10:00:01.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame x in notanumber",
            "[2026-09-08T10:00:02.000Z] [INFO] [Capture] CaptureManager.swift:889 - Deduplication analysis (trigger: interval, similarity: maybe%, threshold: 97.00%, keepBySimilarity: false, keepByMouseMovement: false, outcome: teleported)",
            "[2026-09-08T10:00:03.000Z] [INFO] [App] Logging.swift:266 - [PERF] timeline.open.first-frame n=10 total=40",
            "[2026-09-08T10:00:04.000Z] [INFO] [App] AppCoordinator.swift:1 - some unrelated line",
            "[2026-09-08T10:00:05.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1187 - [Queue-DIAG] Worker 0 error: fakeError)",
        ])
        let metrics = try BaselineLogHarvester.harvest(url: log)
        XCTAssertEqual(metrics.ocrCompletedCount, 1)
        XCTAssertEqual(metrics.malformedMetricLines, 3)
    }

    func testHarvestEmptyLogYieldsZeroCountsAndNullPercentiles() throws {
        let metrics = try BaselineLogHarvester.harvest(url: try writeLog([]))
        XCTAssertEqual(metrics.ocrCompletedCount, 0)
        XCTAssertEqual(metrics.dedupKeptCount, 0)
        XCTAssertEqual(metrics.dedupDroppedCount, 0)
        XCTAssertTrue(metrics.similarityHistogram.isEmpty)
        XCTAssertEqual(metrics.malformedMetricLines, 0)
        XCTAssertNil(BaselineLogHarvester.percentile(metrics.ocrDurationSamplesMs, p: 0.5))
    }

    func testPercentileMatchesLatencyRecorderNearestRankSemantics() {
        // Shared/Logging.swift:373: index = Int(round(p * Double(sorted.count - 1)))
        let samples = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]
        XCTAssertEqual(BaselineLogHarvester.percentile(samples, p: 0.5), 40.0)
        XCTAssertEqual(BaselineLogHarvester.percentile(samples, p: 0.95), 70.0)
        XCTAssertEqual(BaselineLogHarvester.percentile([250.0], p: 0.95), 250.0)
    }

    // MARK: - CLI offline harvest

    func testHarvestLogCommandEmitsObservationalReport() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try writeLog([
            "[2026-09-08T10:00:00.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045031 in 0.45s",
            "[2026-09-08T10:00:01.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 1 COMPLETED frame 51045032 in 0.55s",
            "[2026-09-08T10:00:02.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045033 in 1.00s",
            "[2026-09-08T10:00:03.000Z] [INFO] [Capture] CaptureManager.swift:889 - Deduplication analysis (trigger: interval, similarity: 98.75%, threshold: 97.00%, keepBySimilarity: false, keepByMouseMovement: false, outcome: deduplicated)",
        ], name: "offline.log")
        let result = await run(extra: ["--harvest-log", log.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try json(result)
        XCTAssertEqual(report["command"] as? String, "baseline")
        XCTAssertEqual(report["status"] as? String, "complete")
        // Offline mode never invented a sampling window.
        XCTAssertTrue(report["sampledSeconds"] is NSNull)
        XCTAssertEqual(report["ocrCompletedCount"] as? Int, 3)
        let dedup = try XCTUnwrap(report["dedupKeptVsDropped"] as? [String: Any])
        XCTAssertEqual(dedup["kept"] as? Int, 0)
        XCTAssertEqual(dedup["dropped"] as? Int, 1)
        XCTAssertEqual(report["ocrDurationP50Ms"] as? Double, 550)
        XCTAssertEqual(report["ocrDurationP95Ms"] as? Double, 1000)
        XCTAssertNil(report["cpuP50Percent"] as? Double)
        XCTAssertTrue(report["storageGrowthBytes"] is NSNull)
        XCTAssertEqual(report["malformedMetricLines"] as? Int, 0)
        XCTAssertEqual((report["note"] as? String)?.contains("observational"), true)
        // Offline harvest reads only the supplied log; no source database is required.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("retrace.db").path))
    }

    func testHarvestLogDefaultsToStandardRetraceLogWhenValueOmitted() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await run(extra: ["--harvest-log"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try json(result)["command"] as? String, "baseline")
    }

    func testBaselineRejectsConflictingOrInvalidSessionArguments() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Argument-shape errors exit 2 with code "usage".
        for extra in [["--session", "5", "--harvest-log"],
                      ["--session", "0"],
                      ["--session", "-5"],
                      ["--session", "abc"],
                      ["--session"],
                      ["--session", "3601"]] {
            let result = await run(extra: extra)
            XCTAssertNotEqual(result.exitCode, 0, "expected failure for \(extra)")
            XCTAssertEqual(result.exitCode, 2)
            XCTAssertEqual((try json(result)["error"] as? [String: Any])?["code"] as? String, "usage")
        }
        // URI-style log paths are rejected like every other CLI path argument.
        let uri = await run(extra: ["--harvest-log", "file:///tmp/fixture.log"])
        XCTAssertEqual(uri.exitCode, 2)
        XCTAssertEqual((try json(uri)["error"] as? [String: Any])?["code"] as? String, "invalid_path")
    }

    func testHarvestLogExplicitMissingPathFailsHonestly() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await run(extra: ["--harvest-log", sandbox.appendingPathComponent("absent.log").path])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual((try json(result)["error"] as? [String: Any])?["code"] as? String, "log_unreadable")
    }

    // MARK: - Session mode (self-sampling only)

    func testSessionRunSamplesSelfProcessAndDeltasInventory() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks/202609/08"), withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("chunks/202609/08/1")
        try Data("existing".utf8).write(to: existing)
        let log = try writeLog([
            "[2026-09-08T10:00:00.000Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045031 in 0.45s",
        ], name: "session.log")
        // Grow storage mid-session like a recording app would.
        let grower = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            let grown = self.root.appendingPathComponent("chunks/202609/08/2")
            try Data(repeating: 7, count: 4096).write(to: grown)
        }
        defer { grower.cancel() }
        let report = try await BaselineSampler.runSession(
            seconds: 1, storageRoot: root, logURL: log,
            target: .pid(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(report.ocrCompletedCount, 1)
        XCTAssertEqual(report.storageGrowthBytes, 4096)
        XCTAssertNotNil(report.cpuP50Percent)
        XCTAssertNotNil(report.memFootprintMaxBytes)
        XCTAssertGreaterThan(report.memFootprintMaxBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(report.processSampleCount, 2)
        XCTAssertEqual(report.sampledSeconds, 1)
        _ = try await grower.value
    }

    func testProcessSamplerSelfSampleReportsFootprintAndCPU() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try XCTUnwrap(BaselineSampler.sampleProcess(pid: pid))
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try XCTUnwrap(BaselineSampler.sampleProcess(pid: pid))
        XCTAssertGreaterThan(second.physFootprintBytes, 0)
        XCTAssertGreaterThanOrEqual(second.totalCPUSeconds, first.totalCPUSeconds)
    }
}
