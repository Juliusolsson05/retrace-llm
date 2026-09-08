import Foundation

@main
enum RetraceCLI {
    static func main() async {
        let result = await CLICommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
        // The selected factory and wrapper have no logging side effects. Avoid the app's
        // logging pool/manager: Log writes both stdout and app log files even in release.
        do {
            try FileHandle.standardOutput.write(contentsOf: result.stdout)
            if !result.stderr.isEmpty { try FileHandle.standardError.write(contentsOf: Data(result.stderr.utf8)) }
        } catch { exit(5) }
        exit(result.exitCode)
    }
}
