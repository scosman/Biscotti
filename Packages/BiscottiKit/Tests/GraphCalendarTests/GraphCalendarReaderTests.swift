import Calendar
import Foundation
import Testing
@testable import GraphCalendar

/// `GraphCalendarReader` over the fake transport: account, calendars, the
/// multi-calendar event read and single-event refresh.
@Suite("GraphCalendarReader")
struct GraphCalendarReaderTests {
    private func makeReader(_ transport: FakeGraphTransport) throws -> GraphCalendarReader {
        try GraphCalendarReader(client: makeClient(transport), localTimeZone: zone("America/Los_Angeles"))
    }

    @Test("account comes from /me")
    func account() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me", .fixture("me"))
        let account = try await makeReader(transport).account()

        #expect(account == TestAccount.jane)
        #expect(account.sourceTitle == "Microsoft 365 (jane@synderys.com)")
    }

    @Test("calendars are mapped for the account")
    func calendars() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars", .fixture("calendars"))
        let calendars = try await makeReader(transport).calendars(for: TestAccount.jane)

        #expect(calendars.map(\.title) == ["Calendar", "Project X", "Calendar (Pat Smith)", "Calendar (lee@partner.example)"])
    }

    @Test("events from all calendars, sorted; unreadable calendars and bad events skipped")
    func eventsAcrossCalendars() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars/cal-own/calendarView", .fixture("calendarView_week"))
        try await transport.stub("/v1.0/me/calendars/cal-project/calendarView", .fixture("calendarView_early"))
        try await transport.stub("/v1.0/me/calendars/cal-shared/calendarView", .fixture("error_403", status: 403))
        try await transport.stub("/v1.0/me/calendars/cal-partner/calendarView", .fixture("error_404", status: 404))
        let calendars = [
            TestAccount.ownCalendar,
            TestAccount.calendar("cal-project", title: "Project X"),
            TestAccount.calendar("cal-shared", title: "Calendar (Pat Smith)"),
            TestAccount.calendar("cal-partner", title: "Calendar (lee@partner.example)")
        ]

        let events = try await makeReader(transport).events(in: testWeek, calendars: calendars, account: TestAccount.jane)

        // evt-bad-date is dropped; the all-day event sorts by its local
        // midnight (07:00 UTC).
        #expect(events.map(\.eventIdentifier) == [
            "evt-early", "evt-teams", "evt-cancelled", "evt-occ-2",
            "evt-zoom-body", "evt-exc", "evt-focus", "evt-allday"
        ])
        #expect(events.first?.calendarTitle == "Project X")
        #expect(events.dropFirst().allSatisfy { $0.calendarIdentifier == "cal-own" })
        #expect(await transport.requests.count == 4)
    }

    @Test("any other calendar error fails the read")
    func otherErrorsFail() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars/cal-own/calendarView", .fixture("calendarView_week"))
        await transport.stub("/v1.0/me/calendars/cal-project/calendarView", .status(500))
        let calendars = [TestAccount.ownCalendar, TestAccount.calendar("cal-project", title: "Project X")]

        await #expect(throws: GraphError.http(status: 500, code: nil, message: nil)) {
            try await makeReader(transport).events(in: testWeek, calendars: calendars, account: TestAccount.jane)
        }
    }

    @Test("no calendars means no requests")
    func noCalendars() async throws {
        let transport = FakeGraphTransport()
        let events = try await makeReader(transport).events(in: testWeek, calendars: [], account: TestAccount.jane)

        #expect(events.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test("refresh reads the event from its calendar; nil once deleted")
    func refresh() async throws {
        let transport = FakeGraphTransport()
        try await transport.stub("/v1.0/me/calendars/cal-own/events/evt-teams", .fixture("event_teams"))
        try await transport.stub("/v1.0/me/calendars/cal-own/events/evt-gone", .fixture("error_404", status: 404))
        let reader = try makeReader(transport)

        let refreshed = try await reader.event(id: "evt-teams", calendar: TestAccount.ownCalendar, account: TestAccount.jane)
        let deleted = try await reader.event(id: "evt-gone", calendar: TestAccount.ownCalendar, account: TestAccount.jane)

        #expect(refreshed?.title == "Q4 pipeline review")
        #expect(refreshed?.calendarIdentifier == "cal-own")
        #expect(deleted == nil)
    }
}
