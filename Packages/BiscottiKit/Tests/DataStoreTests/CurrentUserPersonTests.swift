import DataStore
import Foundation
import Testing

@Suite("DataStore -- currentUserPersonIDs")
struct CurrentUserPersonTests {
    @Test("collects the distinct current-user persons of all snapshots")
    func currentUserPersonIDsCollectsDistinctIDs() async throws {
        let store = try DataStore(storage: .inMemory)
        let myself = try await store.findOrCreatePerson(name: "Me", email: "me@example.com")
        let workMe = try await store.findOrCreatePerson(name: "Me (work)", email: "me@work.example")
        let colleague = try await store.findOrCreatePerson(name: "Priya", email: "priya@example.com")

        for (index, currentUser) in [myself, myself, workMe, nil].enumerated() {
            let meetingID = try await store.createMeeting(title: "Meeting \(index)")
            try await store.setSnapshot(
                CalendarSnapshot(compositeKey: "event-\(index)", title: "Event \(index)"),
                for: meetingID
            )
            try await store.setParticipants(
                [colleague] + (currentUser.map { [$0] } ?? []),
                organizer: colleague,
                currentUser: currentUser,
                for: meetingID
            )
        }
        // A meeting without a snapshot contributes nothing.
        _ = try await store.createMeeting(title: "No event")

        #expect(try await store.currentUserPersonIDs() == [myself, workMe])
    }

    @Test("is empty when no snapshot names a current user")
    func emptyWithoutCurrentUser() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Meeting")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "event", title: "Event"), for: meetingID)

        #expect(try await store.currentUserPersonIDs().isEmpty)
    }
}
