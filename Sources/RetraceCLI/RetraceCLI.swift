import Foundation

@main
enum RetraceCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Closed pipes must throw, allowing export outcome handling and an explicit
        // output-failure exit instead of signal termination after a key is created.
        signal(SIGPIPE, SIG_IGN)
        let result = await CLICommand.run(arguments: arguments) { line in
            try FileHandle.standardOutput.write(contentsOf: line)
        }
        // The selected factory and wrapper have no logging side effects. Avoid the app's
        // logging pool/manager: Log writes both stdout and app log files even in release.
        do {
            // A newly persisted key's only recovery phrase is on stderr. Deliver it
            // before stdout, which may be a closed pipeline or another failing sink.
            if !result.stderr.isEmpty { try FileHandle.standardError.write(contentsOf: Data(result.stderr.utf8)) }
            if !result.stdout.isEmpty { try FileHandle.standardOutput.write(contentsOf: result.stdout) }
        } catch { exit(5) }
        exit(result.exitCode)
    }
}
