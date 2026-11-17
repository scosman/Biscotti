import ArgumentParser
import Foundation
import STTLabCore

/// Shared option for the workspace path, used by all subcommands.
struct WorkspaceOption: ParsableArguments {
    @Option(name: .long, help: "Workspace directory (default: ~/STTLabData/default)")
    var workspace: String = defaultWorkspacePath

    var workspaceURL: URL {
        URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath)
    }

    /// Open a RunLog for the given command name in the workspace.
    func openLog(command: String) -> RunLog {
        let logsDir = workspaceURL.appendingPathComponent("home/logs")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let logURL = logsDir.appendingPathComponent("\(command)-\(timestamp).log")
        return RunLog(logURL: logURL, echoToStdout: true)
    }

    private static var defaultWorkspacePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/STTLabData/default"
    }
}
