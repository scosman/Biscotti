import Calendar
import Foundation
import Testing
@testable import GraphCalendar

/// `GraphEventStore` serving `CalendarService` from memory: overlap,
/// calendar filter, merging the picker's events, `refreshEvent`, and the
/// poller-side snapshot bookkeeping.
@Suite("GraphEventStore")
struct GraphEventStoreTests {
    private static let ten = testWeek.start.addingTimeInterval(10 * 3600)

    private static func hour(_ offset: Double) -> Date {
        ten.addingTimeInterval(offset * 3600)
    }

    private static func snapshot(_ events: [EKEventDTO], fetchedAt: Date = ten) -> GraphEventStore.Snapshot {
        GraphEventStore.Snapshot(
            calendars: [TestAccount.ownCalendar],
            events: events,
            window: DateInterval(start: hour(-24), end: hour(24 * 8)),
            fetchedAt: fetchedAt
        )
    }

    @Test("events overlapping the interval, by EventKit's rule")
    func overlap() {
        let store = GraphEventStore()
        store.replace(with: Self.snapshot([
            dto("meeting", start: Self.ten, end: Self.hour(1)),
            dto("reminder", start: Self.ten, end: Self.ten)
        ]))

        func ids(_ start: Double, _ end: Double) -> [String] {
            store.events(in: DateInterval(start: Self.hour(start), end: Self.hour(end)), calendars: nil)
                .map(\.eventIdentifier)
        }

        #expect(ids(0.25, 0.5) == ["meeting"])
        #expect(ids(0, 1) == ["meeting", "reminder"])
        // Ending as the interval starts, or starting as it ends, is outside.
        #expect(ids(1, 2).isEmpty)
        #expect(ids(-1, 0).isEmpty)
    }

    @Test("the enabled-calendar filter: nil is every calendar")
    func calendarFilter() {
        let store = GraphEventStore()
        store.replace(with: Self.snapshot([
            dto("own", start: Self.ten, end: Self.hour(1)),
            dto("project", calendar: "cal-project", start: Self.ten, end: Self.hour(1))
        ]))
        let day = DateInterval(start: Self.hour(-1), end: Self.hour(12))

        #expect(store.events(in: day, calendars: nil).map(\.eventIdentifier) == ["own", "project"])
        #expect(store.events(in: day, calendars: ["cal-project"]).map(\.eventIdentifier) == ["project"])
        #expect(store.events(in: day, calendars: []).isEmpty)
    }

    @Test("picker events merge in sorted, the snapshot's copy winning")
    func mergesNearby() {
        let store = GraphEventStore()
        store.replace(with: Self.snapshot([
            dto("b", title: "From the poll", start: Self.hour(2), end: Self.hour(3)),
            dto("d", start: Self.hour(2), end: Self.hour(3))
        ]))
        store.setNearby([
            dto("a", start: Self.hour(1), end: Self.hour(2)),
            dto("b", title: "From the picker", start: Self.hour(2), end: Self.hour(3)),
            dto("c", start: Self.hour(2), end: Self.hour(3))
        ])

        let events = store.events(in: DateInterval(start: Self.ten, end: Self.hour(4)), calendars: nil)

        #expect(events.map(\.eventIdentifier) == ["a", "b", "c", "d"])
        #expect(events[1].title == "From the poll")
    }

    @Test("refreshEvent finds the occurrence in the snapshot or the picker's events")
    func refreshEvent() {
        let store = GraphEventStore()
        store.replace(with: Self.snapshot([dto("polled", start: Self.ten, end: Self.hour(1))]))
        store.setNearby([dto("older", start: Self.hour(-72), end: Self.hour(-71))])

        #expect(store.refreshEvent(eventIdentifier: "polled", occurrenceStart: Self.ten)?.eventIdentifier == "polled")
        #expect(store.refreshEvent(eventIdentifier: "older", occurrenceStart: Self.hour(-72)) != nil)
        #expect(store.refreshEvent(eventIdentifier: "polled", occurrenceStart: Self.hour(24)) == nil)
        #expect(store.refreshEvent(eventIdentifier: "deleted", occurrenceStart: Self.ten) == nil)
    }

    @Test("replace reports whether calendars or events changed, and clears stale")
    func replaceReportsChanges() {
        let store = GraphEventStore()
        let events = [dto("a", start: Self.ten, end: Self.hour(1))]

        #expect(store.replace(with: Self.snapshot(events)))
        store.markStale()
        #expect(store.isStale)
        // A later poll with the same contents is not a change.
        #expect(!store.replace(with: Self.snapshot(events, fetchedAt: Self.hour(1))))
        #expect(!store.isStale)
        #expect(store.snapshot?.fetchedAt == Self.hour(1))
        #expect(store.replace(with: Self.snapshot(events + [dto("b", start: Self.ten, end: Self.hour(1))])))
    }

    @Test("clear drops the account's events and keeps access")
    func clear() async throws {
        let store = GraphEventStore()
        #expect(store.authorizationStatus() == .notDetermined)
        #expect(try await store.requestAccess() == false)
        store.setAccess(.authorized)
        store.replace(with: Self.snapshot([dto("a", start: Self.ten, end: Self.hour(1))]))
        store.setNearby([dto("b", start: Self.hour(-72), end: Self.hour(-71))])
        store.markStale()

        store.clear()

        #expect(store.snapshot == nil)
        #expect(!store.isStale)
        #expect(store.calendars().isEmpty)
        #expect(store.events(in: DateInterval(start: Self.hour(-100), end: Self.hour(100)), calendars: nil).isEmpty)
        #expect(store.authorizationStatus() == .authorized)
        #expect(try await store.requestAccess())
    }
}

/// A timed event on `calendar` with no attendees.
func dto(
    _ id: String,
    title: String? = nil,
    calendar: String = TestAccount.ownCalendar.id,
    start: Date,
    end: Date,
    isAllDay: Bool = false
) -> EKEventDTO {
    EKEventDTO(
        eventIdentifier: id,
        calendarItemIdentifier: id,
        calendarItemExternalIdentifier: id,
        occurrenceDate: start,
        title: title ?? id,
        startDate: start,
        endDate: end,
        isAllDay: isAllDay,
        location: nil,
        url: nil,
        timeZone: nil,
        notes: nil,
        status: nil,
        availability: nil,
        calendarIdentifier: calendar,
        calendarTitle: "Calendar",
        calendarColorHex: "#808080",
        calendarSourceTitle: TestAccount.jane.sourceTitle,
        birthdayContactIdentifier: nil,
        attendeeCount: 0,
        attendees: [],
        organizer: nil
    )
}
