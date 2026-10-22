import ArgumentParser
import Foundation

@main
struct STTLabCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sttlab",
        abstract: "STT Lab — Apple SpeechTranscriber validation experiment",
        subcommands: [
            SelectCommand.self,
            ConfirmCommand.self,
            BundleCommand.self
            // Later phases add: whisper, diarize, reference, home-run, analyze
        ]
    )
}
