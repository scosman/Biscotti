import DataStore
import Foundation
import Testing

@Suite("People operations")
struct PeopleTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    // MARK: - findOrCreatePerson

    @Test("Email-based dedup returns existing person and retains original name")
    func emailDedupRetainsOriginalName() async throws {
        let store = try makeStore()
        let id1 = try await store.findOrCreatePerson(name: "Alice", email: "alice@example.com")
        // Second call with a different name but same email should return the same person,
        // keeping the ORIGINAL name (name reconciliation is out of scope for 3.1).
        let id2 = try await store.findOrCreatePerson(name: "Alice Smith", email: "alice@example.com")
        #expect(id1 == id2)

        // Verify the stored name is still the original, not overwritten
        let meeting = try await store.createMeeting(title: "Name check")
        try await store.setParticipants([id1], organizer: nil, for: meeting)
        try await store.read { store in
            let fetched = try store.meeting(id: meeting)
            #expect(fetched?.participants.first?.name == "Alice")
        }
    }

    @Test("Dedup by email is case-insensitive")
    func emailCaseInsensitive() async throws {
        let store = try makeStore()
        let id1 = try await store.findOrCreatePerson(name: "Bob", email: "BOB@example.com")
        let id2 = try await store.findOrCreatePerson(name: "Bob", email: "bob@EXAMPLE.com")
        #expect(id1 == id2)
    }

    @Test("Without email, dedup falls back to exact name match")
    func nameFallback() async throws {
        let store = try makeStore()
        let id1 = try await store.findOrCreatePerson(name: "Charlie", email: nil)
        let id2 = try await store.findOrCreatePerson(name: "Charlie", email: nil)
        #expect(id1 == id2)
    }

    @Test("Different names without email create separate people")
    func differentNamesNoEmail() async throws {
        let store = try makeStore()
        let id1 = try await store.findOrCreatePerson(name: "Dave", email: nil)
        let id2 = try await store.findOrCreatePerson(name: "David", email: nil)
        #expect(id1 != id2)
    }

    @Test("Same name but different emails create separate people")
    func sameNameDifferentEmails() async throws {
        let store = try makeStore()
        let id1 = try await store.findOrCreatePerson(name: "Eve", email: "eve@work.com")
        let id2 = try await store.findOrCreatePerson(name: "Eve", email: "eve@personal.com")
        #expect(id1 != id2)
    }

    // MARK: - setParticipants

    @Test("Set participants on a meeting")
    func setParticipants() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Team sync")
        let alice = try await store.findOrCreatePerson(name: "Alice", email: "a@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: "b@x.com")

        try await store.setParticipants([alice, bob], organizer: alice, for: meetingID)

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.participants.count == 2)
            #expect(meeting?.organizer?.id == alice)
        }
    }

    @Test("setParticipants replaces existing participants")
    func replaceParticipants() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Retro")
        let alice = try await store.findOrCreatePerson(name: "Alice", email: "a@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: "b@x.com")

        try await store.setParticipants([alice, bob], organizer: nil, for: meetingID)
        try await store.read { store in
            let count = try store.meeting(id: meetingID)?.participants.count
            #expect(count == 2)
        }

        // Replace with just Bob
        try await store.setParticipants([bob], organizer: bob, for: meetingID)
        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.participants.count == 1)
            #expect(meeting?.participants.first?.id == bob)
            #expect(meeting?.organizer?.id == bob)
        }
    }

    @Test("setParticipants for non-existent meeting throws notFound")
    func participantsNotFoundMeeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.setParticipants([], organizer: nil, for: bogus)
        }
    }

    @Test("setParticipants with non-existent person throws notFound")
    func participantsNotFoundPerson() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Planning")
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.setParticipants([bogus], organizer: nil, for: meetingID)
        }
    }

    @Test("Clearing participants removes all participants and organizer")
    func clearParticipants() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Clearable")
        let alice = try await store.findOrCreatePerson(name: "Alice", email: "a@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: "b@x.com")

        // Set initial participants + organizer
        try await store.setParticipants([alice, bob], organizer: alice, for: meetingID)
        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let participantCount = meeting?.participants.count
            let hasOrganizer = meeting?.organizer != nil
            #expect(participantCount == 2)
            #expect(hasOrganizer)
        }

        // Clear to empty
        try await store.setParticipants([], organizer: nil, for: meetingID)
        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.participants.isEmpty == true)
            #expect(meeting?.organizer == nil)
        }
    }

    // MARK: - Cross-meeting person reuse

    @Test("Person recurs across multiple meetings")
    func personAcrossMeetings() async throws {
        let store = try makeStore()
        let alice = try await store.findOrCreatePerson(name: "Alice", email: "a@x.com")

        let meetingID1 = try await store.createMeeting(title: "Meeting 1")
        let meetingID2 = try await store.createMeeting(title: "Meeting 2")

        try await store.setParticipants([alice], organizer: nil, for: meetingID1)
        try await store.setParticipants([alice], organizer: alice, for: meetingID2)

        // Same person ID appears on both meetings
        try await store.read { store in
            let meeting1 = try store.meeting(id: meetingID1)
            let meeting2 = try store.meeting(id: meetingID2)
            #expect(meeting1?.participants.first?.id == alice)
            #expect(meeting2?.participants.first?.id == alice)
            #expect(meeting2?.organizer?.id == alice)
        }
    }
}
