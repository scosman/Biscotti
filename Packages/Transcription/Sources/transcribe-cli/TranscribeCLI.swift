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

    @Flag(name: .long, help: "Output TranscriptResult as JSON to stdout.")
    var json: Bool = false

    @Option(
        name: .long,
        help: "Override cluster-distance threshold for diarization (default: SDK default)."
    )
    var diarizationThreshold: Float?

    @Option(
        name: .long,
        help: "Diagnostic: comma-separated thresholds to sweep. Prints speaker counts per threshold to stderr."
    )
    var diarizationSweep: String?

    func validate() throws {
        if diarizationThreshold != nil, diarizationSweep != nil {
            throw ValidationError(
                "--diarization-threshold and --diarization-sweep are mutually exclusive"
            )
        }
    }

    func run() async throws {
        let writer = StandardOutputWriter()

        let vocabTerms = parseVocab(vocab)

        // Pre-flight: verify all provided audio paths exist before doing any work.
        try validateAudioPaths(writer: writer)

        writer.writeStderr("transcribe-cli")
        writer.writeStderr("==============")
        printInputSummary(vocabTerms: vocabTerms, writer: writer)

        let transcriber = Transcriber(backend: .inProcess)

        writer.writeStderr("Downloading models (if needed)...")
        try await transcriber.ensureModelsDownloaded { status in
            writer.writeStderr(status)
        }

        let micURL = URL(fileURLWithPath: (mic as NSString).expandingTildeInPath)
        let systemURL = URL(fileURLWithPath: (system as NSString).expandingTildeInPath)

        if let sweepCSV = diarizationSweep {
            try await runSweep(
                sweepCSV: sweepCSV, transcriber: transcriber,
                mic: micURL, system: systemURL, vocabTerms: vocabTerms
            )
            return
        }

        writer.writeStderr("Processing audio...")
        let result = try await transcriber.processAudio(
            mic: micURL, system: systemURL,
            customVocabulary: vocabTerms,
            diarizationClusterThreshold: diarizationThreshold
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

    /// Sweep mode: run the pipeline for each threshold and print speaker counts to stderr.
    private func runSweep(
        sweepCSV: String, transcriber: Transcriber,
        mic: URL, system: URL, vocabTerms: [String]
    ) async throws {
        let writer = StandardOutputWriter()
        let thresholds = parseSweepThresholds(sweepCSV)
        guard !thresholds.isEmpty else {
            writer.writeStderr("Error: --diarization-sweep requires comma-separated float values")
            throw ExitCode.failure
        }
        writer.writeStderr("Sweeping \(thresholds.count) threshold(s)...")
        for threshold in thresholds {
            let result = try await transcriber.processAudio(
                mic: mic, system: system,
                customVocabulary: vocabTerms,
                diarizationClusterThreshold: threshold
            )
            let distinctSpeakers = Set(result.segments.compactMap(\.speakerID)).count
            writer.writeStderr(
                String(
                    format: "%.2f: speakers=%d distinct=%d",
                    threshold, result.speakerCount, distinctSpeakers
                )
            )
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
        vocabTerms: [String], writer: some OutputWriter
    ) {
        writer.writeStderr("Mic:        \(mic)")
        writer.writeStderr("System:     \(system)")
        writer.writeStderr("Method:     \(TranscriptionMethod.current.id)")
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

/// Parse the `--diarization-sweep` CSV value into an array of Float thresholds.
/// Non-numeric entries are silently dropped.
func parseSweepThresholds(_ csv: String) -> [Float] {
    csv.split(separator: ",")
        .compactMap { Float(String($0).trimmingCharacters(in: .whitespaces)) }
}
