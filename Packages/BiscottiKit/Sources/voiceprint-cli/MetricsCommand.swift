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

    @Flag(name: .long, help: "Show the full radius sweep table.")
    var sweep: Bool = false

    @Flag(name: .long, help: "Output results as JSON to stdout.")
    var json: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Comma-separated names or emails that are the same human. Repeatable.",
            discussion: "Example: --same-person \"Steve,steve@kiln.tech,scosman@gmail.com\""
        )
    )
    var samePerson: [String] = []

    func run() async throws {
        let writer = StandardOutputWriter()

        try await MainActor.run { try AppRunningGuard.check(storePath: store, writer: writer) }

        let dataStore = try StoreLocation.open(path: store, writer: writer)

        let space = SpeakerEmbeddingSpace.current()
        writer.writeStderr("Loading raw corpus (space: \(space))...")

        let loaded = try await dataStore.voiceprintCorpus(
            kind: .raw, space: space, excludingMeetingID: nil
        )
        let corpus = try mergeAliases(loaded, writer: writer)

        writer.writeStderr(
            "  \(corpus.entries.count) voiceprints, "
                + "\(Set(corpus.entries.map(\.meetingID)).count) meetings, "
                + "\(corpus.people.count) people"
        )

        let evaluator = VoiceprintEvaluator()
        writer.writeStderr("Evaluating...")
        let metrics = evaluator.evaluate(corpus)

        // Output
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metrics)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ExitCode.failure
            }
            writer.writeStdout(text)
        } else {
            let text = MetricsFormatter.text(metrics, includeSweep: sweep)
            writer.writeStdout(text)
        }
    }

    /// Applies `--same-person` groups. Fails when a term matches no person.
    private func mergeAliases(
        _ corpus: VoiceprintCorpusData, writer: StandardOutputWriter
    ) throws -> VoiceprintCorpusData {
        guard !samePerson.isEmpty else { return corpus }
        let groups = samePerson.map { $0.split(separator: ",").map(String.init) }
        let resolved = PersonAliases.resolve(groups, people: corpus.people)
        guard resolved.unmatched.isEmpty else {
            throw ValidationError(
                "--same-person: no person matches: \(resolved.unmatched.joined(separator: ", "))"
            )
        }
        for group in resolved.groups {
            let names = group.map { corpus.people[$0]?.name ?? $0.uuidString }
            writer.writeStderr("  Same person: \(names.joined(separator: ", "))")
        }
        return corpus.mergingPeople(resolved.groups)
    }
}
