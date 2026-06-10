import DataStore
import Foundation
import Testing

@Suite("Meeting-to-event association")
struct AssociationTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("associate creates a snapshot with the given identifiers")
    func associateCreatesSnapshot() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Assoc test")

        try await store.associate(
            meetingID: meetingID,
            withEventIdentifier: "ek-1",
            compositeKey: "Standup|2025-06-01"
        )

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.calendarSnapshot?.eventIdentifier == "ek-1")
        #expect(meeting?.calendarSnapshot?.compositeKey == "Standup|2025-06-01")
    }

    @Test("associate with same event identifier is idempotent")
    func associateSameEventIdempotent() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Idempotent")

        try await store.associate(
            meetingID: meetingID,
            withEventIdentifier: "ek-1",
            compositeKey: "key1"
        )
        // Same event identifier again -- should not throw
        try await store.associate(
            meetingID: meetingID,
            withEventIdentifier: "ek-1",
            compositeKey: "key1-updated"
        )

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.calendarSnapshot?.eventIdentifier == "ek-1")
        #expect(meeting?.calendarSnapshot?.compositeKey == "key1-updated")
    }

    @Test("associate with different event identifier throws associationConflict")
    func associateConflict() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Conflict")

        // Set up a snapshot with an event identifier
        let snapshot = CalendarSnapshot(
            eventIdentifier: "ek-1",
            compositeKey: "key1",
            title: "Event 1"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        // Try to associate with a different event
        await #expect(throws: DataStoreError.associationConflict) {
            try await store.associate(
                meetingID: meetingID,
                withEventIdentifier: "ek-2",
                compositeKey: "key2"
            )
        }
    }

    @Test("correctAssociation replaces event identifier without error")
    func correctAssociationReplaces() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Correct")

        let snapshot = CalendarSnapshot(
            eventIdentifier: "ek-old",
            compositeKey: "old-key",
            title: "Old Event"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        try await store.correctAssociation(
            meetingID: meetingID,
            toEventIdentifier: "ek-new",
            compositeKey: "new-key"
        )

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.calendarSnapshot?.eventIdentifier == "ek-new")
        #expect(meeting?.calendarSnapshot?.compositeKey == "new-key")
    }

    @Test("correctAssociation creates snapshot when none exists")
    func correctAssociationCreatesSnapshot() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No snapshot")

        try await store.correctAssociation(
            meetingID: meetingID,
            toEventIdentifier: "ek-1",
            compositeKey: "key1"
        )

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.calendarSnapshot?.eventIdentifier == "ek-1")
    }

    @Test("associate on non-existent meeting throws notFound")
    func associateMissingMeeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.associate(
                meetingID: bogus,
                withEventIdentifier: "ek-1",
                compositeKey: "key"
            )
        }
    }

    @Test("correctAssociation on non-existent meeting throws notFound")
    func correctMissingMeeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.correctAssociation(
                meetingID: bogus,
                toEventIdentifier: "ek-1",
                compositeKey: "key"
            )
        }
    }
}
