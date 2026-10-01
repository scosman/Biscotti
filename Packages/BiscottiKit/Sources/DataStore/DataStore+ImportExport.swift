import Foundation
import SwiftData

// MARK: - Import Write Path

public extension DataStore {
    /// Everything already in the database that an import must not duplicate
    /// (functional spec §2.4). One fetch, narrowed to the two columns it
    /// reads — the same treatment as `nextImportBatchID`.
    func existingMeetingIdentity() throws -> ExistingMeetingIdentity {
        var descriptor = FetchDescriptor<Meeting>()
        descriptor.propertiesToFetch = [\.id, \.externalID]
        let meetings = try context.fetch(descriptor)
        return ExistingMeetingIdentity(
            meetingIDs: Set(meetings.map(\.id)),
            externalIDs: Set(meetings.compactMap(\.externalID))
        )
    }

    /// Returns a fresh import batch ID: epoch milliseconds at `now`,
    /// incremented while a meeting already carries that exact `importBatch`
    /// — two imports inside the same millisecond cannot share a batch.
    ///
    /// The value is only claimed once `insertImportedMeetings` writes it,
    /// with `await` points in between, so two overlapping imports could in
    /// principle draw the same ID. That cannot happen through the UI (the
    /// section's buttons are disabled while an import is in flight), and
    /// the field's only reader today is the debug bulk delete, which
    /// ignores batch boundaries.
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
    ///
    /// The scanner has already deduplicated against the identity it was
    /// handed (functional spec §2.4), but the write path does not trust
    /// that: a draft whose meeting ID already exists — in the store or in
    /// an earlier draft of this batch — is skipped, because `Meeting.id`
    /// carries no unique constraint and a duplicate row would corrupt the
    /// store silently.
    @discardableResult
    func insertImportedMeetings(
        _ drafts: [ImportedMeetingDraft], batchID: Int
    ) throws -> Int {
        guard !drafts.isEmpty else { return 0 }

        var idDescriptor = FetchDescriptor<Meeting>()
        idDescriptor.propertiesToFetch = [\.id]
        let existingIDs = try Set(
            context.fetch(idDescriptor).map(\.id)
        )

        var inserted = 0
        var batchIDs = Set<UUID>()
        for draft in drafts {
            guard existingIDs.contains(draft.meetingID) == false,
                  batchIDs.insert(draft.meetingID).inserted
            else { continue }

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

            if !draft.transcript.isEmpty {
                insertImportedTranscript(draft.transcript, into: meeting)
            }
            inserted += 1
        }

        guard inserted > 0 else { return 0 }
        try save()
        return inserted
    }

    /// Builds and inserts the transcript record for a non-empty imported
    /// transcript, links it to the meeting, and marks it preferred
    /// (functional spec §2.2/§4.2).
    private func insertImportedTranscript(
        _ transcript: [TranscriptSegmentDraft], into meeting: Meeting
    ) {
        let record = TranscriptRecord(
            transcriptionMethodId: "imported",
            language: "",
            speakerCount: Set(transcript.map(\.speakerID)).count
        )
        context.insert(record)

        for (index, segment) in transcript.enumerated() {
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
        let fetched = try context.fetch(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { ids.contains($0.id) }
            )
        )
        // `Meeting.id` has no unique constraint; if duplicate rows ever
        // entered the store, first-wins here keeps this lookup from
        // trapping on them.
        let byID = Dictionary(
            fetched.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var results: [MeetingExportData] = []
        for id in ids {
            guard let meeting = byID[id] else { continue }
            try results.append(exportData(for: meeting))
        }
        return results
    }

    private func exportData(for meeting: Meeting) throws -> MeetingExportData {
        // The same read model the detail surface uses: index-sorted
        // segments and speaker assignments resolved to person names with
        // dangling person IDs dropped (`mapTranscript`).
        let transcript = try meeting.preferredTranscriptID
            .flatMap { preferredID in
                meeting.transcripts.first { $0.id == preferredID }
            }
            .map { try mapTranscript($0) }

        return MeetingExportData(
            id: meeting.id,
            title: meeting.title,
            date: meeting.startDate ?? meeting.createdAt,
            summary: meeting.summary,
            notes: meeting.notes,
            segments: transcript?.segments ?? [],
            speakerNames: transcript?.speakerAssignments.mapValues(\.name) ?? [:]
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
