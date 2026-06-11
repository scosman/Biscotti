import DataStore
import Foundation
import Testing

@Suite("Calendar snapshot")
struct SnapshotTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("setSnapshot persists key event fields")
    func setSnapshotPersists() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Snapshot test")

        let snapshot = CalendarSnapshot(
            eventIdentifier: "ek-123",
            compositeKey: "Standup|2025-06-01|alice@x.com",
            title: "Daily Standup",
            startDate: Date(timeIntervalSince1970: 1_717_200_000),
            endDate: Date(timeIntervalSince1970: 1_717_203_600),
            isAllDay: false,
            location: "Room 42",
            url: URL(string: "https://meet.google.com/abc"),
            eventNotes: "Bring updates",
            calendarTitle: "Work",
            calendarColorHex: "#4285F4",
            conferenceURL: URL(string: "https://meet.google.com/abc"),
            conferencePlatform: "Google Meet"
        )

        try await store.setSnapshot(snapshot, for: meetingID)

        let meeting = try await store.meeting(id: meetingID)
        let snap = meeting?.calendarSnapshot
        #expect(snap != nil)
        #expect(snap?.eventIdentifier == "ek-123")
        #expect(snap?.compositeKey == "Standup|2025-06-01|alice@x.com")
        #expect(snap?.title == "Daily Standup")
        #expect(snap?.isAllDay == false)
        #expect(snap?.location == "Room 42")
        #expect(snap?.conferenceURL == URL(string: "https://meet.google.com/abc"))
        #expect(snap?.conferencePlatform == "Google Meet")
        #expect(snap?.calendarTitle == "Work")
        #expect(snap?.calendarColorHex == "#4285F4")
        #expect(snap?.eventNotes == "Bring updates")
    }

    @Test("clearSnapshot removes snapshot and meeting survives")
    func clearSnapshotAndMeetingSurvives() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Clearable")

        let snapshot = CalendarSnapshot(
            compositeKey: "test|key",
            title: "Event"
        )
        try await store.setSnapshot(snapshot, for: meetingID)
        #expect(try await store.meeting(id: meetingID)?.calendarSnapshot != nil)

        try await store.clearSnapshot(for: meetingID)

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting != nil)
        #expect(meeting?.calendarSnapshot == nil)
        #expect(meeting?.title == "Clearable")
    }

    @Test("setSnapshot replaces existing snapshot and deletes old entity")
    func setSnapshotReplaces() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Replace")

        let first = CalendarSnapshot(
            eventIdentifier: "old",
            compositeKey: "old|key",
            title: "Old Event"
        )
        try await store.setSnapshot(first, for: meetingID)

        let second = CalendarSnapshot(
            eventIdentifier: "new",
            compositeKey: "new|key",
            title: "New Event"
        )
        try await store.setSnapshot(second, for: meetingID)

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.calendarSnapshot?.eventIdentifier == "new")
        #expect(meeting?.calendarSnapshot?.title == "New Event")

        // Verify the old snapshot entity was deleted, not orphaned
        let allSnapshots = try await store.fetchAllSnapshots()
        #expect(allSnapshots.count == 1)
        #expect(allSnapshots.first?.eventIdentifier == "new")
    }

    @Test("clearSnapshot on meeting with no snapshot is a no-op")
    func clearNoSnapshot() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No snapshot")

        // Should not throw
        try await store.clearSnapshot(for: meetingID)

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting != nil)
        #expect(meeting?.calendarSnapshot == nil)
    }

    @Test("setSnapshot on non-existent meeting throws notFound")
    func setSnapshotMissing() async throws {
        let store = try makeStore()
        let bogus = UUID()
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Test")
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.setSnapshot(snapshot, for: bogus)
        }
    }
}
