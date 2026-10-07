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
        let space = SpeakerEmbeddingSpace.current()

        writer.writeStderr("Embedding space: \(space)")

        let runner = BackfillRunner(
            dataStore: dataStore, space: space, writer: writer
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
}

private struct BackfillRunner {
    let dataStore: DataStore
    let space: String
    let writer: StandardOutputWriter

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
                let has = try await dataStore.hasVoiceprints(
                    transcriptID: candidate.transcriptID, kind: .raw, space: space
                )
                if has {
                    skipReasons.append(
                        "\(candidate.title) (\(candidate.meetingID)): already has voiceprints"
                    )
                } else {
                    items.append(WorkItem(candidate: candidate))
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
                writer.writeStderr("  plan: \(item.candidate.title)")
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
        var voiceprintsAdded = 0
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
                voiceprintsAdded += result.added
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
        writer.writeStderr("Voiceprints added: \(voiceprintsAdded)")
        if totalUnmapped > 0 {
            writer.writeStderr("Unmapped speakers: \(totalUnmapped)")
        }

        return BackfillSummary(
            processed: processed, failed: failed,
            skipped: skippedCount,
            voiceprintsAdded: voiceprintsAdded,
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

    private struct OneResult {
        let added: Int
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

        guard let embeddingSet = analysis.embeddingSets.first(
            where: { $0.kind == .raw }
        ) else {
            writer.writeStderr("  No raw embeddings from diarization")
            return OneResult(added: 0, unmapped: mapping.unmapped.count)
        }

        var items: [NewVoiceprint] = []
        for (freshID, storedID) in mapping.mapping {
            guard let vector = embeddingSet.vectors[freshID], !vector.isEmpty else { continue }
            let duration = analysis.speakerSpeechDurations[freshID] ?? 0
            items.append(NewVoiceprint(speakerID: storedID, vector: vector, speakingDuration: duration))
        }

        try await dataStore.addVoiceprints(
            items, kind: .raw, space: embeddingSet.space, to: candidate.transcriptID
        )
        writer.writeStderr("  Added \(items.count) voiceprints")

        return OneResult(added: items.count, unmapped: mapping.unmapped.count)
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
    let voiceprintsAdded: Int
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
