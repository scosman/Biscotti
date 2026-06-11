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

/// Bundles the three objects returned by `makeReadyVM`.
private struct ReadyVM {
    let viewModel: EventPreviewViewModel
    let fixture: CoreFixture
    let openedURLs: URLTracker
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
    let tracker = URLTracker()

    let viewModel = EventPreviewViewModel(
        core: fix.core,
        eventKey: eventKey,
        currentDate: currentDate,
        urlOpener: { url in tracker.urls.append(url) }
    )

    return ReadyVM(viewModel: viewModel, fixture: fix, openedURLs: tracker)
}

// MARK: - Primary Action Tests

@Suite("EventPreviewViewModel -- primary action by time window")
struct EventPreviewActionTests {
    @Test("Open Link when meeting is >15 min in the future")
    @MainActor
    func primaryActionOpenLinkWhenFarFuture() async throws {
        // Event starts 30 min from now
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .openLink)
    }

    @Test("Join and Record when within +15 min of start (before)")
    @MainActor
    func primaryActionJoinAndRecordBeforeStart() async throws {
        // Event starts 10 min from now (within 15 min window)
        let eventStart = refDate.addingTimeInterval(10 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .joinAndRecord)
    }

    @Test("Join and Record when within -15 min of start (after)")
    @MainActor
    func primaryActionJoinAndRecordAfterStart() async throws {
        // Event started 10 min ago (within 15 min window)
        let eventStart = refDate.addingTimeInterval(-10 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .joinAndRecord)
    }

    @Test("Join and Record at exact 15 min boundary (before)")
    @MainActor
    func primaryActionJoinAndRecordAtExactBoundary() async throws {
        // Event starts exactly 15 min from now
        let eventStart = refDate.addingTimeInterval(15 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .joinAndRecord)
    }

    @Test("Open Link at 15 min + 1 second (just outside boundary)")
    @MainActor
    func primaryActionOpenLinkJustOutsideBoundary() async throws {
        // Event starts 15 min + 1 second from now
        let eventStart = refDate.addingTimeInterval(15 * 60 + 1)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .openLink)
    }

    @Test("Record when no conference URL (far future)")
    @MainActor
    func primaryActionRecordWhenNoURLFarFuture() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .record)
    }

    @Test("Record when no conference URL (near start)")
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

    @Test("Record when meeting is well past start (>15 min after)")
    @MainActor
    func primaryActionRecordWhenWellPastStart() async throws {
        // Event started 20 min ago
        let eventStart = refDate.addingTimeInterval(-20 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .record)
    }
}

// MARK: - Secondary Record Button Tests

@Suite("EventPreviewViewModel -- secondary record button")
struct EventPreviewSecondaryRecordTests {
    @Test("Shows secondary Record with Open Link primary")
    @MainActor
    func secondaryRecordWithOpenLink() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .openLink)
        #expect(ready.viewModel.showSecondaryRecord == true)
    }

    @Test("Shows secondary Record with Join and Record primary")
    @MainActor
    func secondaryRecordWithJoinAndRecord() async throws {
        let eventStart = refDate.addingTimeInterval(10 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .joinAndRecord)
        #expect(ready.viewModel.showSecondaryRecord == true)
    }

    @Test("No secondary Record when primary is Record")
    @MainActor
    func noSecondaryRecordWhenPrimaryIsRecord() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart,
            conferenceURL: nil,
            currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        #expect(ready.viewModel.primaryAction == .record)
        #expect(ready.viewModel.showSecondaryRecord == false)
    }
}

// MARK: - Action Side-Effect Tests

@Suite("EventPreviewViewModel -- action side effects")
struct EventPreviewActionSideEffectTests {
    @Test("Open Link opens the conference URL")
    @MainActor
    func openLinkOpensURL() async throws {
        let eventStart = refDate.addingTimeInterval(30 * 60)
        let ready = try await makeReadyVM(
            eventStart: eventStart, currentDate: { refDate }
        )
        defer { ready.fixture.cleanup() }

        ready.viewModel.openLink()

        #expect(ready.openedURLs.urls.count == 1)
        #expect(ready.openedURLs.urls.first?.absoluteString.contains("zoom.us") == true)
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
