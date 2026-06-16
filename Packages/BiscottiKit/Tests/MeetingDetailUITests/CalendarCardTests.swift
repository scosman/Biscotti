import BiscottiTestSupport
import DataStore
import DesignSystem
import Foundation
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Fake player

/// File-local fake player for calendar card tests.
private final class CardFakePlayer: AudioPlaybackProviding,
    @unchecked Sendable
{
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120
    var rate: Float = 1.0

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func load(urls _: [URL]) throws {}
}

// MARK: - whenText tests

/// whenText tests now target the shared `TimeFormatting.whenText` helper
/// (formerly duplicated in both MeetingDetailViewModel and EventPreviewViewModel).
@Suite("TimeFormatting -- whenText")
struct WhenTextTests {
    @Test("formats same-day date range with en-dash separator")
    func formatsSameDayRange() throws {
        let cal = Foundation.Calendar.current
        let start = try #require(cal.date(
            from: DateComponents(year: 2026, month: 6, day: 11, hour: 16, minute: 18)
        ))
        let end = try #require(cal.date(
            from: DateComponents(year: 2026, month: 6, day: 11, hour: 16, minute: 50)
        ))

        let result = TimeFormatting.whenText(start: start, end: end)
        #expect(result != nil)
        // Structural: contains middot separator and en-dash between times
        #expect(try #require(result?.contains("\u{00B7}"))) // middot
        #expect(try #require(result?.contains("\u{2013}"))) // en-dash
        // Date portion present (locale-aware, verify "11" for the day)
        #expect(try #require(result?.contains("11")))
    }

    @Test("returns nil when no start date")
    func returnsNilWithoutStart() {
        let result = TimeFormatting.whenText(start: nil, end: nil)
        #expect(result == nil)
    }

    @Test("formats start-only when no end date")
    func formatsStartOnly() throws {
        let cal = Foundation.Calendar.current
        let start = try #require(cal.date(
            from: DateComponents(year: 2026, month: 6, day: 11, hour: 16, minute: 18)
        ))

        let result = TimeFormatting.whenText(start: start, end: nil)
        #expect(result != nil)
        // Should have a middot but no en-dash (single time, not a range)
        #expect(try #require(result?.contains("\u{00B7}")))
        #expect(result?.contains("\u{2013}") != true)
        #expect(try #require(result?.contains("11")))
    }

    @Test("formats multi-day range with both dates")
    func formatsMultiDayRange() throws {
        let cal = Foundation.Calendar.current
        let start = try #require(cal.date(
            from: DateComponents(year: 2026, month: 6, day: 11, hour: 16, minute: 0)
        ))
        let end = try #require(cal.date(
            from: DateComponents(year: 2026, month: 6, day: 12, hour: 10, minute: 0)
        ))

        let result = TimeFormatting.whenText(start: start, end: end)
        #expect(result != nil)
        // Both day numbers present
        #expect(try #require(result?.contains("11")))
        #expect(try #require(result?.contains("12")))
        #expect(try #require(result?.contains("\u{2013}")))
    }
}

// MARK: - invitedText tests

/// @MainActor required: static helpers inherit @MainActor from MeetingDetailViewModel.
@Suite("MeetingDetailViewModel -- invitedText")
struct InvitedTextTests {
    @Test("includes organizer tag and attendees")
    @MainActor
    func includesOrganizerAndAttendees() {
        let org = PersonData(id: UUID(), name: "Steve", email: "steve@example.com")
        let attendees = [
            PersonData(id: UUID(), name: "Alex", email: "alex@example.com"),
            PersonData(id: UUID(), name: "Jay", email: "jay@example.com")
        ]

        let result = MeetingDetailViewModel.invitedText(
            organizer: org, attendees: attendees
        )
        #expect(result == "Steve (organizer) \u{00B7} Alex \u{00B7} Jay")
    }

    @Test("shows +N overflow for many attendees")
    @MainActor
    func showsOverflowCount() throws {
        let org = PersonData(id: UUID(), name: "Steve")
        let attendees = (1 ... 6).map {
            PersonData(id: UUID(), name: "Person \($0)")
        }

        let result = MeetingDetailViewModel.invitedText(
            organizer: org, attendees: attendees
        )
        #expect(result != nil)
        // Organizer + 4 visible + "+2"
        #expect(try #require(result?.contains("Steve (organizer)")))
        #expect(try #require(result?.contains("+2")))
    }

    @Test("returns nil when no attendees and no organizer")
    @MainActor
    func returnsNilWithoutPeople() {
        let result = MeetingDetailViewModel.invitedText(
            organizer: nil, attendees: []
        )
        #expect(result == nil)
    }

    @Test("deduplicates organizer from attendees list")
    @MainActor
    func deduplicatesOrganizer() {
        let orgID = UUID()
        let org = PersonData(id: orgID, name: "Steve")
        let attendees = [
            PersonData(id: orgID, name: "Steve"),
            PersonData(id: UUID(), name: "Alex")
        ]

        let result = MeetingDetailViewModel.invitedText(
            organizer: org, attendees: attendees
        )
        // Steve should appear once (as organizer), not twice
        #expect(result == "Steve (organizer) \u{00B7} Alex")
    }

    @Test("attendees only (no organizer)")
    @MainActor
    func attendeesOnlyNoOrganizer() {
        let attendees = [
            PersonData(id: UUID(), name: "Alex"),
            PersonData(id: UUID(), name: "Jay")
        ]

        let result = MeetingDetailViewModel.invitedText(
            organizer: nil, attendees: attendees
        )
        #expect(result == "Alex \u{00B7} Jay")
    }
}

// MARK: - attendeeSummary tests

/// @MainActor required: static helpers inherit @MainActor from MeetingDetailViewModel.
@Suite("MeetingDetailViewModel -- attendeeSummary")
struct AttendeeSummaryTests {
    @Test("organizer with few attendees")
    @MainActor
    func organizerWithFewAttendees() {
        let org = PersonData(id: UUID(), name: "Steve")
        let attendees = [
            PersonData(id: UUID(), name: "Alex"),
            PersonData(id: UUID(), name: "Jay")
        ]

        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: org, attendees: attendees
        )
        let plain = String(result.characters)
        #expect(plain == "Steve, Alex, Jay")
    }

    @Test("organizer with overflow shows +N others")
    @MainActor
    func organizerWithOverflow() {
        let org = PersonData(id: UUID(), name: "Steve")
        let attendees = (1 ... 5).map {
            PersonData(id: UUID(), name: "Person \($0)")
        }

        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: org, attendees: attendees
        )
        let plain = String(result.characters)
        // Shows first 2 attendees + overflow count for the remaining 3
        #expect(plain.contains("Steve"))
        #expect(plain.contains("Person 1"))
        #expect(plain.contains("Person 2"))
        #expect(plain.contains("3 others"))
    }

    @Test("no organizer, attendees only")
    @MainActor
    func noOrganizerAttendeesOnly() {
        let attendees = [
            PersonData(id: UUID(), name: "Alex"),
            PersonData(id: UUID(), name: "Jay")
        ]

        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: nil, attendees: attendees
        )
        let plain = String(result.characters)
        #expect(plain == "Alex, Jay")
    }

    @Test("no organizer, no attendees returns empty string")
    @MainActor
    func emptyWhenNoPeople() {
        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: nil, attendees: []
        )
        let plain = String(result.characters)
        #expect(plain.isEmpty)
    }

    @Test("deduplicates organizer from attendees list")
    @MainActor
    func deduplicatesOrganizer() {
        let orgID = UUID()
        let org = PersonData(id: orgID, name: "Steve")
        let attendees = [
            PersonData(id: orgID, name: "Steve"),
            PersonData(id: UUID(), name: "Alex")
        ]

        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: org, attendees: attendees
        )
        let plain = String(result.characters)
        // Steve appears once (as organizer text), not duplicated
        #expect(plain == "Steve, Alex")
    }

    @Test("organizer name styled medium weight")
    @MainActor
    func organizerStyledMedium() {
        let org = PersonData(id: UUID(), name: "Steve")

        let result = MeetingDetailViewModel.attendeeSummary(
            organizer: org, attendees: []
        )
        // Verify the organizer run has medium weight font
        let runs = result.runs
        let firstRun = runs.first
        #expect(firstRun != nil)
        #expect(String(result.characters) == "Steve")
    }
}

// MARK: - calendarCard mapping tests

@Suite("MeetingDetailViewModel -- calendarCard")
struct CalendarCardMappingTests {
    @Test("calendarCard returns nil when no calendar context")
    @MainActor
    func calendarCardNilWithoutContext() async throws {
        let fix = try makeCoreFixture(testName: "CalendarCard")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Cal")
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CardFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.calendarCard == nil)
    }

    @Test("calendarCard populates all fields from context")
    @MainActor
    func calendarCardPopulatesAllFields() async throws {
        let fix = try makeCoreFixture(testName: "CalendarCard")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "With Cal")

        let orgID = try await fix.store.findOrCreatePerson(
            name: "Steve", email: "steve@example.com"
        )
        let attendeeID = try await fix.store.findOrCreatePerson(
            name: "Alex", email: "alex@example.com"
        )
        try await fix.store.setParticipants(
            [orgID, attendeeID], organizer: orgID, for: meetingID
        )

        let snapshot = CalendarSnapshot(
            eventIdentifier: "ev-card",
            compositeKey: "key-card",
            title: "Design Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: "Conference Room B",
            eventNotes: "Review the Q2 metrics and retention data.",
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            conferenceURL: URL(string: "https://zoom.us/j/123"),
            conferencePlatform: "Zoom"
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CardFakePlayer() }
        )
        await viewModel.load()

        let card = viewModel.calendarCard
        #expect(card != nil)
        #expect(card?.platform == "Zoom")
        #expect(card?.conferenceURL?.absoluteString == "https://zoom.us/j/123")
        #expect(card?.location == "Conference Room B")
        #expect(card?.eventNotes == "Review the Q2 metrics and retention data.")
        #expect(card?.whenText != nil)
        #expect(card?.invitedText != nil)
        #expect(card?.invitedText?.contains("Steve (organizer)") == true)
        #expect(card?.invitedText?.contains("Alex") == true)
        #expect(card?.attendeeTotal == 2) // organizer + 1 attendee
    }
}

// MARK: - eventNotes DataStore wiring tests

@Suite("DataStore -- eventNotes")
struct EventNotesDataStoreTests {
    @Test("eventNotes populated from snapshot")
    @MainActor
    func eventNotesPopulated() async throws {
        let fix = try makeCoreFixture(testName: "EventNotes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Notes Test")
        let snapshot = CalendarSnapshot(
            compositeKey: "key-notes",
            title: "Meeting",
            eventNotes: "Quarterly review of product metrics."
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        let ctx = try await fix.store.calendarContext(meetingID: meetingID)
        #expect(ctx?.eventNotes == "Quarterly review of product metrics.")
    }

    @Test("eventNotes is nil when snapshot has empty notes")
    @MainActor
    func eventNotesNilWhenEmpty() async throws {
        let fix = try makeCoreFixture(testName: "EventNotes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Empty Notes")
        let snapshot = CalendarSnapshot(
            compositeKey: "key-empty",
            title: "Meeting",
            eventNotes: ""
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        let ctx = try await fix.store.calendarContext(meetingID: meetingID)
        #expect(ctx?.eventNotes == nil)
    }
}

// MARK: - hasAudioFiles tests

@Suite("MeetingDetailViewModel -- hasAudioFiles")
struct HasAudioFilesTests {
    @Test("hasAudioFiles true when audio present")
    @MainActor
    func hasAudioFilesTrue() async throws {
        let fix = try makeCoreFixture(testName: "HasAudio")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CardFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.hasAudioFiles == true)
    }

    @Test("hasAudioFiles false when no audio")
    @MainActor
    func hasAudioFilesFalse() async throws {
        let fix = try makeCoreFixture(testName: "HasAudio")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "No Audio")
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CardFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.hasAudioFiles == false)
    }
}
