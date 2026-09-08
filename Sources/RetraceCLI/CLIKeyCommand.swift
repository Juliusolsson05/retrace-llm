import Foundation
import Shared
import Storage

enum CLIKeyCommand {
    private struct Report: Encodable {
        let schemaVersion = 1
        var command = "key"
        var status = "complete"
        var exitCode: Int32 = 0
        var elapsedMs: Double = 0
        var present: Bool?
        var keyId: String?
        var createdAtMs: Int64?
        var unlocked: Bool?
        var error: CLIError?

        mutating func fail(_ error: CLIError) { self.error = error; status = "failed"; exitCode = error.exitCode }
        mutating func apply(_ value: BackupKeyStore.Status) {
            present = value.present; keyId = value.keyId; createdAtMs = value.createdAtMs
        }
    }

    static func execute(arguments: [String], readPhrase: @Sendable () throws -> String) async -> CLIResult {
        let start = ProcessInfo.processInfo.systemUptime
        var report = Report()
        var metrics: CLIStateMetrics?
        var recoveryOutput = ""
        do {
            guard let action = arguments.first, ["init", "status", "rotate", "unwrap"].contains(action) else { throw CLICommand.usage() }
            let options = try CLICommand.parseOptions(Array(arguments.dropFirst()), keyCommand: action)
            guard action != "unwrap" || options["--phrase-from-stdin"] != nil else { throw CLICommand.usage() }
            let root = try CLICommand.localPath(options["--storage-root"] ?? AppPaths.storageRoot).resolvingSymlinksInPath()
            let state = try CLICommand.localPath(options["--state-root"] ?? "~/Library/Application Support/RetraceCLI")
            report.command = "key \(action)"
            // Validate key aliases before any state writes, including metrics.
            let status = try await BackupKeyStore.status(root: state, sourceRoot: root)
            metrics = try CLIStateMetrics(root: state, sourceRoot: root)
            try metrics?.record(command: report.command, outcome: "started")
            switch action {
            case "init", "rotate":
                let created = try await BackupKeyStore.initialize(root: state, sourceRoot: root, rotate: action == "rotate")
                report.apply(created.status)
                // Only this diagnostic channel carries the phrase. Preserve it even
                // if outcome metrics fail: the durable key must remain recoverable.
                recoveryOutput = "WARNING: Save this recovery phrase privately offline. It is shown ONCE. Losing it prevents backup recovery.\nRecovery phrase:\n\(created.recoveryPhrase)\n"
                if action == "rotate" {
                    recoveryOutput += "Rotation invalidates prior encrypted objects for the active key; their archived wrapped entry requires the old phrase.\n"
                }
            case "unwrap":
                _ = try await unlock(state: state, root: root, fromStdin: true, readPhrase: readPhrase)
                report.apply(status)
                report.unlocked = true
            default: report.apply(status)
            }
        } catch { report.fail(failure(error)) }
        report.elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000)
        if let metrics {
            do {
                try metrics.record(command: report.command, outcome: report.status == "complete" ? "succeeded" : "failed",
                    durationMs: report.elapsedMs, errorCode: report.error?.code)
            } catch { report.fail(CLIError("metrics_unavailable", "Could not persist key command outcome in independent CLI state.", exitCode: 5)) }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return CLIResult(stdout: try encoder.encode(report) + Data([10]),
                stderr: recoveryOutput + (report.error.map { "retrace-cli: \($0.code): \($0.message)\n" } ?? ""), exitCode: report.exitCode)
        } catch {
            return CLIResult(stdout: Data("{\"schemaVersion\":1,\"status\":\"failed\",\"exitCode\":5}\n".utf8),
                stderr: recoveryOutput + "retrace-cli: output_failed: JSON encoding failed.\n", exitCode: 5)
        }
    }

    static func unlock(state: URL, root: URL, fromStdin: Bool, readPhrase: @Sendable () throws -> String) async throws -> ObjectCrypto.Key {
        guard try await BackupKeyStore.status(root: state, sourceRoot: root).present else { throw BackupKeyError.missing }
        guard fromStdin else {
            throw CLIError("phrase_required", "Supply --phrase-from-stdin and pipe the recovery phrase on stdin to unlock the backup key.", exitCode: 2)
        }
        let phrase: String
        do { phrase = try readPhrase() }
        catch { throw BackupKeyError.unlockFailed }
        guard phrase.utf8.count <= 4096 else { throw BackupKeyError.unlockFailed }
        return try await BackupKeyStore.unwrap(root: state, sourceRoot: root, phrase: phrase)
    }

    static func readStdin() throws -> String {
        var data = Data()
        while let next = try FileHandle.standardInput.read(upToCount: 4097 - data.count), !next.isEmpty {
            data.append(next)
            guard data.count <= 4096 else { throw BackupKeyError.unlockFailed }
        }
        guard let phrase = String(data: data, encoding: .utf8) else { throw BackupKeyError.unlockFailed }
        return phrase
    }

    static func failure(_ error: Error) -> CLIError {
        if let cli = error as? CLIError { return cli }
        if error as? SyncManifestError == .unsafeStateRoot {
            return CLIError("unsafe_state_root", "Backup key state must be outside source storage without symlink or hardlink aliases.", exitCode: 2)
        }
        switch error as? BackupKeyError {
        case .missing: return CLIError("backup_key_missing", "No backup key exists; explicitly run retrace-cli key init first.", exitCode: 2)
        case .exists: return CLIError("backup_key_exists", "A backup key already exists; use key status or explicit key rotate.", exitCode: 2)
        case .unlockFailed: return CLIError("backup_key_unlock_failed", "The recovery phrase could not unlock the backup key.", exitCode: 2)
        case .invalidStore: return CLIError("backup_key_invalid", "The wrapped backup key store is invalid or unsupported.")
        default: return CLIError("backup_key_unavailable", "The wrapped backup key store could not be read or persisted.")
        }
    }
}
