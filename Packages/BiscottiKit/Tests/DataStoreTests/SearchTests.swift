import DataStore
import Foundation
import Testing
import Transcription

@Suite("Search (title + participant names)")
struct SearchTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Search matches on meeting title")
    func matchByTitle() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")
        _ = try await store.createMeeting(title: "Daily Standup")

        try await store.read { store in
            let results = try store.search("Sprint")
            #expect(results.count == 1)
            #expect(results.first?.title == "Sprint Planning")
        }
    }

    @Test("Search is case-insensitive on title")
    func caseInsensitiveTitle() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")

        try await store.read { store in
            let results = try store.search("sprint planning")
            #expect(results.count == 1)
            #expect(results.first?.title == "Sprint Planning")
        }
    }

    @Test("Search matches on participant names")
    func matchByParticipantName() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        let alice = try await store.findOrCreatePerson(name: "Alice Johnson", email: "alice@x.com")
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        try await store.read { store in
            let results = try store.search("Alice")
            #expect(results.count == 1)
            #expect(results.first?.title == "Generic Meeting")
        }
    }

    @Test("Search is case-insensitive on participant names")
    func caseInsensitiveParticipant() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Meeting")
        let bob = try await store.findOrCreatePerson(name: "Bob Smith", email: "bob@x.com")
        try await store.setParticipants([bob], organizer: nil, for: meetingID)

        let count = try await store.read { try $0.search("bob smith").count }
        #expect(count == 1)
    }

    @Test("Search with no match returns empty")
    func noMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")

        let isEmpty = try await store.read { try $0.search("Nonexistent").isEmpty }
        #expect(isEmpty)
    }

    @Test("Search matches partial title")
    func partialTitleMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Weekly Sprint Planning Review")

        let count = try await store.read { try $0.search("Sprint").count }
        #expect(count == 1)
    }

    @Test("Search returns multiple matching meetings")
    func multipleMatches() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")
        _ = try await store.createMeeting(title: "Sprint Review")
        _ = try await store.createMeeting(title: "Retro")

        let count = try await store.read { try $0.search("Sprint").count }
        #expect(count == 2)
    }

    @Test("Search matches via participant even when title doesn't match")
    func participantOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        let alice = try await store.findOrCreatePerson(name: "Zara Unique", email: nil)
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        // "Zara" doesn't appear in the title
        try await store.read { store in
            let results = try store.search("Zara")
            #expect(results.count == 1)
            #expect(results.first?.title == "Standup")
        }
    }
}

// MARK: - Notes search tests (searchHits)

@Suite("Search notes field (searchHits)")
struct SearchNotesTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Meeting matching ONLY via notes appears in searchHits")
    func notesOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        try await store.setNotes("Follow up on unicorn project details", for: meetingID)

        let hits = try await store.searchHits("unicorn", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        // The excerpt is drawn from the notes column, the only match.
        #expect(hits.first?.snippet.contains("unicorn") == true)
    }

    @Test("Notes ranked like transcript, below title")
    func notesRankedBelowTitle() async throws {
        let store = try makeStore()
        // Meeting A: "budget" in title (column weight 3)
        _ = try await store.createMeeting(title: "Budget review")
        // Meeting B: "budget" only in notes (column weight 1)
        let meetingB = try await store.createMeeting(title: "Team sync")
        try await store.setNotes("Discussed next year's budget allocation", for: meetingB)

        let hits = try await store.searchHits("budget", limit: 50)
        #expect(hits.count == 2)
        // Title match outranks notes match.
        #expect(hits[0].title == "Budget review")
        #expect(hits[1].title == "Team sync")
        #expect(hits[0].score > hits[1].score)
    }

    @Test("Notes match is case-insensitive")
    func notesCaseInsensitive() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        try await store.setNotes("ACTION ITEMS: Review the PR", for: meetingID)

        let hits = try await store.searchHits("action items", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
    }

    /// A term appearing in two columns of the same meeting yields exactly one
    /// hit, not one per matching column.
    ///
    /// Deliberately does **not** assert that the two-column match outranks the
    /// one-column match. Notes and transcript both carry column weight 1, and
    /// BM25's document-length normalization can outweigh the extra
    /// occurrence -- a shorter single-match document legitimately scores
    /// higher. The old additive score guaranteed "more columns wins"; BM25
    /// does not, and that is correct behaviour rather than a regression.
    /// Ranking by column weight is pinned separately, where the weights
    /// differ enough to dominate (see `notesRankedBelowTitle`).
    @Test("A term in notes and transcript yields one hit, not two")
    func notesAndTranscriptBothMatch() async throws {
        let store = try makeStore()
        let both = try await store.createMeeting(title: "Planning")
        try await store.setNotes("roadmap planning for Q3", for: both)

        // Also add transcript with the same term
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "We need to finalize the roadmap",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: both
        )
        try await store.setPreferredTranscript(txID, for: both)

        // A second meeting with the term in notes only.
        let notesOnly = try await store.createMeeting(title: "Sync")
        try await store.setNotes("roadmap mentioned once", for: notesOnly)

        let hits = try await store.searchHits("roadmap", limit: 50)
        // One hit per meeting, not one per matching column.
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.id)) == Set([both, notesOnly]))
    }

    @Test("Empty notes do not produce false matches")
    func emptyNotesNoMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Regular Standup")

        // Search for a term that only exists in note text (which is empty)
        let hits = try await store.searchHits("unicorn", limit: 50)
        #expect(hits.isEmpty)
    }
}

// MARK: - Tag search tests (searchHits)

@Suite("Search tags field (searchHits)")
struct SearchTagsTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("Tag-only term matches meeting")
    func tagOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        // The term is absent from the title, so the match came via tags.
        #expect(hits.first?.title == "Generic Meeting")
    }

    /// Tags carry the same column weight as the title, so a meeting matching
    /// in both outranks one matching in the tag alone.
    @Test("Tag + title both matching outranks tag alone")
    func tagPlusTitleOutranksTagAlone() async throws {
        let store = try makeStore()
        let both = try await store.createMeeting(title: "Customer Review")
        _ = try await store.createTagAndApply(name: "Customer", to: both)

        let tagOnly = try await store.createMeeting(title: "Weekly Sync")
        _ = try await store.createTagAndApply(name: "Customer", to: tagOnly)

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.count == 2)
        #expect(hits[0].id == both)
        #expect(hits[1].id == tagOnly)
        #expect(hits[0].score > hits[1].score)
    }

    @Test("Tag search is case-insensitive")
    func tagSearchCaseInsensitive() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.createTagAndApply(name: "IMPORTANT", to: meetingID)

        let hits = try await store.searchHits("important", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
    }

    @Test("Tag search matches partial name")
    func tagSearchPartialMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("custom", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
    }

    @Test("Untagged meeting not matched by tag search")
    func untaggedMeetingNotMatched() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Plain Meeting")

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.isEmpty)
    }
}
