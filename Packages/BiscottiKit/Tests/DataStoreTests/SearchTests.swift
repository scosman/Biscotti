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
        #expect(hits.first?.matchedFields.contains(.notes) == true)
        #expect(hits.first?.matchedFields.contains(.title) == false)
    }

    @Test("Notes ranked like transcript, below title")
    func notesRankedBelowTitle() async throws {
        let store = try makeStore()
        // Meeting A: "budget" in title (score 3)
        _ = try await store.createMeeting(title: "Budget review")
        // Meeting B: "budget" only in notes (score 1, same as transcript weight)
        let meetingB = try await store.createMeeting(title: "Team sync")
        try await store.setNotes("Discussed next year's budget allocation", for: meetingB)

        let hits = try await store.searchHits("budget", limit: 50)
        #expect(hits.count == 2)
        // Title match (score 3) ranks above notes match (score 1)
        #expect(hits[0].title == "Budget review")
        #expect(hits[0].matchedFields.contains(.title))
        #expect(hits[1].title == "Team sync")
        #expect(hits[1].matchedFields.contains(.notes))
    }

    @Test("Notes match is case-insensitive")
    func notesCaseInsensitive() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        try await store.setNotes("ACTION ITEMS: Review the PR", for: meetingID)

        let hits = try await store.searchHits("action items", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.notes) == true)
    }

    @Test("Notes and transcript can both match, scoring additively")
    func notesAndTranscriptBothMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Planning")
        try await store.setNotes("roadmap planning for Q3", for: meetingID)

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
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("roadmap", limit: 50)
        #expect(hits.count == 1)
        // Both fields should be reported
        #expect(hits.first?.matchedFields.contains(.notes) == true)
        #expect(hits.first?.matchedFields.contains(.transcript) == true)
        // Score should be 2 (1 for transcript + 1 for notes)
        #expect(hits.first?.score == 2)
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

    @Test("Tag-only term matches meeting with score 3")
    func tagOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.id == meetingID)
        #expect(hits.first?.score == 3)
        #expect(hits.first?.matchedFields.contains(.tags) == true)
        #expect(hits.first?.matchedFields.contains(.title) == false)
    }

    @Test("Tag + title both match, scoring additively")
    func tagPlusTitleScoring() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Customer Review")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.count == 1)
        // title (3) + tags (3) = 6
        #expect(hits.first?.score == 6)
        #expect(hits.first?.matchedFields.contains(.title) == true)
        #expect(hits.first?.matchedFields.contains(.tags) == true)
    }

    @Test("Tag search is case-insensitive")
    func tagSearchCaseInsensitive() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.createTagAndApply(name: "IMPORTANT", to: meetingID)

        let hits = try await store.searchHits("important", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.tags) == true)
    }

    @Test("Tag search matches partial name")
    func tagSearchPartialMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        _ = try await store.createTagAndApply(name: "Customer", to: meetingID)

        let hits = try await store.searchHits("custom", limit: 50)
        #expect(hits.count == 1)
        #expect(hits.first?.matchedFields.contains(.tags) == true)
    }

    @Test("Untagged meeting not matched by tag search")
    func untaggedMeetingNotMatched() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Plain Meeting")

        let hits = try await store.searchHits("customer", limit: 50)
        #expect(hits.isEmpty)
    }

    @Test("Tags field sort order places tags after title")
    func tagsFieldSortOrder() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Review")
        _ = try await store.createTagAndApply(name: "Review", to: meetingID)

        let hits = try await store.searchHits("review", limit: 50)
        #expect(hits.count == 1)
        let fields = try #require(hits.first?.matchedFields)
        // title should come before tags in sorted order
        #expect(fields.first == .title)
        #expect(fields.contains(.tags))
    }
}
