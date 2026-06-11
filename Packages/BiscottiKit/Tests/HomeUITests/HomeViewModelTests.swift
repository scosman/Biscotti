import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import HomeUI

// MARK: - State tests

@Suite("HomeViewModel -- state")
struct HomeViewModelStateTests {
    @Test("upcomingPreview returns first 3 events from core.displayedUpcoming")
    @MainActor
    func homeShowsUpcomingPreview() async throws {
        let now = Date()
        let dtos = (0 ..< 5).map { idx in
            EKEventDTO(
                eventIdentifier: "ev-\(idx)",
                calendarItemIdentifier: "ci-\(idx)",
                calendarItemExternalIdentifier: "ext-\(idx)",
                occurrenceDate: now,
                title: "Event \(idx)",
                startDate: now.addingTimeInterval(Double(idx + 1) * 600),
                endDate: now.addingTimeInterval(Double(idx + 1) * 600 + 3600),
                isAllDay: false,
                location: "https://zoom.us/j/\(idx)",
                url: nil,
                timeZone: nil,
                notes: nil,
                status: nil,
                availability: nil,
                calendarIdentifier: "cal-1",
                calendarTitle: "Work",
                calendarColorHex: "#0066CC",
                calendarSourceTitle: "iCloud",
                birthdayContactIdentifier: nil,
                attendeeCount: 3,
                attendees: [],
                organizer: nil
            )
        }

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.upcomingPreview.count == 3)
        #expect(viewModel.upcomingPreview[0].title == "Event 0")
        #expect(viewModel.upcomingPreview[2].title == "Event 2")
    }

    @Test("showConnectCalendar is true when calendar access not authorized")
    @MainActor
    func homeEmptyWhenNoCalendarAccess() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showConnectCalendar == true)
        #expect(viewModel.upcomingPreview.isEmpty)
    }

    @Test("showNoUpcoming is true when authorized but no upcoming events")
    @MainActor
    func homeNoUpcomingWhenAuthorizedButEmpty() async throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            calendarEventDTOs: [],
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showNoUpcoming == true)
        #expect(viewModel.showConnectCalendar == false)
    }

    @Test("startDisabled is true when recording in progress")
    @MainActor
    func homeStartDisabledWhileRecording() async throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.startDisabled == false)

        await fix.core.startRecording()
        #expect(viewModel.startDisabled == true)
    }

    @Test("showConnectCalendar is false when denied (still not authorized)")
    @MainActor
    func connectCalendarShownWhenDenied() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .denied,
            testName: "HomeUITests"
        )
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showConnectCalendar == true)
    }
}

// MARK: - Formatting tests

@Suite("HomeViewModel -- timeText formatting")
struct HomeViewModelFormattingTests {
    @Test("timeText returns relative time for various intervals")
    func homeTimeTextFormatsRelative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        func makeEvent(startOffset: TimeInterval) -> CalendarEvent {
            CalendarEvent(
                id: "e",
                title: "T",
                start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(startOffset + 3600),
                conferencePlatform: nil,
                conferenceURL: nil,
                attendeeCount: 2,
                calendarTitle: "W",
                calendarColorHex: "#000",
                isMeetingLike: true
            )
        }

        // 12 minutes in the future
        let text12m = HomeViewModel.timeText(
            for: makeEvent(startOffset: 12 * 60),
            relativeTo: now
        )
        #expect(text12m == "in 12m")

        // 90 minutes in the future
        let text90m = HomeViewModel.timeText(
            for: makeEvent(startOffset: 90 * 60),
            relativeTo: now
        )
        #expect(text90m == "in 1h 30m")

        // exactly 2 hours
        let text2h = HomeViewModel.timeText(
            for: makeEvent(startOffset: 2 * 3600),
            relativeTo: now
        )
        #expect(text2h == "in 2h")

        // past event
        let textPast = HomeViewModel.timeText(
            for: makeEvent(startOffset: -600),
            relativeTo: now
        )
        #expect(textPast == "now")
    }
}

// MARK: - Action tests

@Suite("HomeViewModel -- actions")
struct HomeViewModelActionTests {
    @Test("selectEvent routes to event preview")
    @MainActor
    func selectEventRoutes() throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        viewModel.selectEvent("event-key-42")
        #expect(fix.core.route == .event("event-key-42"))
    }

    @Test("startRecording delegates to core")
    @MainActor
    func startRecordingDelegates() async throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        await viewModel.startRecording()
        #expect(fix.core.recording.state.isRecording)
    }
}
