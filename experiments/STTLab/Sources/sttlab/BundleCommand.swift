import ArgumentParser
import Foundation
import STTLabHome

struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Build the runner bundle (merged WAV + metadata) from confirmed meetings"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Flag(name: .long, help: "Rebuild meetings that already have output")
    var force: Bool = false

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "bundle")
        try await BundleBuilder.build(workspace: ws, force: force, log: log)
    }
}
