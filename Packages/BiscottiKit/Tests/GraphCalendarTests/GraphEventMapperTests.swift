import Calendar
import Foundation
import Testing
@testable import GraphCalendar

/// Graph event → `EKEventDTO` mapping, fixture by fixture. The field
/// mapping is `specs/projects/o365_calendar/functional_spec.md` §4.
@Suite("GraphEventMapper")
struct GraphEventMapperTests {
    private static let teamsJoin = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NTk3ZGE4%40thread.v2/0?context=%7b%22Tid%22%3a%22t-1%22%2c%22Oid%22%3a%22o-1%22%7d"

    private func mapper(_ zoneID: String = "America/Los_Angeles", notesLimit: Int = HTMLText.defaultLimit) throws -> GraphEventMapper {
        try GraphEventMapper(account: TestAccount.jane, localTimeZone: zone(zoneID), notesLimit: notesLimit)
    }

    private func map(_ id: String, zoneID: String = "America/Los_Angeles") throws -> EKEventDTO {
        try mapper(zoneID).event(Fixture.event("calendarView_week", id: id), calendar: TestAccount.ownCalendar)
    }

    private func decodeEvent(_ json: String) throws -> Graph.Event {
        try JSONDecoder().decode(Graph.Event.self, from: Data(json.utf8))
    }

    // MARK: - Meetings

    @Test("Teams meeting: join URL, times, zone, notes and calendar")
    func teamsMeeting() throws {
        let dto = try map("evt-teams")

        #expect(dto.eventIdentifier == "evt-teams")
        #expect(dto.calendarItemIdentifier == "evt-teams")
        #expect(dto.calendarItemExternalIdentifier.hasPrefix("040000008200E00074C5B7101A82E008"))
        #expect(dto.title == "Q4 pipeline review")
        #expect(try dto.startDate == instant("2026-10-27T16:00:00Z"))
        #expect(try dto.endDate == instant("2026-10-27T17:00:00Z"))
        #expect(dto.occurrenceDate == dto.startDate)
        #expect(dto.isAllDay == false)
        #expect(dto.timeZone == "America/Los_Angeles")
        #expect(dto.location == "Microsoft Teams Meeting")
        #expect(dto.url?.absoluteString == Self.teamsJoin)
        #expect(dto.status == "accepted")
        #expect(dto.availability == "busy")
        #expect(dto.calendarIdentifier == "cal-own")
        #expect(dto.calendarTitle == "Calendar")
        #expect(dto.calendarColorHex == "#808080")
        #expect(dto.calendarSourceTitle == "Microsoft 365 (jane@synderys.com)")
        #expect(dto.birthdayContactIdentifier == nil)

        let notes = try #require(dto.notes)
        #expect(notes.hasPrefix("Agenda:\n\n- Pipeline by stage\n- Forecast & risks\n"))
        #expect(notes.contains("Click here to join the meeting \(Self.teamsJoin)\n"))
        #expect(notes.contains("Meeting ID: 255 123 456 789"))
        #expect(!notes.contains("<"))
        #expect(!notes.contains("margin"))
    }

    @Test("Teams meeting: attendees, organizer and count")
    func teamsParticipants() throws {
        let dto = try map("evt-teams")

        #expect(dto.attendees.map(\.name) == ["Jane Doe", "Pat Smith", "Lee Wong", "Conf Room 4"])
        #expect(dto.attendees.map(\.role) == ["required", "required", "optional", "nonParticipant"])
        #expect(dto.attendees.map(\.status) == ["accepted", "tentative", "pending", "accepted"])
        #expect(dto.attendees.map(\.type) == ["person", "person", "person", "resource"])
        // Matched against the account's mail, case-insensitively.
        #expect(dto.attendees.map(\.isCurrentUser) == [true, false, false, false])
        #expect(dto.attendees.first?.participantURL?.absoluteString == "mailto:JANE.DOE@synderys.com")

        let organizer = try #require(dto.organizer)
        #expect(organizer == AttendeeDTO(
            name: "Sam Lee", participantURL: URL(string: "mailto:sam@synderys.com"), isCurrentUser: false,
            role: "chair", status: "accepted", type: "person"
        ))
        // Four invitees plus the organizer, who Graph does not list.
        #expect(dto.attendeeCount == 5)
    }

    @Test("an organizer who is also listed is counted once")
    func listedOrganizerCountedOnce() throws {
        let dto = try map("evt-zoom-body")
        #expect(dto.attendees.count == 3)
        #expect(dto.attendeeCount == 3)
    }

    @Test("an attendee with no name or address maps to nils")
    func emptyAttendee() throws {
        let attendee = try #require(try map("evt-zoom-body").attendees.last)
        #expect(attendee == AttendeeDTO(
            name: nil, participantURL: nil, isCurrentUser: false, role: "optional", status: "unknown", type: "person"
        ))
    }

    @Test("join link found only in an HTML body href")
    func joinLinkInBody() throws {
        let dto = try map("evt-zoom-body")

        #expect(dto.url?.absoluteString == "https://us02web.zoom.us/j/85512345678?pwd=abcDEF123")
        #expect(dto.location == nil, "a blank location maps to nil")
        #expect(dto.notes == """
        Hi all,

        Let’s review & plan.

        Join Zoom Meeting https://us02web.zoom.us/j/85512345678?pwd=abcDEF123

        Meeting ID: 855 1234 5678
        """)
        #expect(dto.status == "tentativelyAccepted")
        #expect(dto.availability == "tentative")
    }

    @Test("a join link past the notes cap is still found")
    func joinLinkPastNotesCap() throws {
        let filler = String(repeating: "word ", count: 100)
        let event = try decodeEvent("""
        {
          "id": "evt-long",
          "start": { "dateTime": "2026-10-27T16:00:00.0000000", "timeZone": "UTC" },
          "end": { "dateTime": "2026-10-27T17:00:00.0000000", "timeZone": "UTC" },
          "body": { "contentType": "text", "content": "\(filler)https://teams.microsoft.com/l/meetup-join/abc" }
        }
        """)
        let dto = try mapper(notesLimit: 100).event(event, calendar: TestAccount.ownCalendar)

        #expect(dto.url?.absoluteString == "https://teams.microsoft.com/l/meetup-join/abc")
        let notes = try #require(dto.notes)
        #expect(notes.count == 100)
        #expect(notes.hasSuffix("…"))
    }

    @Test("non-web join URLs are ignored; the legacy onlineMeetingUrl is used")
    func joinURLSources() throws {
        let telOnly = try decodeEvent("""
        {
          "id": "evt-tel",
          "start": { "dateTime": "2026-10-27T16:00:00", "timeZone": "UTC" },
          "end": { "dateTime": "2026-10-27T17:00:00", "timeZone": "UTC" },
          "onlineMeeting": { "joinUrl": "tel:+15551234567" }
        }
        """)
        let legacy = try decodeEvent("""
        {
          "id": "evt-legacy",
          "start": { "dateTime": "2026-10-27T16:00:00", "timeZone": "UTC" },
          "end": { "dateTime": "2026-10-27T17:00:00", "timeZone": "UTC" },
          "onlineMeeting": null,
          "onlineMeetingUrl": "https://meet.lync.com/synderys/jane/ABC123"
        }
        """)
        let sut = try mapper()

        #expect(try sut.event(telOnly, calendar: TestAccount.ownCalendar).url == nil)
        #expect(
            try sut.event(legacy, calendar: TestAccount.ownCalendar).url?.absoluteString
                == "https://meet.lync.com/synderys/jane/ABC123"
        )
    }

    // MARK: - Recurrence

    @Test("an occurrence keys on its series and its own instance id")
    func recurringOccurrence() throws {
        let dto = try map("evt-occ-2")

        #expect(dto.eventIdentifier == "evt-occ-2")
        #expect(dto.calendarItemIdentifier == "series-standup")
        #expect(try dto.occurrenceDate == instant("2026-10-28T15:30:00Z"))
        #expect(dto.occurrenceDate == dto.startDate)
        #expect(dto.timeZone == "America/New_York")
        #expect(dto.status == "organizer")
        #expect(dto.notes == "Standup notes:\nhttps://example.com/standup")
        #expect(dto.url == nil, "a plain link is not a conference link")
        #expect(dto.organizer?.isCurrentUser == true)
        #expect(dto.attendees.map(\.status) == ["accepted", "declined"])
        #expect(dto.attendeeCount == 3)
    }

    @Test("a moved occurrence keeps its original start as occurrenceDate")
    func movedOccurrence() throws {
        let dto = try map("evt-exc")

        #expect(dto.calendarItemIdentifier == "series-standup")
        #expect(try dto.startDate == instant("2026-10-29T17:00:00Z"))
        #expect(try dto.occurrenceDate == instant("2026-10-29T15:30:00Z"))
        #expect(dto.notes == nil, "an empty body maps to nil")
    }

    // MARK: - All-day, cancelled, appointments

    @Test("all-day events are local midnights with no zone", arguments: [
        ("America/Los_Angeles", "2026-10-30T00:00:00-07:00", "2026-10-31T00:00:00-07:00"),
        ("Europe/Berlin", "2026-10-30T00:00:00+01:00", "2026-10-31T00:00:00+01:00")
    ])
    func allDay(zoneID: String, start: String, end: String) throws {
        let dto = try map("evt-allday", zoneID: zoneID)

        #expect(dto.isAllDay)
        #expect(try dto.startDate == instant(start))
        #expect(try dto.endDate == instant(end))
        #expect(dto.occurrenceDate == dto.startDate)
        #expect(dto.timeZone == nil)
        #expect(dto.availability == "oof")
        #expect(dto.attendeeCount == 0)
    }

    @Test("an all-day event sent as a UTC instant keeps the organizer's day")
    func allDayConvertedToUTC() throws {
        // Sydney midnight on Oct 30 is 13:00 UTC on Oct 29.
        let event = try decodeEvent("""
        {
          "id": "evt-allday-syd",
          "isAllDay": true,
          "originalStartTimeZone": "AUS Eastern Standard Time",
          "start": { "dateTime": "2026-10-29T13:00:00.0000000", "timeZone": "UTC" },
          "end": { "dateTime": "2026-10-30T13:00:00.0000000", "timeZone": "UTC" }
        }
        """)
        let dto = try mapper().event(event, calendar: TestAccount.ownCalendar)

        #expect(try dto.startDate == instant("2026-10-30T00:00:00-07:00"))
        #expect(try dto.endDate == instant("2026-10-31T00:00:00-07:00"))
    }

    @Test("a cancelled meeting reads as canceled")
    func cancelled() throws {
        let dto = try map("evt-cancelled")

        #expect(dto.status == "canceled")
        #expect(dto.availability == "free")
        // Matched against the account's UPN.
        #expect(dto.attendees.first?.isCurrentUser == true)
        #expect(dto.attendees.first?.status == "unknown")
        #expect(dto.attendeeCount == 2)
    }

    @Test("a personal appointment has no attendees and counts 0")
    func organizerOnly() throws {
        let dto = try map("evt-focus")

        #expect(dto.attendees.isEmpty)
        #expect(dto.attendeeCount == 0)
        #expect(dto.organizer?.isCurrentUser == true)
        #expect(dto.notes == nil)
        #expect(dto.url == nil)
        #expect(dto.timeZone == nil, "a custom Outlook zone has no IANA identifier")
    }

    // MARK: - Dates and zones

    @Test("an impossible date throws")
    func impossibleDateThrows() throws {
        let event = try Fixture.event("calendarView_week", id: "evt-bad-date")
        #expect(throws: GraphMappingError.invalidDateTime("2026-02-30T10:00:00.0000000")) {
            try mapper().event(event, calendar: TestAccount.ownCalendar)
        }
    }

    @Test("an unknown start zone throws")
    func unknownZoneThrows() throws {
        let event = try decodeEvent("""
        {
          "id": "evt-mars",
          "start": { "dateTime": "2026-10-27T16:00:00", "timeZone": "Mars Standard Time" },
          "end": { "dateTime": "2026-10-27T17:00:00", "timeZone": "Mars Standard Time" }
        }
        """)
        #expect(throws: GraphMappingError.unknownTimeZone("Mars Standard Time")) {
            try mapper().event(event, calendar: TestAccount.ownCalendar)
        }
    }

    @Test("start/end in a Windows zone (no Prefer header) resolve to the right instant")
    func windowsZoneTimes() throws {
        let event = try decodeEvent("""
        {
          "id": "evt-est",
          "start": { "dateTime": "2026-10-29T13:00:00.0000000", "timeZone": "Eastern Standard Time" },
          "end": { "dateTime": "2026-10-29T14:00:00.0000000", "timeZone": "Eastern Standard Time" }
        }
        """)
        let dto = try mapper().event(event, calendar: TestAccount.ownCalendar)

        #expect(try dto.startDate == instant("2026-10-29T17:00:00Z"))
        #expect(try dto.endDate == instant("2026-10-29T18:00:00Z"))
    }
}
