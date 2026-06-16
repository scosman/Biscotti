import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Helpers

/// Fixed reference date for deterministic tests.
private let refDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Creates a CalendarEvent with a Zoom conference URL starting at `start`.
private func makeEvent(
    start: Date,
    end: Date? = nil,
    conferenceURL: URL? = URL(string: "https://us04web.zoom.us/j/12345678"),
    organizer: AttendeeInfo? = AttendeeInfo(name: "Alice", email: "alice@x.com"),
    attendees: [AttendeeInfo] = [
        AttendeeInfo(name: "Bob", email: "bob@x.com"),
        AttendeeInfo(name: "Carol", email: nil)
    ],
    notes: String? = "Discuss roadmap",
    location: String? = "Room 42"
) -> EKEventDTO {
    let endDate = end ?? start.addingTimeInterval(3600)
    return EKEventDTO(
        eventIdentifier: "evt-preview",
        calendarItemIdentifier: "ci-preview",
        calendarItemExternalIdentifier: "ext-preview",
        occurrenceDate: start,
        title: "Team Standup",
        startDate: start,
        endDate: endDate,
        isAllDay: false,
        location: location,
        url: conferenceURL,
        timeZone: "America/New_York",
        notes: notes,
        status: "confirmed",
        availability: "busy",
        calendarIdentifier: "cal-1",
        calendarTitle: "Work",
        calendarColorHex: "#0066CC",
        calendarSourceTitle: "iCloud",
        birthdayContactIdentifier: nil,
        attendeeCount: attendees.count + (organizer != nil ? 1 : 0),
        attendees: attendees.map { info in
            AttendeeDTO(
                name: info.name,
                participantURL: info.email.flatMap { URL(string: "mailto:\($0)") },
                isCurrentUser: false,
                role: "required",
                status: "accepted",
                type: "person"
            )
        },
        organizer: organizer.map { info in
            AttendeeDTO(
                name: info.name,
                participantURL: info.email.flatMap { URL(string: "mailto:\($0)") },
                isCurrentUser: false,
                role: "chair",
                status: "accepted",
                type: "person"
            )
        }
    )
}

/// Tracks URLs opened by the VM. Uses `@unchecked Sendable` (safe
/// because tests run single-threaded on `@MainActor`).
private final class URLTracker: @unchecked Sendable {
    var urls: [URL] = []
}

/// Tracks strings written to the clipboard by the VM.
private final class ClipboardTracker: @unchecked Sendable {
    var strings: [String] = []
}

/// Bundles the objects returned by `makeReadyVM`.
private struct ReadyVM {
    let viewModel: EventPreviewViewModel
    let fixture: CoreFixture
    let openedURLs: URLTracker
    let copiedStrings: ClipboardTracker
}

/// Creates a fully-wired fixture with the event refreshed and VM ready.
@MainActor
private func makeReadyVM(
    eventStart: Date,
    eventEnd: Date? = nil,
    conferenceURL: URL? = URL(string: "https://us04web.zoom.us/j/12345678"),
    organizer: AttendeeInfo? = AttendeeInfo(name: "Alice", email: "alice@x.com"),
    attendees: [AttendeeInfo] = [
        AttendeeInfo(name: "Bob", email: "bob@x.com"),
        AttendeeInfo(name: "Carol", email: nil)
    ],
    notes: String? = "Discuss roadmap",
    location: String? = "Room 42",
    currentDate: @escaping () -> Date = { refDate }
) async throws -> ReadyVM {
    let dto = makeEvent(
        start: eventStart,
        end: eventEnd,
        conferenceURL: conferenceURL,
        organizer: organizer,
        attendees: attendees,
        notes: notes,
        location: location
    )

    let fix = try makeCoreFixture(
        calendarEventDTOs: [dto],
        testName: "EventPreviewVMTests"
    )
    _ = try await fix.store.settings()

    let window = DateInterval(
        start: eventStart.addingTimeInterval(-86400),
        end: eventStart.addingTimeInterval(86400)
    )
    await fix.calendarService.refreshUpcoming(window: window)

    let eventKey = try #require(fix.calendarService.upcoming.first?.id)
    let urlTracker = URLTracker()
    let clipTracker = ClipboardTracker()

    let viewModel = EventPreviewViewModel(
        core: fix.core,
        eventKey: eventKey,
        currentDate: currentDate,
        urlOpener: { url in urlTracker.urls.append(url) },
        clipboardWriter: { text in clipTracker.strings.append(text) }
    )

    return ReadyVM(
        viewModel: viewModel,
        fixture: fix,
        openedURLs: urlTracker,
        copiedStrings: clipTracker
    )
}

// MARK: - Primary Action Tests

@Suite("EventPreviewViewModel -- primary action by conference URL")
struct EventPreviewActionTests {
    @Test("Join and Record when conference URL exists")
    @MainActor
    func primaryActionJoinAndRecordWithURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .joinAndRecord)
    }

    @Test("Record when no conference URL")
    @MainActor
    func primaryActionRecordWhenNoURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .record)
    }

    @Test("Record when no conference URL near start")
    @MainActor
    func primaryActionRecordWhenNoURLNearStart() async throws {
        let eventStart = refDate.addingTimeInterval(5 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .record)
    }
}

// MARK: - Prominence Window Tests

@Suite("EventPreviewViewModel -- prominence window (5 min before start to 5 min after end)")
struct EventPreviewProminenceTests {
    @Test("Not prominent when meeting is far in the future (30 min)")
    @MainActor
    func notProminentFarFuture() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == false)
    }

    @Test("Prominent when 5 min before start (exact boundary)")
    @MainActor
    func prominentAtFiveMinBefore() async throws {
        // Event starts in 5 min (exactly at the boundary)
        let eventStart = refDate.addingTimeInterval(5 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == true)
    }

    @Test("Not prominent at 5 min + 1 second before start")
    @MainActor
    func notProminentJustOutsideBefore() async throws {
        let eventStart = refDate.addingTimeInterval(5 * 60 + 1)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == false)
    }

    @Test("Prominent during meeting (midway through)")
    @MainActor
    func prominentDuringMeeting() async throws {
        // Event started 30 min ago, ends in 30 min (1h meeting)
        let eventStart = refDate.addingTimeInterval(-30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == true)
    }

    @Test("Prominent at event start")
    @MainActor
    func prominentAtStart() async throws {
        let eventStart = refDate
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == true)
    }

    @Test("Prominent at event end")
    @MainActor
    func prominentAtEnd() async throws {
        // Event started 1h ago (and default end = start+1h = refDate)
        let eventStart = refDate.addingTimeInterval(-3600)
        let eventEnd = refDate
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            eventEnd: eventEnd,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == true)
    }

    @Test("Prominent at 5 min after end (exact boundary)")
    @MainActor
    func prominentAtFiveMinAfterEnd() async throws {
        // Event: 2h ago to 1h5min ago. Now is exactly 5 min after end.
        let eventStart = refDate.addingTimeInterval(-2 * 3600)
        let eventEnd = refDate.addingTimeInterval(-5 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            eventEnd: eventEnd,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == true)
    }

    @Test("Not prominent at 5 min + 1 second after end")
    @MainActor
    func notProminentJustOutsideAfterEnd() async throws {
        // Event: 2h ago to (5min+1s) ago. Now is 1 second past the end window.
        let eventStart = refDate.addingTimeInterval(-2 * 3600)
        let eventEnd = refDate.addingTimeInterval(-5 * 60 - 1)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            eventEnd: eventEnd,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.isProminent == false)
    }
}

// MARK: - Show Copy Link Tests

@Suite("EventPreviewViewModel -- showCopyLink")
struct EventPreviewShowCopyLinkTests {
    @Test("Shows copy link when conference URL exists")
    @MainActor
    func showsCopyLinkWithURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.showCopyLink == true)
    }

    @Test("Hides copy link when no conference URL")
    @MainActor
    func hidesCopyLinkWithoutURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.showCopyLink == false)
    }
}

// MARK: - Action Side-Effect Tests

@Suite("EventPreviewViewModel -- action side effects")
struct EventPreviewActionSideEffectTests {
    @Test("Copy Link writes conference URL to clipboard")
    @MainActor
    func copyLinkWritesToClipboard() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        ready.viewModel.copyLink()

        #expect(ready.copiedStrings.strings.count == 1)
        #expect(ready.copiedStrings.strings.first?.contains("zoom.us") == true)
    }

    @Test("Copy Link does nothing when no conference URL")
    @MainActor
    func copyLinkNoOpWithoutURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        ready.viewModel.copyLink()

        #expect(ready.copiedStrings.strings.isEmpty)
    }

    @Test("Join and Record opens URL AND starts recording")
    @MainActor
    func joinAndRecordOpensURLAndStartsRecording() async throws {
        let eventStart = refDate.addingTimeInterval(10 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        await ready.viewModel.joinAndRecord()

        // URL was opened
        #expect(ready.openedURLs.urls.count == 1)
        #expect(ready.openedURLs.urls.first?.absoluteString.contains("zoom.us") == true)

        // Recording was started
        #expect(ready.fixture.core.recording.state.isRecording)
    }

    @Test("Start recording uses the event key")
    @MainActor
    func startRecordingUsesEventKey() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        await ready.viewModel.startRecording()

        #expect(ready.fixture.core.recording.state.isRecording)
    }

    @Test("Open in Calendar opens ical deep-link URL with event identifier")
    @MainActor
    func openInCalendarOpensURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        ready.viewModel.openInCalendar()

        #expect(ready.openedURLs.urls.count == 1)
        let url = try #require(ready.openedURLs.urls.first)
        // Must use ical:// scheme (not calshow:) matching MeetingDetailViewModel
        #expect(url.scheme == "ical")
        // Must contain the event identifier path
        #expect(url.absoluteString.contains("ekevent/"))
        // Must not contain a fractional ".0" — integer epoch only
        #expect(!url.absoluteString.contains(".0"))
    }
}

// MARK: - Event Details Tests

@Suite("EventPreviewViewModel -- event details exposed")
struct EventPreviewDetailsTests {
    @Test("Event exposes all details from enriched CalendarEvent")
    @MainActor
    func eventDetailsExposed() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            organizer: AttendeeInfo(name: "Alice", email: "alice@x.com"),
            attendees: [
                AttendeeInfo(name: "Bob", email: "bob@x.com"),
                AttendeeInfo(name: "Carol", email: nil)
            ],
            notes: "Discuss roadmap",
            location: "Room 42",
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        let event = try #require(ready.viewModel.event)

        // Core fields
        #expect(event.title == "Team Standup")
        #expect(event.calendarTitle == "Work")
        #expect(event.calendarColorHex == "#0066CC")
        #expect(event.conferencePlatform == "Zoom")
        #expect(event.conferenceURL?.absoluteString.contains("zoom.us") == true)

        // Enriched fields
        #expect(event.organizer?.name == "Alice")
        #expect(event.organizer?.email == "alice@x.com")
        #expect(event.attendees.count == 2)
        #expect(event.attendees[0].name == "Bob")
        #expect(event.attendees[0].email == "bob@x.com")
        #expect(event.attendees[1].name == "Carol")
        #expect(event.attendees[1].email == nil)
        #expect(event.notes == "Discuss roadmap")
        #expect(event.location == "Room 42")
    }

    @Test("Event with no organizer/notes/location shows minimal details")
    @MainActor
    func eventMinimalDetails() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        // Must have >=2 attendees or a conference URL to be "meeting-like";
        // use 2 bare attendees so the event passes the filter without a URL.
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            organizer: nil,
            attendees: [
                AttendeeInfo(name: "A", email: nil),
                AttendeeInfo(name: "B", email: nil)
            ],
            notes: nil,
            location: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        let event = try #require(ready.viewModel.event)
        #expect(event.organizer == nil)
        #expect(event.notes == nil)
        #expect(event.location == nil)
        #expect(event.conferenceURL == nil)
    }

    @Test("AttendeeInfo displayName prefers name over email")
    func attendeeDisplayNamePrefersName() {
        let info = AttendeeInfo(name: "Alice", email: "alice@x.com")
        #expect(info.displayName == "Alice")
    }

    @Test("AttendeeInfo displayName falls back to email")
    func attendeeDisplayNameFallsToEmail() {
        let info = AttendeeInfo(name: nil, email: "alice@x.com")
        #expect(info.displayName == "alice@x.com")
    }

    @Test("AttendeeInfo displayName falls back to Unknown")
    func attendeeDisplayNameFallsToUnknown() {
        let info = AttendeeInfo(name: nil, email: nil)
        #expect(info.displayName == "Unknown")
    }

    @Test("AttendeeInfo displayName treats empty name as missing")
    func attendeeDisplayNameEmptyName() {
        let info = AttendeeInfo(name: "", email: "bob@x.com")
        #expect(info.displayName == "bob@x.com")
    }

    @Test("Event not found returns nil")
    @MainActor
    func eventNotFound() throws {
        let fix = try makeCoreFixture(testName: "EventPreview")
        defer { fix.cleanup() }

        let viewModel = EventPreviewViewModel(
            core: fix.core,
            eventKey: "nonexistent-key"
        )

        #expect(viewModel.event == nil)
        #expect(viewModel.primaryAction == .record)
    }
}

// MARK: - Avatar Data Tests

@Suite("EventPreviewViewModel -- avatar data")
struct EventPreviewAvatarTests {
    @Test("Avatar data includes organizer and attendees")
    @MainActor
    func avatarDataIncludesAll() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            organizer: AttendeeInfo(name: "Alice", email: "alice@x.com"),
            attendees: [
                AttendeeInfo(name: "Bob", email: "bob@x.com"),
                AttendeeInfo(name: "Carol", email: nil)
            ],
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        let data = ready.viewModel.avatarData
        #expect(data.people.count == 3) // Alice + Bob + Carol
        #expect(data.total == 3) // attendeeCount = 3 (2 attendees + 1 organizer)
        #expect(data.people[0].displayName == "Alice")
        #expect(data.people[1].displayName == "Bob")
    }

    @Test("Avatar data empty when no event")
    @MainActor
    func avatarDataEmptyWhenNoEvent() throws {
        let fix = try makeCoreFixture(testName: "EventPreviewAvatar")
        defer { fix.cleanup() }

        let viewModel = EventPreviewViewModel(
            core: fix.core,
            eventKey: "nonexistent-key"
        )

        let data = viewModel.avatarData
        #expect(data.people.isEmpty)
        #expect(data.total == 0)
    }
}

// MARK: - Attendee Email Lines Tests

@Suite("EventPreviewViewModel -- attendeeEmailLines")
struct EventPreviewAttendeeEmailTests {
    @Test("Email lines use email when available, organizer first with suffix")
    @MainActor
    func emailLinesWithOrganizer() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            organizer: AttendeeInfo(name: "Alice", email: "alice@x.com"),
            attendees: [
                AttendeeInfo(name: "Bob", email: "bob@x.com"),
                AttendeeInfo(name: "Carol", email: nil)
            ],
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        let lines = ready.viewModel.attendeeEmailLines
        #expect(lines.count == 3)
        #expect(lines[0] == "alice@x.com (organizer)")
        #expect(lines[1] == "bob@x.com")
        // Carol has no email, falls back to displayName
        #expect(lines[2] == "Carol")
    }

    @Test("Email lines without organizer")
    @MainActor
    func emailLinesWithoutOrganizer() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            organizer: nil,
            attendees: [
                AttendeeInfo(name: "A", email: "a@test.com"),
                AttendeeInfo(name: "B", email: nil)
            ],
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        let lines = ready.viewModel.attendeeEmailLines
        #expect(lines.count == 2)
        #expect(lines[0] == "a@test.com")
        #expect(lines[1] == "B")
    }

    @Test("Email lines empty when no event")
    @MainActor
    func emailLinesEmptyWhenNoEvent() throws {
        let fix = try makeCoreFixture(testName: "EventPreviewEmails")
        defer { fix.cleanup() }

        let viewModel = EventPreviewViewModel(
            core: fix.core,
            eventKey: "nonexistent-key"
        )

        #expect(viewModel.attendeeEmailLines.isEmpty)
    }
}

// MARK: - Domain Summary Tests

@Suite("EventPreviewViewModel -- domainSummary")
struct EventPreviewDomainSummaryTests {
    @Test("Domain summary nil with single domain")
    @MainActor
    func singleDomainReturnsNil() {
        let lines = [
            "alice@waldo.fyi (organizer)",
            "bob@waldo.fyi",
            "carol@waldo.fyi"
        ]
        let result = EventPreviewViewModel.buildDomainSummary(for: lines)
        #expect(result == nil)
    }

    @Test("Domain summary nil with no email domains")
    @MainActor
    func noDomainsReturnsNil() {
        let lines = ["Alice", "Bob", "Carol"]
        let result = EventPreviewViewModel.buildDomainSummary(for: lines)
        #expect(result == nil)
    }

    @Test("Domain summary shows multiple domains sorted by count")
    @MainActor
    func multipleDomainsShowsSorted() throws {
        let lines = [
            "a@waldo.fyi (organizer)",
            "b@waldo.fyi",
            "c@waldo.fyi",
            "d@kiln.tech",
            "e@kiln.tech",
            "f@other.io"
        ]
        let result = EventPreviewViewModel.buildDomainSummary(for: lines)
        #expect(result != nil)
        // waldo.fyi(3) > kiln.tech(2) > other.io(1)
        #expect(try #require(result?.contains("3 from waldo.fyi")))
        #expect(try #require(result?.contains("2 from kiln.tech")))
        #expect(try #require(result?.contains("1 from other.io")))
    }

    @Test("Domain summary strips organizer suffix before parsing")
    @MainActor
    func stripsOrganizerSuffix() throws {
        let lines = [
            "alice@a.com (organizer)",
            "bob@b.com"
        ]
        let result = EventPreviewViewModel.buildDomainSummary(for: lines)
        #expect(result != nil)
        #expect(try #require(result?.contains("a.com")))
        #expect(try #require(result?.contains("b.com")))
    }

    @Test("Domain summary with empty lines")
    @MainActor
    func emptyLinesReturnsNil() {
        let result = EventPreviewViewModel.buildDomainSummary(for: [])
        #expect(result == nil)
    }

    @Test("Domain summary is case-insensitive")
    @MainActor
    func caseInsensitive() throws {
        let lines = [
            "a@Waldo.FYI (organizer)",
            "b@waldo.fyi",
            "c@other.com"
        ]
        let result = EventPreviewViewModel.buildDomainSummary(for: lines)
        #expect(result != nil)
        #expect(try #require(result?.contains("2 from waldo.fyi")))
        #expect(try #require(result?.contains("1 from other.com")))
    }
}

// MARK: - Display Helper Tests

@Suite("EventPreviewViewModel -- display helpers")
struct EventPreviewDisplayTests {
    @Test("Relative time text shows countdown")
    @MainActor
    func relativeTimeText() async throws {
        let eventStart = refDate.addingTimeInterval(12 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.relativeTimeText == "in 12m")
    }

    @Test("Formatted duration for 1h meeting")
    @MainActor
    func formattedDuration() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        // Default end = start + 1h
        #expect(ready.viewModel.formattedDuration == "1h")
    }

    @Test("Formatted date range is non-nil")
    @MainActor
    func formattedDateRange() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.formattedDateRange != nil)
    }
}

// MARK: - Platform Display Name Tests (BundledMeetingCatalog)

@Suite("BundledMeetingCatalog -- human-friendly platform names")
struct PlatformDisplayNameTests {
    @Test("Google Meet link returns 'Google Meet' platform")
    @MainActor
    func googleMeetPlatformName() async throws {
        let dto = makeEvent(
            start: refDate.addingTimeInterval(3600),
            conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "PlatformNames"
        )
        defer { fix.cleanup() }
        _ = try await fix.store.settings()

        let window = DateInterval(
            start: refDate,
            end: refDate.addingTimeInterval(86400)
        )
        await fix.calendarService.refreshUpcoming(window: window)

        let event = try #require(fix.calendarService.upcoming.first)
        #expect(event.conferencePlatform == "Google Meet")
    }

    @Test("Zoom link returns 'Zoom' platform")
    @MainActor
    func zoomPlatformName() async throws {
        let dto = makeEvent(
            start: refDate.addingTimeInterval(3600),
            conferenceURL: URL(string: "https://us04web.zoom.us/j/12345678")
        )
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "PlatformNames"
        )
        defer { fix.cleanup() }
        _ = try await fix.store.settings()

        let window = DateInterval(
            start: refDate,
            end: refDate.addingTimeInterval(86400)
        )
        await fix.calendarService.refreshUpcoming(window: window)

        let event = try #require(fix.calendarService.upcoming.first)
        #expect(event.conferencePlatform == "Zoom")
    }
}
