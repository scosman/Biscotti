import DataStore
import Foundation
import Testing

@Suite("MeetingSummary participant mapping")
struct ReadModelParticipantTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("meetingSummaries maps participants organizer-first, deduped, capped at 5")
    func meetingSummaryParticipants() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Team Sync")

        // Create organizer + 6 attendees
        let organizerID = try await store.findOrCreatePerson(
            name: "Organizer", email: "org@example.com"
        )
        var attendeeIDs: [UUID] = []
        for idx in 0 ..< 6 {
            let pid = try await store.findOrCreatePerson(
                name: "Attendee \(idx)", email: "a\(idx)@example.com"
            )
            attendeeIDs.append(pid)
        }
        try await store.setParticipants(
            attendeeIDs, organizer: organizerID, for: meetingID
        )

        let summaries = try await store.meetingSummaries(limit: 10)
        let summary = try #require(summaries.first(where: { $0.id == meetingID }))

        // Capped at 5, organizer is first
        #expect(summary.participants.count == 5)
        #expect(summary.participants[0].name == "Organizer")

        // Total count reflects all 7 distinct people (1 org + 6 attendees)
        #expect(summary.participantCount == 7)
    }

    @Test("meetingSummaries deduplicates organizer who is also a participant")
    func meetingSummaryDedupOrganizerParticipant() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Dedup Test")

        let personID = try await store.findOrCreatePerson(
            name: "Alice", email: "alice@example.com"
        )
        // Set the same person as both organizer and participant
        try await store.setParticipants(
            [personID], organizer: personID, for: meetingID
        )

        let summaries = try await store.meetingSummaries(limit: 10)
        let summary = try #require(summaries.first(where: { $0.id == meetingID }))

        // Should appear only once
        #expect(summary.participants.count == 1)
        #expect(summary.participantCount == 1)
        #expect(summary.participants[0].name == "Alice")
    }

    @Test("meetingSummaries returns empty participants when none set")
    func meetingSummaryNoParticipants() async throws {
        let store = try makeStore()
        try await store.createMeeting(title: "Solo")

        let summaries = try await store.meetingSummaries(limit: 10)
        let summary = try #require(summaries.first)

        #expect(summary.participants.isEmpty)
        #expect(summary.participantCount == 0)
    }
}
