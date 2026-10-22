import ArgumentParser
import Foundation
import STTLabHome

struct HomeRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "home-run",
        abstract: "Run all home engines in sequence: whisper, then diarize, then reference"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Flag(name: .long, help: "Skip the interactive consent prompt for reference upload")
    var yes: Bool = false

    @Option(name: .long, help: "Reference model ID (default: microsoft/mai-transcribe-2)")
    var model: String = "microsoft/mai-transcribe-2"

    @Option(name: .long, help: "Target chunk length in seconds (default: 300)")
    var chunkSeconds: Double = 300

    @Flag(name: .long, help: "Disable zero-data-retention provider preference")
    var noZdr: Bool = false

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "home-run")
        var anyFailed = false

        // Step 1: Whisper
        log.log("=== Step 1/3: WhisperKit ===")
        let (_, wFailed, _) = try await WhisperRunner.run(workspace: ws, log: log)
        if wFailed > 0 { anyFailed = true }

        // Step 2: Diarization
        log.log("=== Step 2/3: SpeakerKit Diarization ===")
        let (_, dFailed, _) = try await DiarizationRunner.run(workspace: ws, log: log)
        if dFailed > 0 { anyFailed = true }

        // Step 3: Reference
        log.log("=== Step 3/3: Reference (\(model)) ===")
        let config = ReferenceConfig(
            model: model,
            zdr: !noZdr,
            chunkSeconds: chunkSeconds
        )
        let (_, rFailed, _) = try await ReferenceRunner.run(
            workspace: ws, config: config, skipConsent: yes, log: log
        )
        if rFailed > 0 { anyFailed = true }

        if anyFailed {
            throw ExitCode(1)
        }
    }
}
