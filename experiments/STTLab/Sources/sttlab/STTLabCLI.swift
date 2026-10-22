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
            BundleCommand.self,
            WhisperCommand.self,
            DiarizeCommand.self,
            ReferenceCommand.self,
            HomeRunCommand.self
            // Later phases add: analyze
        ]
    )
}
