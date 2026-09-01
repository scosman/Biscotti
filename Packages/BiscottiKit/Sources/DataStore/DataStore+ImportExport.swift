import Foundation
import SwiftData

// MARK: - Import Write Path

public extension DataStore {
    /// Everything already in the database that an import must not duplicate
    /// (functional spec §2.4). One fetch, mapped into two sets.
    func existingMeetingIdentity() throws -> ExistingMeetingIdentity {
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        return ExistingMeetingIdentity(
            meetingIDs: Set(meetings.map(\.id)),
            externalIDs: Set(meetings.compactMap(\.externalID))
        )
    }

    /// Returns a fresh import batch ID: epoch milliseconds at `now`,
    /// incremented while a meeting already carries that exact `importBatch`
    /// — two imports inside the same millisecond cannot share a batch.
    func nextImportBatchID(now: Date = Date()) throws -> Int {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.importBatch != nil }
        )
        // Narrow the fetch to the one column needed: only collisions with
        // the batch value matter, never the meetings themselves.
        descriptor.propertiesToFetch = [\.importBatch]
        let used = try Set(
            context.fetch(descriptor).compactMap(\.importBatch)
        )

        var candidate = Int(now.timeIntervalSince1970 * 1000)
        while used.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    /// Inserts the scanner's drafts as meetings (plus transcript records for
    /// non-empty transcript drafts), all stamped with `batchID`. One save at
    /// the end — a failure leaves the store unchanged. Returns the number of
    /// meetings inserted.
    @discardableResult
    func insertImportedMeetings(
        _ drafts: [ImportedMeetingDraft], batchID: Int
    ) throws -> Int {
        guard !drafts.isEmpty else { return 0 }

        for draft in drafts {
            let meeting = Meeting(
                id: draft.meetingID,
                title: draft.title,
                createdAt: draft.created
            )
            // Imported titles/summaries are authored content: calendar
            // association must never overwrite the title, and the AI
            // auto-run must never overwrite the summary.
            meeting.editedTitle = true
            meeting.summary = draft.summary
            meeting.editedSummary = !draft.summary.isEmpty
            meeting.notes = draft.notes
            meeting.externalID = draft.externalID
            meeting.importBatch = batchID
            context.insert(meeting)

            guard !draft.transcript.isEmpty else { continue }

            let record = TranscriptRecord(
                transcriptionMethodId: "imported",
                language: "",
                speakerCount: Set(draft.transcript.map(\.speakerID)).count
            )
            context.insert(record)

            for (index, segment) in draft.transcript.enumerated() {
                // Imported segments carry no durations (functional spec §4.2).
                let segmentRecord = TranscriptSegmentRecord(
                    index: index,
                    speakerID: segment.speakerID,
                    speakerLabel: segment.speakerLabel,
                    startTime: segment.startTime,
                    endTime: segment.startTime,
                    text: segment.text,
                    noSpeechProbability: 0
                )
                context.insert(segmentRecord)
                record.segments.append(segmentRecord)
            }

            meeting.transcripts.append(record)
            meeting.preferredTranscriptID = record.id
        }

        try save()
        return drafts.count
    }
}

// MARK: - Export Read Path

public extension DataStore {
    /// IDs of every meeting, sorted by effective date
    /// (`startDate ?? createdAt`) descending — newest first, the export
    /// order. The coalesce is not expressible in a SwiftData predicate, so
    /// the sort happens in memory (same approach as `meetingSummaries`).
    func meetingIDsForExport() throws -> [UUID] {
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        return meetings
            .sorted {
                ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt)
            }
            .map(\.id)
    }

    /// Hydrates export data for the given IDs, preserving the input order so
    /// chunked exports keep the newest-first sequence. IDs that no longer
    /// resolve to a meeting are skipped.
    func exportData(for ids: [UUID]) throws -> [MeetingExportData] {
        // The #Predicate macro cannot capture a function parameter directly;
        // it needs a local binding.
        let ids = ids
        let fetched = try context.fetch(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { ids.contains($0.id) }
            )
        )
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })

        var results: [MeetingExportData] = []
        for id in ids {
            guard let meeting = byID[id] else { continue }
            try results.append(exportData(for: meeting))
        }
        return results
    }

    private func exportData(for meeting: Meeting) throws -> MeetingExportData {
        let preferred: TranscriptRecord? = if let preferredID = meeting.preferredTranscriptID {
            meeting.transcripts.first { $0.id == preferredID }
        } else {
            nil
        }

        let segments: [SegmentData] = (preferred?.segments ?? [])
            .sorted { $0.index < $1.index }
            .map {
                SegmentData(
                    id: $0.id,
                    speakerID: $0.speakerID,
                    speakerLabel: $0.speakerLabel,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text
                )
            }

        // Resolve speaker assignments to person names, dropping dangling
        // person IDs — the same policy as `mapTranscript`.
        var speakerNames: [Int: String] = [:]
        for (speakerID, entry) in preferred?.speakerAssignments ?? [:] {
            if let person = try fetchPerson(id: entry.personID) {
                speakerNames[speakerID] = person.name
            }
        }

        return MeetingExportData(
            id: meeting.id,
            title: meeting.title,
            date: meeting.startDate ?? meeting.createdAt,
            summary: meeting.summary,
            notes: meeting.notes,
            segments: segments,
            speakerNames: speakerNames
        )
    }
}

// MARK: - Debug-Build Bulk Delete (functional spec §6.1)

public extension DataStore {
    /// Counts the imported (`importBatch != nil`) and remaining meetings via
    /// two `fetchCount` calls — no objects materialized.
    func importedMeetingCounts() throws -> (imported: Int, remaining: Int) {
        let imported = try context.fetchCount(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { $0.importBatch != nil }
            )
        )
        let remaining = try context.fetchCount(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { $0.importBatch == nil }
            )
        )
        return (imported, remaining)
    }

    /// Deletes every meeting whose `importBatch` is non-nil — the whole
    /// imported population, not one batch — removing each one's search-index
    /// entry before the delete, exactly as `delete(meetingID:)` does.
    /// Transcripts, segments, words, audio refs, and calendar snapshots go
    /// with them via the existing cascade rules. Returns the deleted count.
    @discardableResult
    func deleteImportedMeetings() throws -> Int {
        let meetings = try context.fetch(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { $0.importBatch != nil }
            )
        )
        guard !meetings.isEmpty else { return 0 }

        for meeting in meetings {
            // Eagerly remove from FTS5 index so it stays consistent even
            // before the next search-triggered sync.
            try? searchIndex.removeMeeting(uuid: meeting.id)
            context.delete(meeting)
        }
        try save()
        return meetings.count
    }
}
