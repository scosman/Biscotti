import Foundation
import Testing
import Transcription
@testable import DataStore

// MARK: - Shared Helpers

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private func makeDraft(
    id: UUID = UUID(),
    externalID: String? = nil,
    title: String = "Imported",
    created: Date = Date(timeIntervalSince1970: 1_700_000_000),
    summary: String = "",
    notes: String = "",
    transcript: [TranscriptSegmentDraft] = []
) -> ImportedMeetingDraft {
    ImportedMeetingDraft(
        meetingID: id,
        externalID: externalID,
        title: title,
        created: created,
        summary: summary,
        notes: notes,
        transcript: transcript
    )
}

private func makeSegments() -> [TranscriptSegmentDraft] {
    [
        TranscriptSegmentDraft(
            speakerID: 0, speakerLabel: "Steve", startTime: 23, text: "Let's get started."
        ),
        TranscriptSegmentDraft(
            speakerID: 1, speakerLabel: "Priya", startTime: 31, text: "I pushed the fix."
        ),
        TranscriptSegmentDraft(
            speakerID: 0, speakerLabel: "Steve", startTime: 40, text: "Great."
        )
    ]
}

private func twoSpeakerResult(
    texts: [String] = ["Hello world", "Hi there"]
) -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: texts.enumerated().map { index, text in
            TranscriptSegment(
                speakerID: index,
                speakerLabel: "Speaker \(index)",
                startTime: TimeInterval(index) * 3.5,
                endTime: TimeInterval(index + 1) * 3.5,
                text: text,
                confidence: 0.9,
                noSpeechProbability: 0.01,
                words: nil
            )
        },
        speakerEmbeddings: [:],
        processingDuration: 1.0
    )
}

// MARK: - Import Write Path

@Suite("Import write path")
struct ImportWritePathTests {
    @Test("Insert creates meetings with the given UUIDs and import fields")
    func insertCreatesMeetings() async throws {
        let store = try makeStore()
        let uuidA = UUID()
        let uuidB = UUID()
        let batchID = try await store.nextImportBatchID()

        let inserted = try await store.insertImportedMeetings(
            [
                makeDraft(id: uuidA, title: "Meeting A"),
                makeDraft(id: uuidB, externalID: "granola-42", title: "Meeting B")
            ],
            batchID: batchID
        )
        #expect(inserted == 2)

        try await store.read { store in
            let meetingA = try #require(try store.meeting(id: uuidA))
            #expect(meetingA.title == "Meeting A")
            #expect(meetingA.editedTitle)
            #expect(meetingA.externalID == nil)
            #expect(meetingA.importBatch == batchID)
            #expect(meetingA.startDate == nil)
            #expect(meetingA.endDate == nil)

            let meetingB = try #require(try store.meeting(id: uuidB))
            #expect(meetingB.externalID == "granola-42")
            #expect(meetingB.importBatch == batchID)
        }
    }

    @Test("Insert stores created as createdAt and gates editedSummary on content")
    func insertSummaryAndCreated() async throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let withSummary = UUID()
        let withoutSummary = UUID()

        _ = try await store.insertImportedMeetings(
            [
                makeDraft(id: withSummary, created: created, summary: "Recap", notes: "note"),
                makeDraft(id: withoutSummary, created: created)
            ],
            batchID: 1
        )

        try await store.read { store in
            let withSummaryMeeting = try #require(try store.meeting(id: withSummary))
            #expect(withSummaryMeeting.createdAt == created)
            #expect(withSummaryMeeting.summary == "Recap")
            #expect(withSummaryMeeting.editedSummary == true)
            #expect(withSummaryMeeting.notes == "note")

            let withoutSummaryMeeting = try #require(try store.meeting(id: withoutSummary))
            #expect(withoutSummaryMeeting.editedSummary == false)
        }
    }

    @Test("Insert creates a transcript record with ordered segments and sets preferred")
    func insertCreatesTranscript() async throws {
        let store = try makeStore()
        let meetingID = UUID()

        _ = try await store.insertImportedMeetings(
            [makeDraft(id: meetingID, transcript: makeSegments())],
            batchID: 1
        )

        try await store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.transcripts.count == 1)

            let record = try #require(meeting.transcripts.first)
            #expect(record.transcriptionMethodId == "imported")
            #expect(record.language == "")
            // Two distinct speaker IDs (0, 1) across three segments.
            #expect(record.speakerCount == 2)
            #expect(meeting.preferredTranscriptID == record.id)

            let segments = record.segments.sorted { $0.index < $1.index }
            #expect(segments.count == 3)
            #expect(segments.map(\.index) == [0, 1, 2])
            #expect(segments[0].text == "Let's get started.")
            #expect(segments[1].speakerLabel == "Priya")
            // Imported segments carry no durations.
            #expect(segments[2].endTime == segments[2].startTime)
        }
    }

    @Test("Insert with empty transcript creates no transcript record")
    func insertWithoutTranscript() async throws {
        let store = try makeStore()
        let meetingID = UUID()

        let inserted = try await store.insertImportedMeetings(
            [makeDraft(id: meetingID)],
            batchID: 1
        )
        #expect(inserted == 1)

        try await store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.transcripts.isEmpty)
            #expect(meeting.preferredTranscriptID == nil)
        }
    }

    @Test("Insert with no drafts returns zero")
    func insertNothing() async throws {
        let store = try makeStore()
        let inserted = try await store.insertImportedMeetings([], batchID: 1)
        #expect(inserted == 0)
    }

    @Test("Insert skips drafts whose meeting ID is already taken")
    func insertSkipsTakenIDs() async throws {
        let store = try makeStore()
        let recordedID = try await store.createMeeting(title: "Recorded")
        let inBatchDup = UUID()

        let inserted = try await store.insertImportedMeetings(
            [
                makeDraft(id: recordedID, title: "Clash"),
                makeDraft(id: inBatchDup, title: "First"),
                makeDraft(id: inBatchDup, title: "Second"),
                makeDraft(title: "Fresh")
            ],
            batchID: 1
        )
        // One clash with the store, one clash within the batch, one insert.
        #expect(inserted == 2)

        try await store.read { store in
            // The recorded meeting is untouched, and the in-batch first
            // occurrence wins.
            let recorded = try #require(try store.meeting(id: recordedID))
            #expect(recorded.title == "Recorded")
            let inBatchWinner = try #require(try store.meeting(id: inBatchDup))
            #expect(inBatchWinner.title == "First")
        }
        #expect(try await store.existingMeetingIdentity().meetingIDs.count == 3)
    }

    @Test("existingMeetingIdentity returns both ID sets")
    func existingIdentity() async throws {
        let store = try makeStore()
        let importedID = UUID()
        _ = try await store.insertImportedMeetings(
            [
                makeDraft(id: importedID),
                makeDraft(externalID: "otter-7", title: "From Otter")
            ],
            batchID: 1
        )
        _ = try await store.createMeeting(title: "Recorded")

        let identity = try await store.existingMeetingIdentity()
        #expect(identity.meetingIDs.contains(importedID))
        #expect(identity.externalIDs == ["otter-7"])
        // The recorded meeting contributes its UUID but no external ID.
        #expect(identity.meetingIDs.count == 3)
    }

    @Test("nextImportBatchID is epoch milliseconds of now")
    func batchIDFromNow() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000.123)
        let batchID = try await store.nextImportBatchID(now: now)
        #expect(batchID == 1_750_000_000_123)
    }

    @Test("nextImportBatchID increments past a colliding existing batch")
    func batchIDCollision() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000.0)
        let colliding = Int(1_750_000_000_000)
        _ = try await store.insertImportedMeetings(
            [makeDraft()],
            batchID: colliding
        )

        let batchID = try await store.nextImportBatchID(now: now)
        #expect(batchID == colliding + 1)
    }

    @Test("importedMeetingCounts returns the imported/remaining split")
    func importedCounts() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Recorded A")
        _ = try await store.createMeeting(title: "Recorded B")
        _ = try await store.insertImportedMeetings(
            [makeDraft(), makeDraft(title: "Second")],
            batchID: 1
        )

        let counts = try await store.importedMeetingCounts()
        #expect(counts.imported == 2)
        #expect(counts.remaining == 2)
    }
}

// MARK: - Bulk Delete & Export Read Path

@Suite("Imported meeting delete and export read path")
struct ImportDeleteExportTests {
    @Test("meetingIDsForExport sorts by effective date descending")
    func exportOrdering() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)

        // startDate wins over createdAt; createdAt-only meetings interleave.
        let middleStart = try await store.createMeeting(
            title: "Middle", start: base.addingTimeInterval(1000)
        )
        let oldestStart = try await store.createMeeting(
            title: "Recorded old", start: base.addingTimeInterval(-5000)
        )
        let newestStart = try await store.createMeeting(
            title: "Newest", start: base.addingTimeInterval(5000)
        )
        // Imported meeting: no startDate, sorts by createdAt.
        let importedCreated = base.addingTimeInterval(3000)
        let importedID = UUID()
        _ = try await store.insertImportedMeetings(
            [makeDraft(id: importedID, created: importedCreated)],
            batchID: 1
        )

        let ids = try await store.meetingIDsForExport()
        #expect(ids == [newestStart, importedID, middleStart, oldestStart])
    }

    @Test("deleteImportedMeetings removes only imported meetings and cascades transcripts")
    func deleteRemovesOnlyImported() async throws {
        let store = try makeStore()
        let importedID = UUID()
        _ = try await store.insertImportedMeetings(
            [makeDraft(id: importedID, transcript: makeSegments())],
            batchID: 1
        )
        let recordedID = try await store.createMeeting(title: "Recorded")

        let deleted = try await store.deleteImportedMeetings()
        #expect(deleted == 1)
        #expect(try await store.meetingExists(id: importedID) == false)
        #expect(try await store.meetingExists(id: recordedID) == true)

        try await store.read { store in
            let transcripts = try store.fetchAllTranscripts()
            let segments = try store.fetchAllSegments()
            #expect(transcripts.isEmpty)
            #expect(segments.isEmpty)
        }
    }

    @Test("deleteImportedMeetings clears search-index entries for deleted meetings")
    func deleteClearsSearchIndex() async throws {
        let store = try makeStore()
        let importedID = UUID()
        _ = try await store.insertImportedMeetings(
            [makeDraft(id: importedID, title: "Xylophone Imported")],
            batchID: 1
        )
        _ = try await store.createMeeting(title: "Xylophone Recorded")

        // Both are indexed once a search runs.
        #expect(try await store.searchHits("xylophone", limit: 10).count == 2)

        _ = try await store.deleteImportedMeetings()

        let hits = try await store.searchHits("xylophone", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id != importedID)
    }

    @Test("deleteImportedMeetings with none imported returns zero")
    func deleteNothing() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Recorded")
        let deleted = try await store.deleteImportedMeetings()
        #expect(deleted == 0)
    }

    @Test("exportData resolves speaker names and returns segments in index order")
    func exportDataResolution() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        let transcriptID = try await store.addTranscript(
            twoSpeakerResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)
        let personID = try await store.findOrCreatePerson(name: "Alice Smith", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: personID, for: transcriptID
        )

        let data = try await store.exportData(for: [meetingID])
        #expect(data.count == 1)

        let export = try #require(data.first)
        #expect(export.id == meetingID)
        #expect(export.title == "Standup")
        #expect(export.segments.count == 2)
        #expect(export.segments[0].text == "Hello world")
        #expect(export.segments[1].text == "Hi there")
        #expect(export.speakerNames[0] == "Alice Smith")
        #expect(export.speakerNames[1] == nil)
    }

    @Test("exportData preserves input order and skips unknown IDs")
    func exportDataOrder() async throws {
        let store = try makeStore()
        let firstID = try await store.createMeeting(title: "A")
        let secondID = try await store.createMeeting(title: "B")

        let data = try await store.exportData(for: [secondID, UUID(), firstID])
        #expect(data.map(\.id) == [secondID, firstID])
    }

    @Test("exportData for a meeting with no transcript yields empty segments")
    func exportDataNoTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Bare")

        let createdAt: Date? = try await store.read { store in
            try store.meeting(id: meetingID)?.createdAt
        }

        let export = try #require(
            try await store.exportData(for: [meetingID]).first
        )
        #expect(export.segments.isEmpty)
        #expect(export.speakerNames.isEmpty)
        #expect(export.date == createdAt)
    }

    @Test("exportData with several transcripts exports the preferred one")
    func exportDataUsesPreferredTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.addTranscript(
            twoSpeakerResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        let secondID = try await store.addTranscript(
            twoSpeakerResult(texts: ["Second version A", "Second version B"]),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(secondID, for: meetingID)

        let export = try #require(
            try await store.exportData(for: [meetingID]).first
        )
        #expect(export.segments.map(\.text) == ["Second version A", "Second version B"])
    }

    @Test("exportData with transcripts but no preferred ID yields empty segments")
    func exportDataWithoutPreferredID() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.addTranscript(
            twoSpeakerResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let export = try #require(
            try await store.exportData(for: [meetingID]).first
        )
        #expect(export.segments.isEmpty)
        #expect(export.speakerNames.isEmpty)
    }

    @Test("exportData sorts segments by index, not storage order")
    func exportDataSortsSegmentsByIndex() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")

        try await store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            let record = TranscriptRecord(
                transcriptionMethodId: "manual",
                language: "",
                speakerCount: 1
            )
            store.context.insert(record)
            // Appended out of index order on purpose: relationship order
            // must not become segment order.
            let late = TranscriptSegmentRecord(
                index: 1,
                speakerID: 0,
                speakerLabel: "Steve",
                startTime: 10,
                endTime: 10,
                text: "Second",
                noSpeechProbability: 0
            )
            let early = TranscriptSegmentRecord(
                index: 0,
                speakerID: 0,
                speakerLabel: "Steve",
                startTime: 0,
                endTime: 0,
                text: "First",
                noSpeechProbability: 0
            )
            store.context.insert(late)
            store.context.insert(early)
            record.segments.append(late)
            record.segments.append(early)
            meeting.transcripts.append(record)
            meeting.preferredTranscriptID = record.id
            try store.save()
        }

        let export = try #require(
            try await store.exportData(for: [meetingID]).first
        )
        #expect(export.segments.map(\.text) == ["First", "Second"])
    }

    @Test("exportData survives duplicate meeting IDs already in the store")
    func exportDataDuplicateMeetingIDs() async throws {
        let store = try makeStore()
        let dup = UUID()

        // The write path now prevents this state, but rows written before
        // that guard existed (or by another tool) must not trap a read.
        try await store.read { store in
            store.context.insert(Meeting(id: dup, title: "First"))
            store.context.insert(Meeting(id: dup, title: "Second"))
            try store.save()
        }

        let data = try await store.exportData(for: [dup, dup])
        #expect(data.count == 2)
        #expect(data.map(\.id) == [dup, dup])
    }
}
