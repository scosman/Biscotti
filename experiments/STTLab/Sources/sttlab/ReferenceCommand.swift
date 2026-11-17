import ArgumentParser
import Foundation
import STTLabHome

struct ReferenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reference",
        abstract: "Run the OpenRouter reference model on confirmed meetings"
    )

    @OptionGroup var workspaceOpt: WorkspaceOption

    @Option(name: .long, help: "Process only these meeting IDs (e.g. m01 m03)")
    var meeting: [String] = []

    @Flag(name: .long, help: "Re-run meetings that already have completed output")
    var force: Bool = false

    @Option(name: .long, help: "Reference model ID (default: microsoft/mai-transcribe-2)")
    var model: String = "microsoft/mai-transcribe-2"

    @Option(name: .long, help: "Target chunk length in seconds (default: 300)")
    var chunkSeconds: Double = 300

    @Flag(name: .long, help: "Disable zero-data-retention provider preference")
    var noZdr: Bool = false

    @Flag(name: .long, help: "Probe mode: send 60s of the first meeting and print diagnostics")
    var probe: Bool = false

    @Flag(name: .long, help: "Skip the interactive consent prompt")
    var yes: Bool = false

    @Option(name: .long, help: "Estimated price per audio hour (default: 0.10)")
    var pricePerHour: Double = 0.10

    func run() async throws {
        let ws = workspaceOpt.workspaceURL
        let log = workspaceOpt.openLog(command: "reference")

        let config = ReferenceConfig(
            model: model,
            zdr: !noZdr,
            chunkSeconds: chunkSeconds,
            pricePerHour: pricePerHour
        )

        if probe {
            try await ReferenceRunner.probe(workspace: ws, config: config, log: log)
        } else {
            let (_, failed, _) = try await ReferenceRunner.run(
                workspace: ws, meetingFilter: meeting, force: force,
                config: config, skipConsent: yes, log: log
            )
            if failed > 0 {
                throw ExitCode(1)
            }
        }
    }
}
