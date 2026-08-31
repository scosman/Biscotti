import DataStore
import Foundation
import Testing

@Suite("DataStore meetingPeople")
struct MeetingPeopleTests {
    @Test("returns uncapped participants with the organizer separate and excluded")
    func uncappedParticipants() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Big meeting")
        let organizerID = try await store.findOrCreatePerson(name: "Ada L.", email: "ada@example.com")
        var participantIDs: [UUID] = []
        for idx in 1 ... 7 {
            try await participantIDs.append(
                store.findOrCreatePerson(name: "Person \(idx)", email: nil)
            )
        }
        try await store.setParticipants(participantIDs, organizer: organizerID, for: meetingID)

        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(people.participants.count == 7)
        #expect(people.organizer?.name == "Ada L.")
        #expect(people.organizer?.email == "ada@example.com")
        #expect(people.participants.allSatisfy { $0.id != organizerID })
    }

    @Test("excludes the organizer even when listed among participants")
    func organizerListedAsParticipant() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Sync")
        let organizerID = try await store.findOrCreatePerson(name: "Ada L.", email: nil)
        let otherID = try await store.findOrCreatePerson(name: "Grace", email: nil)
        try await store.setParticipants(
            [organizerID, otherID], organizer: organizerID, for: meetingID
        )

        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(people.participants.map(\.name) == ["Grace"])
        #expect(people.organizer?.name == "Ada L.")
    }

    @Test("dedupes repeated participant ids")
    func dedupesParticipants() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Dupes")
        let first = try await store.findOrCreatePerson(name: "First", email: nil)
        let second = try await store.findOrCreatePerson(name: "Second", email: nil)
        try await store.setParticipants(
            [first, first, second, first], organizer: nil, for: meetingID
        )

        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(people.participants.count == 2)
        #expect(Set(people.participants.map(\.name)) == ["First", "Second"])
    }

    @Test("returns nil for an unknown id")
    func unknownMeeting() async throws {
        let store = try DataStore(storage: .inMemory)
        let people = try await store.meetingPeople(id: UUID())
        #expect(people == nil)
    }

    @Test("meeting with no people has empty results")
    func noPeople() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Solo")
        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(people.organizer == nil)
        #expect(people.participants.isEmpty)
    }
}
