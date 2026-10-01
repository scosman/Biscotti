import ArgumentParser
import DataStore
import Foundation
import Transcription
import VoiceprintMatching

struct BackfillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill",
        abstract: "Create voiceprints from existing meetings by re-running speaker detection."
    )

    @Option(name: .long, help: "Path to the directory that contains Biscotti.store.")
    var store: String?

    @Flag(name: .long, help: "List what would be processed without running speaker detection.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Process at most N meetings.")
    var limit: Int?

    @Option(name: .long, help: "Process only this meeting (UUID).")
    var meeting: String?

    @Flag(name: .long, help: "Output results as JSON to stdout.")
    var json: Bool = false

    func run() async throws {
        let writer = StandardOutputWriter()

        try await MainActor.run { try AppRunningGuard.check(storePath: store, writer: writer) }

        let dataStore = try StoreLocation.open(path: store, writer: writer)
        let spaces = BackfillRunner.currentSpaces()

        writer.writeStderr("Embedding spaces:")
        for (kind, space) in spaces.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            writer.writeStderr("  \(kind.rawValue): \(space)")
        }

        let runner = BackfillRunner(
            dataStore: dataStore, spaces: spaces, writer: writer
        )
        var workItems = try await runner.planWork(meetingFilter: meeting)

        if let limit, workItems.items.count > limit {
            workItems.items = Array(workItems.items.prefix(limit))
        }

        runner.printPlan(workItems)

        if dryRun {
            writer.writeStderr("")
            writer.writeStderr("Dry run complete. No changes made.")
            if json {
                try writeJSON(
                    DryRunSummary(planned: workItems.items.count, skipped: workItems.skipReasons.count),
                    writer: writer
                )
            }
            return
        }

        guard !workItems.items.isEmpty else {
            writer.writeStderr("Nothing to process.")
            return
        }

        let summary = try await runner.execute(
            workItems.items, skippedCount: workItems.skipReasons.count
        )

        if json { try writeJSON(summary, writer: writer) }
        if summary.failed > 0 { throw ExitCode.failure }
    }
}

// MARK: - BackfillRunner

private struct WorkPlan {
    var items: [WorkItem]
    let skipReasons: [String]
    let totalCandidates: Int
}

private struct WorkItem {
    let candidate: BackfillCandidateData
    let neededKinds: [VoiceprintKind]
}

private struct BackfillRunner {
    let dataStore: DataStore
    let spaces: [VoiceprintKind: String]
    let writer: StandardOutputWriter

    static func currentSpaces() -> [VoiceprintKind: String] {
        [
            .raw: SpeakerEmbeddingSpace.current(.raw),
            .plda: SpeakerEmbeddingSpace.current(.plda)
        ]
    }

    func planWork(meetingFilter: String?) async throws -> WorkPlan {
        var candidates = try await dataStore.backfillCandidates()

        if let meetingIDStr = meetingFilter {
            guard let meetingID = UUID(uuidString: meetingIDStr) else {
                writer.writeStderr("Error: invalid UUID: \(meetingIDStr)")
                throw ExitCode.failure
            }
            candidates = candidates.filter { $0.meetingID == meetingID }
            if candidates.isEmpty {
                writer.writeStderr("No candidate found for meeting \(meetingIDStr)")
                throw ExitCode.failure
            }
        }

        var items: [WorkItem] = []
        var skipReasons: [String] = []

        for candidate in candidates {
            if let reason = try await skipReason(for: candidate) {
                skipReasons.append(reason)
            } else {
                let needed = try await neededKinds(for: candidate)
                if needed.isEmpty {
                    skipReasons.append(
                        "\(candidate.title) (\(candidate.meetingID)): already has voiceprints"
                    )
                } else {
                    items.append(WorkItem(candidate: candidate, neededKinds: needed))
                }
            }
        }

        return WorkPlan(items: items, skipReasons: skipReasons, totalCandidates: candidates.count)
    }

    func printPlan(_ plan: WorkPlan) {
        writer.writeStderr("")
        writer.writeStderr("Candidates: \(plan.totalCandidates) meetings with preferred transcripts")
        writer.writeStderr("To process: \(plan.items.count)")
        writer.writeStderr("Skipped: \(plan.skipReasons.count)")

        if !plan.skipReasons.isEmpty {
            writer.writeStderr("")
            for reason in plan.skipReasons {
                writer.writeStderr("  skip: \(reason)")
            }
        }

        if !plan.items.isEmpty {
            writer.writeStderr("")
            for item in plan.items {
                let kinds = item.neededKinds.map(\.rawValue).joined(separator: ", ")
                writer.writeStderr("  plan: \(item.candidate.title) — needs \(kinds)")
            }
        }
    }

    func execute(_ items: [WorkItem], skippedCount: Int) async throws -> BackfillSummary {
        let analyzer = SpeakerAnalyzer()
        writer.writeStderr("")
        writer.writeStderr("Downloading SpeakerKit models (if needed)...")
        try await analyzer.ensureModelsDownloaded()

        var processed = 0
        var failed = 0
        var voiceprintsAdded: [VoiceprintKind: Int] = [.raw: 0, .plda: 0]
        var totalUnmapped = 0

        for (idx, item) in items.enumerated() {
            writer.writeStderr("")
            writer.writeStderr(
                "[\(idx + 1)/\(items.count)] \(item.candidate.title) (\(formatDate(item.candidate.date)))"
            )

            do {
                let result = try await processOne(item, analyzer: analyzer)
                processed += 1
                totalUnmapped += result.unmapped
                for (kind, count) in result.added {
                    voiceprintsAdded[kind, default: 0] += count
                }
            } catch {
                writer.writeStderr("  Error: \(error.localizedDescription)")
                failed += 1
            }
        }

        await analyzer.unload()

        writer.writeStderr("")
        writer.writeStderr("=== Summary ===")
        writer.writeStderr("Processed: \(processed)")
        writer.writeStderr("Failed: \(failed)")
        writer.writeStderr("Skipped: \(skippedCount)")
        for (kind, count) in voiceprintsAdded.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            writer.writeStderr("Voiceprints added (\(kind.rawValue)): \(count)")
        }
        if totalUnmapped > 0 {
            writer.writeStderr("Unmapped speakers: \(totalUnmapped)")
        }

        return BackfillSummary(
            processed: processed, failed: failed,
            skipped: skippedCount,
            voiceprintsRaw: voiceprintsAdded[.raw, default: 0],
            voiceprintsPlda: voiceprintsAdded[.plda, default: 0],
            unmappedSpeakers: totalUnmapped
        )
    }

    // MARK: - Helpers

    private func skipReason(for candidate: BackfillCandidateData) async throws -> String? {
        if candidate.micURL == nil || candidate.systemURL == nil {
            return "\(candidate.title) (\(candidate.meetingID)): missing audio files"
        }
        if candidate.segments.isEmpty {
            return "\(candidate.title) (\(candidate.meetingID)): no stored segments"
        }
        return nil
    }

    private func neededKinds(for candidate: BackfillCandidateData) async throws -> [VoiceprintKind] {
        var result: [VoiceprintKind] = []
        for (kind, space) in spaces {
            let has = try await dataStore.hasVoiceprints(
                transcriptID: candidate.transcriptID, kind: kind, space: space
            )
            if !has { result.append(kind) }
        }
        return result
    }

    private struct OneResult {
        let added: [VoiceprintKind: Int]
        let unmapped: Int
    }

    private func processOne(
        _ item: WorkItem, analyzer: SpeakerAnalyzer
    ) async throws -> OneResult {
        let candidate = item.candidate
        guard let micPath = candidate.micURL?.path,
              let systemPath = candidate.systemURL?.path
        else {
            throw BackfillError.missingAudioPath
        }

        let analysis = try await analyzer.analyze(micPath: micPath, systemPath: systemPath)

        let freshSpans = analysis.spans.map {
            SpeakerSpan(speakerID: $0.speakerID, start: $0.start, end: $0.end)
        }
        let storedSpans = candidate.segments.map {
            SpeakerSpan(speakerID: $0.speakerID, start: $0.start, end: $0.end)
        }
        let mapping = BackfillSpeakerMapper.map(fresh: freshSpans, stored: storedSpans)

        if !mapping.unmapped.isEmpty {
            writer.writeStderr(
                "  Warning: \(mapping.unmapped.count) fresh speakers could not be mapped"
            )
        }

        var added: [VoiceprintKind: Int] = [:]
        for kind in item.neededKinds {
            let count = try await writeVoiceprints(
                kind: kind, candidate: candidate, analysis: analysis, mapping: mapping
            )
            added[kind] = count
        }

        return OneResult(added: added, unmapped: mapping.unmapped.count)
    }

    private func writeVoiceprints(
        kind: VoiceprintKind, candidate: BackfillCandidateData,
        analysis: SpeakerAnalysis, mapping: BackfillSpeakerMapper.Result
    ) async throws -> Int {
        let embeddingKind: EmbeddingKind = kind == .raw ? .raw : .plda
        guard let embeddingSet = analysis.embeddingSets.first(
            where: { $0.kind == embeddingKind }
        ) else {
            writer.writeStderr("  No \(kind.rawValue) embeddings from diarization")
            return 0
        }

        var items: [NewVoiceprint] = []
        for (freshID, storedID) in mapping.mapping {
            guard let vector = embeddingSet.vectors[freshID], !vector.isEmpty else { continue }
            let duration = analysis.speakerSpeechDurations[freshID] ?? 0
            items.append(NewVoiceprint(speakerID: storedID, vector: vector, speakingDuration: duration))
        }

        // Use the space from the actual diarization output, not pre-computed.
        try await dataStore.addVoiceprints(
            items, kind: kind, space: embeddingSet.space, to: candidate.transcriptID
        )
        writer.writeStderr("  Added \(items.count) \(kind.rawValue) voiceprints")
        return items.count
    }
}

// MARK: - Types

private enum BackfillError: LocalizedError {
    case missingAudioPath

    var errorDescription: String? {
        switch self {
        case .missingAudioPath: "Audio file path is nil"
        }
    }
}

private struct DryRunSummary: Codable {
    let planned: Int
    let skipped: Int
}

private struct BackfillSummary: Codable {
    let processed: Int
    let failed: Int
    let skipped: Int
    let voiceprintsRaw: Int
    let voiceprintsPlda: Int
    let unmappedSpeakers: Int
}

// MARK: - Helpers

private func writeJSON(_ value: some Encodable, writer: StandardOutputWriter) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw ExitCode.failure
    }
    writer.writeStdout(text)
}

private let dateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .none
    return fmt
}()

private func formatDate(_ date: Date) -> String {
    dateFormatter.string(from: date)
}
