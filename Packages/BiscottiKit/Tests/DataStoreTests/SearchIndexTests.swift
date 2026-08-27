import Foundation
import Testing
import Transcription
@testable import DataStore

// MARK: - Test helper

/// Builds a `MeetingContent` with only the specified fields populated.
private func content(
    uuid: UUID = UUID(),
    effectiveDate: Date = Date(),
    title: String = "",
    summary: String = "",
    notes: String = "",
    transcript: String = "",
    people: String = "",
    tags: String = ""
) -> SearchIndex.MeetingContent {
    SearchIndex.MeetingContent(
        uuid: uuid, effectiveDate: effectiveDate, title: title,
        summary: summary, notes: notes, transcript: transcript,
        people: people, tags: tags
    )
}

// MARK: - SearchIndex unit tests

@Suite("SearchIndex -- core operations")
struct SearchIndexCoreTests {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(storage: .inMemory)
    }

    @Test("Index a meeting and find it by title")
    func indexAndSearchTitle() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(uuid: meetingID, title: "Sprint Planning"))

        let hits = try index.search(query: "Sprint", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.meetingUUID == meetingID)
        #expect(hits.first?.fields.contains(.title) == true)
    }

    @Test("Prefix matching works")
    func prefixMatching() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(uuid: meetingID, title: "Infrastructure Review"))

        let hits = try index.search(query: "infra", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.meetingUUID == meetingID)
    }

    @Test("AND across terms: both terms must appear")
    func andAcrossTerms() throws {
        let index = try makeIndex()
        let idBoth = UUID()
        let idOne = UUID()
        try index.indexMeeting(content(uuid: idBoth, title: "Sprint Planning"))
        try index.indexMeeting(content(uuid: idOne, title: "Sprint Review"))

        // "Sprint Plan" should match only the first (both terms present).
        let hits = try index.search(query: "Sprint Plan", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.meetingUUID == idBoth)
    }

    @Test("AND across terms: terms can span different fields")
    func andAcrossFields() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(
            uuid: meetingID, title: "Quarterly Review", people: "Alice Johnson"
        ))

        // "Quarterly" in title, "Alice" in people.
        let hits = try index.search(query: "Quarterly Alice", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.fields.contains(.title) == true)
        #expect(hits.first?.fields.contains(.people) == true)
    }

    @Test("Score weights: title 3, tags 3, summary 2, people 2, notes 1, transcript 1")
    func scoreWeights() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(
            uuid: meetingID, title: "budget", summary: "budget",
            notes: "budget", transcript: "budget",
            people: "budget", tags: "budget"
        ))

        let hits = try index.search(query: "budget", limit: 50)
        #expect(hits.count == 1)
        // 3 (title) + 3 (tags) + 2 (summary) + 2 (people) + 1 (notes) + 1 (transcript) = 12
        #expect(hits.first?.score == 12)
    }

    @Test("Remove a meeting from the index")
    func removeMeeting() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(uuid: meetingID, title: "Doomed Meeting"))

        #expect(try index.search(query: "Doomed", limit: 50).count == 1)

        try index.removeMeeting(uuid: meetingID)
        #expect(try index.search(query: "Doomed", limit: 50).isEmpty)
        #expect(index.indexedMeetingCount == 0)
    }

    @Test("INSERT OR REPLACE self-corrects stale data")
    func insertOrReplaceCorrects() throws {
        let index = try makeIndex()
        let meetingID = UUID()

        // Index with old title.
        try index.indexMeeting(content(uuid: meetingID, title: "Old Title"))
        #expect(try index.search(query: "Old", limit: 50).count == 1)

        // Re-index with new title.
        try index.indexMeeting(content(uuid: meetingID, title: "New Title"))

        // Old term gone, new term present.
        #expect(try index.search(query: "Old", limit: 50).isEmpty)
        #expect(try index.search(query: "New", limit: 50).count == 1)
        // Only one entry in the map.
        #expect(index.indexedMeetingCount == 1)
    }

    @Test("Empty query returns no results")
    func emptyQueryReturnsNothing() throws {
        let index = try makeIndex()
        try index.indexMeeting(content(uuid: UUID(), title: "Something"))

        #expect(try index.search(query: "", limit: 50).isEmpty)
        #expect(try index.search(query: "   ", limit: 50).isEmpty)
    }

    @Test("removeStaleEntries purges unlisted UUIDs")
    func removeStaleEntries() throws {
        let index = try makeIndex()
        let keepID = UUID()
        let staleID = UUID()
        try index.indexMeeting(content(uuid: keepID, title: "Keep Me"))
        try index.indexMeeting(content(uuid: staleID, title: "Remove Me"))

        try index.removeStaleEntries(liveUUIDs: [keepID])

        #expect(try index.search(query: "Keep", limit: 50).count == 1)
        #expect(try index.search(query: "Remove", limit: 50).isEmpty)
        #expect(index.indexedMeetingCount == 1)
    }

    @Test("clear resets all data but preserves schema")
    func clearResetsData() throws {
        let index = try makeIndex()
        try index.indexMeeting(content(uuid: UUID(), title: "Meeting"))
        #expect(index.indexedMeetingCount == 1)

        try index.clear()
        #expect(index.indexedMeetingCount == 0)
        #expect(try index.search(query: "Meeting", limit: 50).isEmpty)
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() throws {
        let index = try makeIndex()
        try index.indexMeeting(content(uuid: UUID(), title: "UPPERCASE Title"))

        // FTS5 unicode61 tokenizer lowercases by default.
        #expect(try index.search(query: "uppercase", limit: 50).count == 1)
        #expect(try index.search(query: "UPPERCASE", limit: 50).count == 1)
        #expect(try index.search(query: "Uppercase", limit: 50).count == 1)
    }

    @Test("FTS5 special characters in query do not crash")
    func specialCharactersSafe() throws {
        let index = try makeIndex()
        try index.indexMeeting(content(uuid: UUID(), title: "C++ meeting (draft)"))

        // Should not throw or crash.
        _ = try index.search(query: "C++", limit: 50)
        _ = try index.search(query: "(draft)", limit: 50)
        _ = try index.search(query: "AND OR NOT", limit: 50)
        _ = try index.search(query: "\"quoted\"", limit: 50)
    }

    @Test("Limit caps returned results")
    func limitCapsResults() throws {
        let index = try makeIndex()
        for offset in 0 ..< 10 {
            try index.indexMeeting(content(uuid: UUID(), title: "Alpha \(offset)"))
        }

        let hits = try index.search(query: "Alpha", limit: 3)
        #expect(hits.count == 3)
    }

    @Test("Score sorts results descending")
    func scoreSortOrder() throws {
        let index = try makeIndex()
        let lowID = UUID()
        let highID = UUID()

        // lowID: only notes match (weight 1).
        try index.indexMeeting(content(uuid: lowID, title: "Generic", notes: "budget"))
        // highID: title match (weight 3).
        try index.indexMeeting(content(uuid: highID, title: "Budget Review"))

        let hits = try index.search(query: "budget", limit: 50)
        #expect(hits.count == 2)
        #expect(hits[0].meetingUUID == highID)
        #expect(hits[0].score == 3)
        #expect(hits[1].meetingUUID == lowID)
        #expect(hits[1].score == 1)
    }

    @Test("Multi-term score accumulates per term per field")
    func multiTermScoreAccumulates() throws {
        let index = try makeIndex()
        let meetingID = UUID()
        try index.indexMeeting(content(uuid: meetingID, title: "Sprint Planning"))

        let hits = try index.search(query: "Sprint Planning", limit: 50)
        #expect(hits.count == 1)
        // Two terms, each matching title (weight 3): 3 + 3 = 6.
        #expect(hits.first?.score == 6)
    }
}

// MARK: - DataStore FTS5 integration tests

@Suite("DataStore searchHits -- FTS5 integration")
struct DataStoreFTS5Tests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Summary field is searchable at weight 2")
    func summaryFieldSearchable() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Weekly Sync")
        try await store.setSummary(
            "Discussed the quarterly roadmap milestones", for: meetingID
        )

        let hits = try await store.searchHits("roadmap", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        #expect(hits.first?.matchedFields.contains(.summary) == true)
        #expect(hits.first?.score == 2)
    }

    @Test("Summary + title both contribute to score")
    func summaryAndTitleScore() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Budget Review")
        try await store.setSummary(
            "Reviewed the budget for next quarter", for: meetingID
        )

        let hits = try await store.searchHits("budget", limit: 50)
        #expect(hits.count == 1)
        // title (3) + summary (2) = 5
        #expect(hits.first?.score == 5)
        #expect(hits.first?.matchedFields.contains(.title) == true)
        #expect(hits.first?.matchedFields.contains(.summary) == true)
    }

    @Test("AND semantics: multi-term query requires all terms")
    func andSemantics() async throws {
        let store = try makeStore()
        // Meeting A has both "sprint" and "planning" in title.
        let idA = try await store.createMeeting(title: "Sprint Planning")
        // Meeting B has only "sprint" in title.
        _ = try await store.createMeeting(title: "Sprint Review")

        let hits = try await store.searchHits("sprint plan", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == idA)
    }

    @Test("AND semantics: terms can match across different fields")
    func andAcrossFields() async throws {
        let store = try makeStore()
        // Meeting with "quarterly" in title, "alice" in people.
        let meetingID = try await store.createMeeting(title: "Quarterly Review")
        let alice = try await store.findOrCreatePerson(
            name: "Alice Johnson", email: nil
        )
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        let hits = try await store.searchHits("quarterly alice", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        #expect(hits.first?.matchedFields.contains(.title) == true)
        #expect(hits.first?.matchedFields.contains(.people) == true)
    }

    @Test("Index self-corrects after title change")
    func selfCorrectsAfterTitleChange() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Old Title")

        // Should find with old title.
        let before = try await store.searchHits("Old", limit: 50)
        #expect(before.count == 1)

        // Change title.
        try await store.setTitle("New Title", for: meetingID)

        // Should find with new title, not old.
        let afterNew = try await store.searchHits("New", limit: 50)
        #expect(afterNew.count == 1)
        let afterOld = try await store.searchHits("Old", limit: 50)
        #expect(afterOld.isEmpty)
    }

    @Test("Deleted meeting disappears from search results")
    func deletedMeetingRemoved() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Ephemeral Meeting")

        #expect(try await store.searchHits("Ephemeral", limit: 50).count == 1)

        try await store.delete(meetingID: meetingID)

        #expect(try await store.searchHits("Ephemeral", limit: 50).isEmpty)
    }

    @Test("Prefix matching works through DataStore")
    func prefixMatchingIntegration() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Infrastructure Planning")

        let hits = try await store.searchHits("infra", limit: 50)
        #expect(hits.count == 1)
    }

    @Test("matchedFields includes summary in sort order")
    func matchedFieldsSortOrder() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Review")
        try await store.setSummary("This review was productive", for: meetingID)

        let hits = try await store.searchHits("review", limit: 50)
        #expect(hits.count == 1)
        let fields = try #require(hits.first?.matchedFields)
        // title should come before summary in sort order.
        let titleIdx = fields.firstIndex(of: .title)
        let summaryIdx = fields.firstIndex(of: .summary)
        #expect(titleIdx != nil)
        #expect(summaryIdx != nil)
        if let titlePos = titleIdx, let summaryPos = summaryIdx {
            #expect(titlePos < summaryPos)
        }
    }

    @Test("Transcript segments are flattened and searchable")
    func transcriptSearchable() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")

        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "We discussed the xylophone prototype",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("xylophone", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.transcript) == true)
        #expect(hits.first?.score == 1) // transcript weight
    }

    @Test("Tag search still works through FTS5")
    func tagSearchIntegration() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.tags) == true)
        #expect(hits.first?.score == 3) // tags weight
    }

    @Test("Notes search still works through FTS5")
    func notesSearchIntegration() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Meeting")
        try await store.setNotes(
            "Remember to order the zeppelin parts", for: meetingID
        )

        let hits = try await store.searchHits("zeppelin", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.notes) == true)
        #expect(hits.first?.score == 1) // notes weight
    }

    @Test("People search includes organizer")
    func peopleSearchIncludesOrganizer() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        let org = try await store.findOrCreatePerson(
            name: "Xander Organizer", email: nil
        )
        try await store.setParticipants([], organizer: org, for: meetingID)

        let hits = try await store.searchHits("xander", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.people) == true)
    }
}

// MARK: - Incremental History Sync tests (on-disk stores)

/// Tests that exercise the SwiftData History API incremental sync path.
/// In-memory stores do not support history tracking, so these tests use
/// on-disk stores in temporary directories.
@Suite("Incremental History Sync -- on-disk stores")
struct IncrementalSyncTests {
    /// Creates an on-disk DataStore in a fresh temporary directory.
    private func makeOnDiskStore() throws -> (DataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "IncrementalSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let store = try DataStore(storage: .onDisk(dir))
        return (store, dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("History token is captured on first sync with on-disk store")
    func tokenCapturedOnDisk() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        // Create a meeting so there is at least one history transaction.
        _ = try await store.createMeeting(title: "Token Test")

        // First search triggers full reconcile, which captures a token.
        _ = try await store.searchHits("Token", limit: 50)

        let token = await store.lastSyncToken
        #expect(token != nil, "History token must be captured for on-disk stores")
    }

    @Test("Incremental sync picks up a new meeting after the token is set")
    func incrementalPicksUpNewMeeting() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        // Seed a meeting and search to trigger full reconcile + capture token.
        _ = try await store.createMeeting(title: "Seed Meeting")
        let initial = try await store.searchHits("Seed", limit: 50)
        #expect(initial.count == 1)

        let tokenBefore = await store.lastSyncToken
        #expect(tokenBefore != nil)

        // Create another meeting (generates a new history transaction).
        _ = try await store.createMeeting(title: "Incremental Meeting")

        // Next search uses incremental sync and finds both meetings.
        let hits = try await store.searchHits("Meeting", limit: 50)
        #expect(hits.count == 2)

        // Token should have advanced.
        let tokenAfter = await store.lastSyncToken
        #expect(tokenAfter != nil)
        #expect(tokenBefore != tokenAfter)
    }

    @Test("Title edit reindexes via incremental sync (self-correction)")
    func titleEditReindexesIncrementally() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Original Title")

        // Full reconcile — indexes "Original Title".
        let before = try await store.searchHits("Original", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Change title.
        try await store.setTitle("Revised Title", for: meetingID)

        // Incremental sync picks up the update.
        let afterNew = try await store.searchHits("Revised", limit: 50)
        #expect(afterNew.count == 1)
        let afterOld = try await store.searchHits("Original", limit: 50)
        #expect(afterOld.isEmpty)
    }

    @Test("Notes edit reindexes via incremental sync")
    func notesEditReindexesIncrementally() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Standup")

        // Full reconcile.
        _ = try await store.searchHits("Standup", limit: 50)
        #expect(await store.lastSyncToken != nil)

        // Add notes.
        try await store.setNotes("Follow up on xylophone order", for: meetingID)

        let hits = try await store.searchHits("xylophone", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.notes) == true)
    }

    @Test("Summary edit reindexes via incremental sync")
    func summaryEditReindexesIncrementally() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Review")

        // Full reconcile.
        _ = try await store.searchHits("Review", limit: 50)
        #expect(await store.lastSyncToken != nil)

        // Set summary.
        try await store.setSummary(
            "Discussed the zeppelin launch timeline", for: meetingID
        )

        let hits = try await store.searchHits("zeppelin", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.summary) == true)
    }

    @Test("Tag rename reindexes affected meetings via incremental sync")
    func tagRenameReindexes() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Generic")
        _ = try await store.createTagAndApply(name: "Alpha", to: meetingID)

        // Full reconcile — indexes tag "Alpha".
        let before = try await store.searchHits("Alpha", limit: 50)
        #expect(before.count == 1)
        #expect(before.first?.matchedFields.contains(.tags) == true)
        #expect(await store.lastSyncToken != nil)

        // Rename the tag via direct model mutation.
        try await store.read { store in
            let tags = try store.fetchAllTags()
            let tag = try #require(tags.first(where: { $0.name == "Alpha" }))
            tag.name = "Beta"
            try store.save()
        }

        // Incremental sync picks up the Tag update and reindexes
        // the meeting through collectAffectedMeetings.
        let afterNew = try await store.searchHits("Beta", limit: 50)
        #expect(afterNew.count == 1)
        #expect(afterNew.first?.matchedFields.contains(.tags) == true)
        let afterOld = try await store.searchHits("Alpha", limit: 50)
        #expect(afterOld.isEmpty)
    }

    @Test("Person rename reindexes affected meetings via incremental sync")
    func personRenameReindexes() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Standup")
        let personID = try await store.findOrCreatePerson(
            name: "Alice Smith", email: nil
        )
        try await store.setParticipants(
            [personID], organizer: nil, for: meetingID
        )

        // Full reconcile — indexes person "Alice Smith".
        let before = try await store.searchHits("Alice", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Rename person via direct model mutation.
        try await store.read { store in
            let persons = try store.fetchAllPersons()
            let person = try #require(
                persons.first(where: { $0.name == "Alice Smith" })
            )
            person.name = "Alicia Smith"
            try store.save()
        }

        // Incremental sync reindexes affected meetings.
        let afterNew = try await store.searchHits("Alicia", limit: 50)
        #expect(afterNew.count == 1)
        let afterOld = try await store.searchHits("Alice", limit: 50)
        #expect(afterOld.isEmpty)
    }

    @Test("Deleted meeting purged via history-driven stale-entry path")
    func deletedMeetingPurgedViaHistory() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Ephemeral")

        // Full reconcile — indexes the meeting.
        let before = try await store.searchHits("Ephemeral", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Delete via context directly (bypasses DataStore.delete's
        // eager searchIndex.removeMeeting call) to exercise the
        // history-driven stale purge path alone.
        try await store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            store.context.delete(meeting)
            try store.save()
        }

        // Incremental sync detects the delete tombstone and purges
        // the stale index entry.
        let after = try await store.searchHits("Ephemeral", limit: 50)
        #expect(after.isEmpty)
    }

    @Test("Persisted token round-trips through the side DB")
    func tokenPersistsToSideDB() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        _ = try await store.createMeeting(title: "Persistent")
        _ = try await store.searchHits("Persistent", limit: 50)

        // Verify the token is held in memory.
        #expect(await store.lastSyncToken != nil)

        // Verify it was also persisted to the side DB as non-nil data.
        let hasPersistedToken = try await store.read { store in
            try store.searchIndex.historyToken() != nil
        }
        #expect(hasPersistedToken, "Token must be persisted to the side DB")
    }

    @Test("Persisted token enables incremental sync after in-memory reset")
    func persistedTokenResumesIncrementally() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        _ = try await store.createMeeting(title: "Before Reset")
        _ = try await store.searchHits("Before", limit: 50)
        #expect(await store.lastSyncToken != nil)

        // Clear in-memory token (simulates app restart).
        await store.read { store in
            store.lastSyncToken = nil
        }
        #expect(await store.lastSyncToken == nil)

        // Create new data after the in-memory token was cleared.
        _ = try await store.createMeeting(title: "After Reset")

        // Search should load the persisted token from the side DB
        // and use incremental sync to pick up the new meeting.
        let hits = try await store.searchHits("After", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "After Reset")

        // Token should be restored in memory.
        #expect(await store.lastSyncToken != nil)
    }

    @Test("startDate edit updates the effective date in the index")
    func startDateEditUpdatesEffectiveDate() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let oldDate = Date(timeIntervalSinceReferenceDate: 1000)
        let newDate = Date(timeIntervalSinceReferenceDate: 9000)

        let meetingID = try await store.createMeeting(
            title: "Dated Meeting", start: oldDate
        )

        // Full reconcile indexes the meeting with oldDate.
        let before = try await store.searchHits("Dated", limit: 50)
        #expect(before.count == 1)
        #expect(before.first?.date == oldDate)

        // Change startDate via direct model mutation.
        try await store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            meeting.startDate = newDate
            try store.save()
        }

        // Incremental sync picks up the update and refreshes the date.
        let after = try await store.searchHits("Dated", limit: 50)
        #expect(after.count == 1)
        #expect(after.first?.date == newDate)
    }
}

// MARK: - Deterministic truncation tests (Fix 1)

@Suite("Deterministic truncation at score ties")
struct DeterministicTruncationTests {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(storage: .inMemory)
    }

    @Test("Truncation returns N most recent when all scores tie")
    func truncationReturnsMostRecent() throws {
        let index = try makeIndex()

        // Create 20 meetings with distinct dates, all matching the same
        // title-only term so they have identical scores.
        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        var uuidsAndDates: [(UUID, Date)] = []
        for offset in 0 ..< 20 {
            let uuid = UUID()
            let date = baseDate.addingTimeInterval(
                Double(offset) * 3600
            )
            uuidsAndDates.append((uuid, date))
            try index.indexMeeting(content(
                uuid: uuid, effectiveDate: date, title: "Alpha"
            ))
        }

        // Ask for 10 of 20. The 10 most recent should survive.
        let hits = try index.search(query: "Alpha", limit: 10)
        #expect(hits.count == 10)

        // All scores are identical (title weight = 3).
        for hit in hits {
            #expect(hit.score == 3)
        }

        // Verify the returned meetings are the 10 most recent by date.
        let expectedUUIDs = Set(
            uuidsAndDates
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map(\.0)
        )
        let returnedUUIDs = Set(hits.map(\.meetingUUID))
        #expect(returnedUUIDs == expectedUUIDs)

        // Verify ordering within results: date descending.
        for pair in hits.indices.dropLast() {
            #expect(hits[pair].effectiveDate >= hits[pair + 1].effectiveDate)
        }
    }

    @Test("Repeated calls with identical data return identical results")
    func deterministicRepeatedCalls() throws {
        let index = try makeIndex()

        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        for offset in 0 ..< 15 {
            try index.indexMeeting(content(
                uuid: UUID(),
                effectiveDate: baseDate.addingTimeInterval(
                    Double(offset) * 3600
                ),
                title: "Beta"
            ))
        }

        // Run the same query 5 times; all results must be identical.
        let first = try index.search(query: "Beta", limit: 5)
        for _ in 1 ..< 5 {
            let again = try index.search(query: "Beta", limit: 5)
            #expect(again.map(\.meetingUUID) == first.map(\.meetingUUID))
        }
    }
}

// MARK: - Transaction atomicity tests (Fix 2)

@Suite("Transaction wrapping -- indexMeeting atomicity")
struct TransactionAtomicityTests {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(storage: .inMemory)
    }

    @Test("Partial index state is repaired by fullReconcile")
    func partialIndexRepairedByReconcile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "TxAtomicity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DataStore(storage: .onDisk(dir))
        let meetingID = try await store.createMeeting(title: "Full Meeting")

        // Full reconcile to build index.
        _ = try await store.searchHits("Full", limit: 50)
        #expect(await store.lastSyncToken != nil)

        // Simulate partial index: remove the meeting from one FTS
        // table but leave meeting_map intact. This mimics the state
        // a crash mid-indexMeeting would leave WITHOUT transaction
        // wrapping.
        try await store.read { store in
            // Delete the title entry for this meeting's rowid.
            let rowid = try #require(
                try store.searchIndex.testRowID(
                    for: meetingID
                )
            )
            try store.searchIndex.testDeleteFTSRow(
                field: .title, rowid: rowid
            )
        }

        // Verify the title term is now missing.
        let broken = try await store.searchHits("Full", limit: 50)
        #expect(broken.isEmpty, "Title entry was manually removed")

        // Force a full reconcile by clearing the token.
        await store.read { store in
            store.lastSyncToken = nil
            try? store.searchIndex.clear()
        }

        // Next search triggers fullReconcile, which repairs the entry.
        let repaired = try await store.searchHits("Full", limit: 50)
        #expect(repaired.count == 1)
        #expect(repaired.first?.id == meetingID)
    }
}

// MARK: - Staleness detection tests (Fix 3)

@Suite("Staleness detection -- count mismatch triggers reconcile")
struct StalenessDetectionTests {
    @Test("Meeting in store but absent from index is detected and reindexed")
    func missingMeetingDetected() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "Staleness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Create two meetings and build the index.
        let id1 = try await store.createMeeting(title: "Present Meeting")
        _ = try await store.createMeeting(title: "Ghost Meeting")
        _ = try await store.searchHits("Meeting", limit: 50)
        #expect(await store.lastSyncToken != nil)

        // Manually remove one meeting from the index (simulates the
        // index and store diverging, e.g. from a backup restore).
        try await store.read { store in
            try store.searchIndex.removeMeeting(uuid: id1)
        }

        // Index now has 1 entry, store has 2 meetings. The count
        // mismatch in syncSearchIndex should trigger fullReconcile.
        let hits = try await store.searchHits("Present", limit: 50)
        #expect(hits.count == 1, "Missing meeting should be reindexed")
        #expect(hits.first?.id == id1)
    }
}

// MARK: - fullReconcile direct tests

@Suite("fullReconcile -- direct verification")
struct FullReconcileTests {
    @Test("fullReconcile indexes all meetings and purges stale entries")
    func fullReconcileDirectly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "FullReconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DataStore(storage: .onDisk(dir))

        // Create meetings and build the index via a search.
        _ = try await store.createMeeting(title: "Alpha Meeting")
        _ = try await store.createMeeting(title: "Beta Meeting")
        _ = try await store.searchHits("Meeting", limit: 50)

        // Inject a stale entry directly into the index.
        let staleUUID = UUID()
        try await store.read { store in
            try store.searchIndex.indexMeeting(content(
                uuid: staleUUID, title: "Stale Ghost"
            ))
        }

        // Verify the stale entry is present before reconcile.
        let staleCount = await store.read { store in
            store.searchIndex.indexedMeetingCount
        }
        #expect(staleCount == 3) // 2 real + 1 stale

        // Clear token to force fullReconcile on next search.
        await store.read { store in
            store.lastSyncToken = nil
            try? store.searchIndex.testDeleteHistoryToken()
        }

        // Search triggers fullReconcile.
        let hits = try await store.searchHits("Meeting", limit: 50)
        #expect(hits.count == 2) // Only the two real meetings

        // Stale entry should be purged.
        let afterCount = await store.read { store in
            store.searchIndex.indexedMeetingCount
        }
        #expect(afterCount == 2)

        // The ghost term should be gone.
        let ghostHits = try await store.searchHits("Stale", limit: 50)
        #expect(ghostHits.isEmpty)
    }
}

// MARK: - Delete-coverage tests (Fix 4)

@Suite("Delete coverage -- non-Meeting deletes reindex via relationship updates")
struct DeleteCoverageTests {
    private func makeOnDiskStore() throws -> (DataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "DeleteCov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let store = try DataStore(storage: .onDisk(dir))
        return (store, dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Tag deletion refreshes affected meeting's index entry")
    func tagDeletionRefreshes() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Tagged Meeting")
        _ = try await store.createTagAndApply(
            name: "UniqueTag", to: meetingID
        )

        // Build index; tag term should be searchable.
        let before = try await store.searchHits("UniqueTag", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Delete the tag via context.
        try await store.read { store in
            let tags = try store.fetchAllTags()
            let tag = try #require(
                tags.first(where: { $0.name == "UniqueTag" })
            )
            store.context.delete(tag)
            try store.save()
        }

        // After sync, the tag term should no longer match.
        let after = try await store.searchHits("UniqueTag", limit: 50)
        #expect(after.isEmpty, "Deleted tag's term should be removed from index")

        // The meeting itself should still be searchable by title.
        let titleHits = try await store.searchHits("Tagged", limit: 50)
        #expect(titleHits.count == 1)
    }

    @Test("Person deletion refreshes affected meeting's index entry")
    func personDeletionRefreshes() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(title: "Staffed Meeting")
        let personID = try await store.findOrCreatePerson(
            name: "Xylophone Person", email: nil
        )
        try await store.setParticipants(
            [personID], organizer: nil, for: meetingID
        )

        // Build index.
        let before = try await store.searchHits("Xylophone", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Delete the person via context.
        try await store.read { store in
            let persons = try store.fetchAllPersons()
            let person = try #require(
                persons.first(where: { $0.name == "Xylophone Person" })
            )
            store.context.delete(person)
            try store.save()
        }

        // After sync, the person's name should no longer match.
        let after = try await store.searchHits("Xylophone", limit: 50)
        #expect(after.isEmpty, "Deleted person's name should be removed from index")

        // Meeting still searchable by title.
        let titleHits = try await store.searchHits("Staffed", limit: 50)
        #expect(titleHits.count == 1)
    }

    /// Adds a transcript with a single segment and returns its ID.
    private func addTranscript(
        text: String, method: String, to meetingID: UUID,
        store: DataStore
    ) async throws -> UUID {
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: text,
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: method, language: "en",
            speakerCount: 1, segments: [seg],
            speakerEmbeddings: [:], processingDuration: 1.0
        )
        return try await store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
    }

    /// Characterization test: pins the current SwiftData behaviour
    /// where deleting a TranscriptRecord does NOT cause SwiftData to
    /// record a relationship-level update on the parent Meeting.
    /// The transcript text stays in the index because incremental
    /// sync never re-indexes the meeting.
    ///
    /// Not a shipping bug -- no production path deletes a
    /// TranscriptRecord individually (re-transcription is additive;
    /// the only transcript deletion is the cascade from Meeting
    /// deletion, which hadMeetingDeletes already covers).
    ///
    /// If this test starts FAILING, SwiftData now records the
    /// relationship update and the gap has closed. Invert the
    /// assertion (expect isEmpty) and update the doc comment on
    /// changedMeetings in DataStore+ReadModels.swift.
    @Test("TranscriptRecord delete leaves stale text (SwiftData gap)")
    func transcriptDeletionLeavesStaleText() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { cleanup(dir) }

        let meetingID = try await store.createMeeting(
            title: "Transcribed Meeting"
        )

        let txID = try await addTranscript(
            text: "Discussing zeppelin blueprints",
            method: "v1", to: meetingID, store: store
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        // Build index -- "zeppelin" (preferred) is present.
        let before = try await store.searchHits("zeppelin", limit: 50)
        #expect(before.count == 1)
        #expect(await store.lastSyncToken != nil)

        // Delete the preferred TranscriptRecord directly.
        try await store.read { store in
            let transcripts = try store.fetchAllTranscripts()
            let record = try #require(
                transcripts.first(where: { $0.id == txID })
            )
            store.context.delete(record)
            try store.save()
        }

        // SwiftData does not record a Meeting update for this
        // delete, so incremental sync does not re-index the
        // meeting. The old transcript text remains findable.
        let after = try await store.searchHits("zeppelin", limit: 50)
        #expect(
            !after.isEmpty,
            "Stale text persists -- SwiftData gap (see comment above)"
        )
    }
}
