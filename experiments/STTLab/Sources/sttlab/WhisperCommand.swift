import ArgumentParser
import Foundation
import STTLabHome

struct WhisperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whisper",
        abstract: "Run WhisperKit transcription on confirmed meetings"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Process only these meeting IDs (e.g. m01 m03)")
    var meeting: [String] = []

    @Flag(name: .long, help: "Re-run meetings that already have completed output")
    var force: Bool = false

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "whisper")
        let (_, failed, _) = try await WhisperRunner.run(
            workspace: ws, meetingFilter: meeting, force: force, log: log
        )
        if failed > 0 {
            throw ExitCode(1)
        }
    }
}
