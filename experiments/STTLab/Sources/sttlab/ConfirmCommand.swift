import ArgumentParser
import Foundation
import STTLabCore
import STTLabHome

struct ConfirmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm",
        abstract: "Confirm the meeting selection (assigns IDs and locks it)"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "confirm")
        try Confirm.run(workspace: ws, log: log)
    }
}
