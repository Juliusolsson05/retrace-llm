import Foundation

/// Uniform CLI/SDK failure: machine-readable code, human diagnostic that never embeds
/// user paths or key material, exit code for the executable face, and optional gate
/// codes for sync's fail-closed preflight. Lives in RetraceKit so both the CLI and any
/// SDK consumer share one error contract.
public struct CLIError: Error, Encodable, Sendable {
    public let code: String
    public let message: String
    public let exitCode: Int32
    public let missingGates: [String]?

    public init(_ code: String, _ message: String, exitCode: Int32 = 3, missingGates: [String]? = nil) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.missingGates = missingGates
    }
}
