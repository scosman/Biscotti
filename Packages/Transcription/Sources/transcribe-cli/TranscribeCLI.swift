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

        Provide at least one audio path (--mic, --system, or --merged).
        """
    )

    @Option(name: .long, help: "Path to the mic audio file.")
    var mic: String?

    @Option(name: .long, help: "Path to the system audio file.")
    var system: String?

    @Option(name: .long, help: "Path to a pre-merged audio file.")
    var merged: String?

    @Option(name: .long, help: "WhisperKit model variant (default: RAM-aware selection).")
    var model: String?

    @Option(name: .long, help: "Comma-separated custom vocabulary terms.")
    var vocab: String?

    @Flag(name: .long, help: "Output TranscriptResult as JSON to stdout.")
    var json: Bool = false

    func validate() throws {
        guard mic != nil || system != nil || merged != nil else {
            throw ValidationError(
                "At least one audio path (--mic, --system, or --merged) is required."
            )
        }
    }

    func run() async throws {
        let writer = StandardOutputWriter()

        let vocabTerms = parseVocab(vocab)
        let config = buildConfig(model: model)

        // Pre-flight: verify all provided audio paths exist before doing any work.
        try validateAudioPaths(writer: writer)

        writer.writeStderr("transcribe-cli")
        writer.writeStderr("==============")
        printInputSummary(config: config, vocabTerms: vocabTerms, writer: writer)

        let transcriber = Transcriber(backend: .inProcess, config: config)

        writer.writeStderr("Downloading models (if needed)...")
        try await transcriber.ensureModelsDownloaded { progress in
            writer.writeStderrInline(
                String(format: "\rDownload progress: %.0f%%", progress * 100)
            )
        }
        writer.writeStderr("") // newline after progress

        writer.writeStderr("Processing audio...")
        let result = try await transcriber.processAudio(
            mic: mic.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            system: system.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            merged: merged.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            customVocabulary: vocabTerms
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

    /// Fail fast if any provided audio path does not exist on disk.
    func validateAudioPaths(writer: some OutputWriter) throws {
        let paths: [(label: String, path: String?)] = [
            ("--mic", mic),
            ("--system", system),
            ("--merged", merged)
        ]

        for (label, raw) in paths {
            guard let raw else { continue }
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                writer.writeStderr("Error: file not found for \(label): \(raw)")
                throw ExitCode.failure
            }
        }
    }

    private func printInputSummary(
        config: ProcessorConfig, vocabTerms: [String], writer: some OutputWriter
    ) {
        if let mic { writer.writeStderr("Mic:        \(mic)") }
        if let system { writer.writeStderr("System:     \(system)") }
        if let merged { writer.writeStderr("Merged:     \(merged)") }
        writer.writeStderr("Model:      \(config.sttModel)")
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

/// Build a `ProcessorConfig` from the optional `--model` flag.
/// When no model is specified, uses the RAM-aware default.
func buildConfig(model: String?) -> ProcessorConfig {
    if let model {
        ProcessorConfig(sttModel: model)
    } else {
        .ramAware()
    }
}
