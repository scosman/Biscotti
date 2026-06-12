import DataStore
import Foundation
import Testing

@Suite("Meeting CRUD operations")
struct MeetingCRUDTests {
    /// Fresh in-memory store for every test.
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    // MARK: - Create & read

    @Test("Create meeting returns a valid UUID and is fetchable")
    func createAndFetch() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Standup")
        try await store.read { store in
            let meeting = try store.meeting(id: id)
            #expect(meeting != nil)
            #expect(meeting?.title == "Standup")
            #expect(meeting?.id == id)
        }
    }

    @Test("Meeting with start/end dates round-trips correctly")
    func datesRoundTrip() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)
        let id = try await store.createMeeting(title: "With dates", start: start, end: end)
        try await store.read { store in
            let meeting = try store.meeting(id: id)
            #expect(meeting?.startDate == start)
            #expect(meeting?.endDate == end)
        }
    }

    @Test("Fetching a non-existent ID returns nil")
    func fetchMissing() async throws {
        let store = try makeStore()
        #expect(try await store.meetingExists(id: UUID()) == false)
    }

    // MARK: - Delete

    @Test("Delete removes meeting")
    func deleteMeeting() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Ephemeral")
        try await store.delete(meetingID: id)
        #expect(try await store.meetingExists(id: id) == false)
    }

    @Test("Delete non-existent meeting throws notFound")
    func deleteNotFound() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.delete(meetingID: bogus)
        }
    }

    // MARK: - Recent meetings

    @Test("recentMeetings returns newest first, respects limit")
    func recentOrdering() async throws {
        let store = try makeStore()
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        // Create 5 meetings with ascending createdAt.
        // Date() increments monotonically between calls.
        for idx in 0 ..< 5 {
            try await store.createMeeting(
                title: "Meeting \(idx)",
                start: baseDate.addingTimeInterval(Double(idx) * 60)
            )
        }

        try await store.read { store in
            let recent = try store.recentMeetings(limit: 3)
            #expect(recent.count == 3)
            // Most-recent createdAt first — the last inserted should be first.
            #expect(recent[0].title == "Meeting 4")
            #expect(recent[1].title == "Meeting 3")
            #expect(recent[2].title == "Meeting 2")
        }
    }

    @Test("recentMeetings with limit larger than data returns all")
    func recentLimitOverflow() async throws {
        let store = try makeStore()
        try await store.createMeeting(title: "Only one")
        let count = try await store.read { try $0.recentMeetings(limit: 100).count }
        #expect(count == 1)
    }

    // MARK: - Upcoming meetings

    @Test("upcomingMeetings returns only future meetings, ordered ascending")
    func upcomingOrdering() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Past meeting — should be excluded
        try await store.createMeeting(
            title: "Past",
            start: now.addingTimeInterval(-3600)
        )
        // Future meetings
        let futureID2 = try await store.createMeeting(
            title: "Later",
            start: now.addingTimeInterval(7200)
        )
        let futureID1 = try await store.createMeeting(
            title: "Soon",
            start: now.addingTimeInterval(600)
        )
        // No start date — should be excluded
        try await store.createMeeting(title: "No date")

        try await store.read { store in
            let upcoming = try store.upcomingMeetings(now: now, limit: 10)
            #expect(upcoming.count == 2)
            #expect(upcoming[0].id == futureID1)
            #expect(upcoming[1].id == futureID2)
        }
    }

    @Test("upcomingMeetings respects limit")
    func upcomingLimit() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for idx in 1 ... 5 {
            try await store.createMeeting(
                title: "Future \(idx)",
                start: now.addingTimeInterval(Double(idx) * 60)
            )
        }
        let count = try await store.read { try $0.upcomingMeetings(now: now, limit: 2).count }
        #expect(count == 2)
    }
}
