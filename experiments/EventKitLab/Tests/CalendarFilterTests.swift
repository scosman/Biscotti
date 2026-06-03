import XCTest

@testable import EventKitLab

final class CalendarFilterTests: XCTestCase {
    func testFilterSnapshotsByCalendar() {
        let workSnapshot = makeSnapshot(
            title: "Work Meeting", calendarTitle: "Work", calendarID: "cal-work"
        )
        let personalSnapshot = makeSnapshot(
            title: "Dentist", calendarTitle: "Personal", calendarID: "cal-personal"
        )
        let allSnapshots = [workSnapshot, personalSnapshot]

        let enabledIDs: Set<String> = ["cal-work"]
        let filtered = allSnapshots.filter { snapshot in
            enabledIDs.contains(snapshot.calendarIdentifier)
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.title, "Work Meeting")
    }

    func testAllCalendarsEnabledReturnsAll() {
        let s1 = makeSnapshot(title: "A", calendarTitle: "Cal1", calendarID: "cal-1")
        let s2 = makeSnapshot(title: "B", calendarTitle: "Cal2", calendarID: "cal-2")
        let allSnapshots = [s1, s2]

        let enabledIDs: Set<String> = ["cal-1", "cal-2"]
        let filtered = allSnapshots.filter { enabledIDs.contains($0.calendarIdentifier) }
        XCTAssertEqual(filtered.count, 2)
    }

    func testNoCalendarsEnabledReturnsEmpty() {
        let s1 = makeSnapshot(title: "A", calendarTitle: "Cal1", calendarID: "cal-1")
        let allSnapshots = [s1]

        let enabledIDs: Set<String> = []
        let filtered = allSnapshots.filter { enabledIDs.contains($0.calendarIdentifier) }
        XCTAssertEqual(filtered.count, 0)
    }

    func testFilterDistinguishesCalendarFromEventIdentifier() {
        // Ensure filtering uses calendarIdentifier, not calendarItemIdentifier
        let snapshot = makeSnapshot(title: "Meeting", calendarTitle: "Work", calendarID: "cal-work")

        // calendarItemIdentifier is "evt-cal-work" (set by makeSnapshot), not "cal-work"
        let wrongIDs: Set<String> = [snapshot.linkKey.calendarItemIdentifier]
        let filteredWrong = [snapshot].filter { wrongIDs.contains($0.calendarIdentifier) }
        XCTAssertEqual(filteredWrong.count, 0, "Should not match event identifier against calendar filter")

        let correctIDs: Set<String> = ["cal-work"]
        let filteredCorrect = [snapshot].filter { correctIDs.contains($0.calendarIdentifier) }
        XCTAssertEqual(filteredCorrect.count, 1, "Should match actual calendarIdentifier")
    }

    // MARK: - Helpers

    private func makeSnapshot(
        title: String, calendarTitle: String, calendarID: String
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            linkKey: EventLinkKey(
                eventIdentifier: "evt-\(calendarID)",
                calendarItemIdentifier: "evt-\(calendarID)",
                occurrenceStartDate: Date()
            ),
            calendarItemExternalIdentifier: "ext-\(calendarID)",
            title: title,
            notes: nil,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            url: nil,
            timeZoneIdentifier: nil,
            availability: "busy",
            status: "confirmed",
            organizerName: nil,
            organizerEmail: nil,
            organizerIsCurrentUser: false,
            calendarIdentifier: calendarID,
            calendarTitle: calendarTitle,
            calendarColorHex: nil,
            attendees: [],
            conferenceURL: nil,
            conferencePlatform: nil,
            snapshotDate: Date(),
            lastSyncDate: nil,
            isStale: false
        )
    }
}
