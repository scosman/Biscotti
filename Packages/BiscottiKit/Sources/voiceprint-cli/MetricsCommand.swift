import ArgumentParser
import DataStore
import Foundation
import Transcription
import VoiceprintMatching

struct MetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Evaluate voiceprint matching accuracy using leave-one-meeting-out cross-validation."
    )

    @Option(name: .long, help: "Path to the directory that contains Biscotti.store.")
    var store: String?

    @Option(name: .long, help: "Which voiceprint kind to evaluate: plda, raw, or both (default: both).")
    var kind: KindOption = .both

    @Flag(name: .long, help: "Show the full radius sweep table.")
    var sweep: Bool = false

    @Flag(name: .long, help: "Output results as JSON to stdout.")
    var json: Bool = false

    func run() async throws {
        let writer = StandardOutputWriter()

        try await MainActor.run { try AppRunningGuard.check(writer: writer) }

        let dataStore = try StoreLocation.open(path: store, writer: writer)

        let kinds = kind.voiceprintKinds
        var results: [VoiceprintMetrics] = []

        for voiceprintKind in kinds {
            let space = SpeakerEmbeddingSpace.current(
                voiceprintKind == .raw ? .raw : .plda
            )
            writer.writeStderr("Loading \(voiceprintKind.rawValue) corpus (space: \(space))...")

            let corpus = try await dataStore.voiceprintCorpus(
                kind: voiceprintKind, space: space, excludingMeetingID: nil
            )

            writer.writeStderr(
                "  \(corpus.entries.count) voiceprints, "
                    + "\(Set(corpus.entries.map(\.meetingID)).count) meetings, "
                    + "\(corpus.people.count) people"
            )

            let evaluator = VoiceprintEvaluator()
            writer.writeStderr("Evaluating \(voiceprintKind.rawValue)...")
            let metrics = evaluator.evaluate(corpus)
            results.append(metrics)
        }

        // Output
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(results)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ExitCode.failure
            }
            writer.writeStdout(text)
        } else {
            let text = MetricsFormatter.text(results, includeSweep: sweep)
            writer.writeStdout(text)
        }
    }
}

// MARK: - Kind option

enum KindOption: String, ExpressibleByArgument, CaseIterable {
    case plda
    case raw
    case both

    var voiceprintKinds: [VoiceprintKind] {
        switch self {
        case .plda: [.plda]
        case .raw: [.raw]
        case .both: [.plda, .raw]
        }
    }
}
