import ArgumentParser
import Foundation
import Transcription

@main
struct TranscribeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe audio files with WhisperKit STT + SpeakerKit diarization.",
        discussion: """
        Runs the in-process transcription engine (no XPC). Models are downloaded
        automatically on first run (~3 GB for STT, ~33 MB for diarization).
        First-run CoreML compilation may take 15-90 seconds.

        Both --mic and --system paths are required.
        """
    )

    @Option(name: .long, help: "Path to the mic audio file.")
    var mic: String

    @Option(name: .long, help: "Path to the system audio file.")
    var system: String

    @Option(name: .long, help: "Comma-separated custom vocabulary terms.")
    var vocab: String?

    @Option(name: .long, help: "STT engine: whisper (default) or apple.")
    var engine: String?

    @Option(name: .long, help: "Locale for Apple Speech (e.g. en_US). Required when --engine apple.")
    var locale: String?

    @Flag(name: .long, help: "Output TranscriptResult as JSON to stdout.")
    var json: Bool = false

    func run() async throws {
        let writer = StandardOutputWriter()

        let vocabTerms = parseVocab(vocab)
        let config = try buildConfig(writer: writer)

        // Pre-flight: verify all provided audio paths exist before doing any work.
        try validateAudioPaths(writer: writer)

        writer.writeStderr("transcribe-cli")
        writer.writeStderr("==============")
        printInputSummary(vocabTerms: vocabTerms, config: config, writer: writer)

        let transcriber = Transcriber(backend: .inProcess)

        // Download the components the engine needs.
        let components: Set<ModelComponent> = switch config.engine {
        case .whisper: .all
        case .apple: [.speakerID]
        }

        writer.writeStderr("Downloading models (if needed)...")
        try await transcriber.ensureModelsDownloaded(components) { status in
            writer.writeStderr(status)
        }

        writer.writeStderr("Processing audio...")
        let micURL = URL(fileURLWithPath: (mic as NSString).expandingTildeInPath)
        let systemURL = URL(fileURLWithPath: (system as NSString).expandingTildeInPath)
        let result = try await transcriber.processAudio(
            mic: micURL,
            system: systemURL,
            customVocabulary: vocabTerms,
            config: config
        )

        writer.writeStderr("Done. Elapsed: \(String(format: "%.1f", result.processingDuration))s")

        if json {
            let jsonString = try formatResultJSON(result)
            writer.writeStdout(jsonString)
        } else {
            let text = formatResultText(result)
            writer.writeStdout(text)
        }
    }

    /// Build a `TranscriptionConfig` from the CLI options.
    func buildConfig(writer: some OutputWriter) throws -> TranscriptionConfig {
        guard let engineStr = engine else {
            return .whisper()
        }
        switch engineStr.lowercased() {
        case "whisper":
            return .whisper()
        case "apple":
            guard let loc = locale else {
                writer.writeStderr("Error: --locale is required when --engine apple")
                throw ExitCode.failure
            }
            return .apple(locale: loc)
        default:
            writer.writeStderr("Error: unknown engine '\(engineStr)'. Use 'whisper' or 'apple'.")
            throw ExitCode.failure
        }
    }

    /// Fail fast if any provided audio path does not exist on disk.
    func validateAudioPaths(writer: some OutputWriter) throws {
        let paths: [(label: String, path: String)] = [
            ("--mic", mic),
            ("--system", system)
        ]

        for (label, raw) in paths {
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                writer.writeStderr("Error: file not found for \(label): \(raw)")
                throw ExitCode.failure
            }
        }
    }

    private func printInputSummary(
        vocabTerms: [String],
        config: TranscriptionConfig,
        writer: some OutputWriter
    ) {
        writer.writeStderr("Mic:        \(mic)")
        writer.writeStderr("System:     \(system)")
        writer.writeStderr("Engine:     \(config.engine.rawValue)")
        writer.writeStderr("Method:     \(config.method.id)")
        if let loc = config.locale {
            writer.writeStderr("Locale:     \(loc)")
        }
        if !vocabTerms.isEmpty {
            writer.writeStderr("Vocabulary: \(vocabTerms.joined(separator: ", "))")
        }
        writer.writeStderr("")
    }
}

// MARK: - Argument processing helpers

/// Parse the `--vocab` flag value into an array of trimmed terms.
func parseVocab(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
}
