import Foundation

@main
enum RetraceCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Let a closed downstream pipe throw through the writer so export records a
        // failed outcome instead of terminating before metrics/summary handling.
        if arguments.first == "export" { signal(SIGPIPE, SIG_IGN) }
        let result = await CLICommand.run(arguments: arguments) { line in
            try FileHandle.standardOutput.write(contentsOf: line)
        }
        // The selected factory and wrapper have no logging side effects. Avoid the app's
        // logging pool/manager: Log writes both stdout and app log files even in release.
        do {
            if !result.stdout.isEmpty { try FileHandle.standardOutput.write(contentsOf: result.stdout) }
            if !result.stderr.isEmpty { try FileHandle.standardError.write(contentsOf: Data(result.stderr.utf8)) }
        } catch { exit(5) }
        exit(result.exitCode)
    }
}
