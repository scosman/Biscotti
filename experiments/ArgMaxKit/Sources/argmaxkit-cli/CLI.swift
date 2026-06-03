import ArgumentParser
import ArgMaxKit
import Foundation

@main
struct ArgMaxCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "argmaxkit-cli",
        abstract: "Process an audio file with WhisperKit STT + SpeakerKit diarization.",
        discussion: """
            Loads the specified WhisperKit model and SpeakerKit Pyannote model,
            transcribes the audio file, runs speaker diarization, and outputs
            the merged transcript with speaker labels.

            Models are downloaded automatically on first run (~3 GB for STT,
            ~33 MB for diarization). First-run CoreML compilation may take
            15-90 seconds.
            """
    )

    @Argument(help: "Path to an audio file (WAV, CAF, M4A, MP3, etc.)")
    var audioFile: String

    @Option(name: .long, help: "WhisperKit model variant (default: large-v3_turbo)")
    var model: String = "large-v3_turbo"

    @Option(name: .long, help: "Comma-separated custom vocabulary terms")
    var vocab: String?

    @Flag(name: .long, help: "Output raw JSON instead of formatted text")
    var json: Bool = false

    @Flag(name: .long, help: "Load STT and diarization models sequentially to reduce peak memory")
    var sequential: Bool = false

    func run() async throws {
        let expandedPath = (audioFile as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("Error: File not found: \(audioFile)")
            throw ExitCode.failure
        }

        let vocabTerms = vocab?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []

        let config = ProcessorConfig(
            sttModel: model,
            sequentialLoading: sequential
        )

        print("ArgMaxKit CLI")
        print("=============")
        print("Audio file: \(fileURL.path)")
        print("STT model:  \(model)")
        if !vocabTerms.isEmpty {
            print("Vocabulary: \(vocabTerms.joined(separator: ", "))")
        }
        print("Sequential: \(sequential)")
        print()

        let processor = ArgMaxProcessor(config: config)

        print("Loading models and processing audio...")
        print("(First run will download models and compile CoreML — this may take several minutes)")
        print()

        let result: TranscriptResult
        do {
            result = try await processor.processAudio(fileURL, customVocabulary: vocabTerms)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        if json {
            printJSON(result)
        } else {
            printFormatted(result)
        }
    }

    private func printJSON(_ result: TranscriptResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(result),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("Error: Failed to encode result as JSON")
            return
        }
        print(jsonString)
    }

    private func printFormatted(_ result: TranscriptResult) {
        print("Transcript Result")
        print("=================")
        print("Model:      \(result.modelVersion)")
        print("Language:   \(result.language)")
        print("Speakers:   \(result.speakerCount)")
        print("Segments:   \(result.segments.count)")
        print("Duration:   \(String(format: "%.1f", result.processingDuration))s processing time")
        print("Created:    \(result.createdAt)")
        print()

        if !result.speakerEmbeddings.isEmpty {
            print("Speaker Embeddings")
            print("------------------")
            for (speakerID, embedding) in result.speakerEmbeddings.sorted(by: { $0.key < $1.key }) {
                print("  Speaker \(speakerID): \(embedding.count)-dim vector")
            }
            print()
        }

        print("Transcript")
        print("----------")
        for segment in result.segments {
            let timeRange = formatTime(segment.startTime) + " -> " + formatTime(segment.endTime)
            print("[\(timeRange)] \(segment.speakerLabel):")
            print("  \(segment.text)")

            if let words = segment.words, !words.isEmpty {
                let wordDetails = words.map { w in
                    "\(w.word)(\(String(format: "%.0f%%", w.probability * 100)))"
                }.joined(separator: " ")
                print("  Words: \(wordDetails)")
            }
            print()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds - Double(Int(seconds))) * 10)
        return String(format: "%02d:%02d.%d", minutes, secs, frac)
    }
}
