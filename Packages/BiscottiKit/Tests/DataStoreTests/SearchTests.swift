import DataStore
import Foundation
import Testing

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

        let results = try await store.search("Sprint")
        #expect(results.count == 1)
        #expect(results.first?.title == "Sprint Planning")
    }

    @Test("Search is case-insensitive on title")
    func caseInsensitiveTitle() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")

        let results = try await store.search("sprint planning")
        #expect(results.count == 1)
        #expect(results.first?.title == "Sprint Planning")
    }

    @Test("Search matches on participant names")
    func matchByParticipantName() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        let alice = try await store.findOrCreatePerson(name: "Alice Johnson", email: "alice@x.com")
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        let results = try await store.search("Alice")
        #expect(results.count == 1)
        #expect(results.first?.title == "Generic Meeting")
    }

    @Test("Search is case-insensitive on participant names")
    func caseInsensitiveParticipant() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Meeting")
        let bob = try await store.findOrCreatePerson(name: "Bob Smith", email: "bob@x.com")
        try await store.setParticipants([bob], organizer: nil, for: meetingID)

        let results = try await store.search("bob smith")
        #expect(results.count == 1)
    }

    @Test("Search with no match returns empty")
    func noMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")

        let results = try await store.search("Nonexistent")
        #expect(results.isEmpty)
    }

    @Test("Search matches partial title")
    func partialTitleMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Weekly Sprint Planning Review")

        let results = try await store.search("Sprint")
        #expect(results.count == 1)
    }

    @Test("Search returns multiple matching meetings")
    func multipleMatches() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Sprint Planning")
        _ = try await store.createMeeting(title: "Sprint Review")
        _ = try await store.createMeeting(title: "Retro")

        let results = try await store.search("Sprint")
        #expect(results.count == 2)
    }

    @Test("Search matches via participant even when title doesn't match")
    func participantOnlyMatch() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")
        let alice = try await store.findOrCreatePerson(name: "Zara Unique", email: nil)
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        // "Zara" doesn't appear in the title
        let results = try await store.search("Zara")
        #expect(results.count == 1)
        #expect(results.first?.title == "Standup")
    }
}
