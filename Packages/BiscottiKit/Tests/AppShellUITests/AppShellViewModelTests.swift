import BiscottiTestSupport
import Calendar
import Foundation
import Testing
@testable import AppCore
@testable import AppShellUI

// MARK: - Tests

@Suite("AppShellViewModel -- recording state")
struct AppShellRecordingStateTests {
    @Test("isRecording is false when idle")
    @MainActor
    func isRecordingFalseWhenIdle() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.isRecording == false)
    }

    @Test("isRecording is true when recording")
    @MainActor
    func isRecordingTrueWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.isRecording == true)
    }

    @Test("recordingElapsedText formats M:SS at zero")
    @MainActor
    func recordingElapsedTextZero() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.recordingElapsedText == "0:00")
    }

    @Test("formatElapsed handles minutes and seconds")
    func formatElapsedMinutesSeconds() {
        #expect(AppShellViewModel.formatElapsed(0) == "0:00")
        #expect(AppShellViewModel.formatElapsed(5) == "0:05")
        #expect(AppShellViewModel.formatElapsed(65) == "1:05")
        #expect(AppShellViewModel.formatElapsed(113) == "1:53")
    }

    @Test("formatElapsed handles hours")
    func formatElapsedHours() {
        #expect(AppShellViewModel.formatElapsed(3661) == "1:01:01")
        #expect(AppShellViewModel.formatElapsed(7200) == "2:00:00")
    }
}

@Suite("AppShellViewModel -- routing")
struct AppShellRoutingTests {
    @Test("route is .home initially")
    @MainActor
    func routeHomeInitially() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        #expect(viewModel.route == .home)
    }

    @Test("route is .recording after startRecording")
    @MainActor
    func routeRecordingAfterStart() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        await viewModel.startRecording()
        #expect(viewModel.route == .recording)
    }

    @Test("route is .meetings after selecting a meeting")
    @MainActor
    func routeMeetingsAfterSelect() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.route == .meetings)
        #expect(viewModel.meetingsSelection == meetingID)
    }

    @Test("showRecording navigates back to recording screen")
    @MainActor
    func showRecordingNavigatesBack() async throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        await viewModel.startRecording()
        #expect(viewModel.route == .recording)

        // User selects a past meeting during recording
        fix.core.select(UUID())
        #expect(viewModel.route != .recording)

        // Tap recording indicator to go back
        viewModel.showRecording()
        #expect(viewModel.route == .recording)
    }

    @Test("showRecording is a no-op when not recording")
    @MainActor
    func showRecordingNoOpWhenIdle() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        viewModel.showRecording()
        #expect(viewModel.route == .home)
    }

    @Test("eventPreviewViewModel returns stable instance for same key")
    @MainActor
    func eventPreviewVMStableForSameKey() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let epVM1 = viewModel.eventPreviewViewModel(for: "key-1")
        let epVM2 = viewModel.eventPreviewViewModel(for: "key-1")
        #expect(epVM1 === epVM2)
    }

    @Test("eventPreviewViewModel returns new instance for different key")
    @MainActor
    func eventPreviewVMNewForDifferentKey() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let epVM1 = viewModel.eventPreviewViewModel(for: "key-1")
        let epVM2 = viewModel.eventPreviewViewModel(for: "key-2")
        #expect(epVM1 !== epVM2)
    }
}

@Suite("AppShellViewModel -- child view model stability")
struct AppShellChildVMTests {
    @Test("child view models are stable across accesses")
    @MainActor
    func childViewModelsStable() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)

        // MeetingListViewModel should be the same instance across accesses
        let listVM1 = viewModel.meetingListViewModel
        let listVM2 = viewModel.meetingListViewModel
        #expect(listVM1 === listVM2)

        // RecordingViewModel should be the same instance across accesses
        let recordingVM1 = viewModel.recordingViewModel
        let recordingVM2 = viewModel.recordingViewModel
        #expect(recordingVM1 === recordingVM2)
    }

    @Test("meetingDetailViewModel returns stable instance for same meeting ID")
    @MainActor
    func meetingDetailVMStableForSameID() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let meetingID = UUID()

        let detailVM1 = viewModel.meetingDetailViewModel(for: meetingID)
        let detailVM2 = viewModel.meetingDetailViewModel(for: meetingID)
        #expect(detailVM1 === detailVM2)
    }

    @Test("meetingDetailViewModel returns new instance for different meeting ID")
    @MainActor
    func meetingDetailVMNewForDifferentID() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let id1 = UUID()
        let id2 = UUID()

        let detailVM1 = viewModel.meetingDetailViewModel(for: id1)
        let detailVM2 = viewModel.meetingDetailViewModel(for: id2)
        #expect(detailVM1 !== detailVM2)
    }

    @Test("settingsViewModel is stable")
    @MainActor
    func settingsVMStable() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let viewModel = AppShellViewModel(core: fix.core)
        let settings1 = viewModel.settingsViewModel
        let settings2 = viewModel.settingsViewModel
        #expect(settings1 === settings2)
    }
}

// MARK: - Upcoming and search tests

@Suite("AppShellViewModel -- upcoming and search")
struct AppShellUpcomingSearchTests {
    @Test("upcomingEvents reflects core upcoming")
    @MainActor
    func upcomingEventsReflectsCore() async throws {
        let now = Date()
        let dto = EKEventDTO(
            eventIdentifier: "ev-shell",
            calendarItemIdentifier: "ci-shell",
            calendarItemExternalIdentifier: "ext-shell",
            occurrenceDate: now,
            title: "Shell Event",
            startDate: now,
            endDate: now.addingTimeInterval(3600),
            isAllDay: false,
            location: "https://zoom.us/j/789",
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

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "AppShellUITests"
        )
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch primes calendar
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let shellVM = AppShellViewModel(core: fix.core)
        #expect(shellVM.upcomingEvents.count == 1)
        #expect(shellVM.upcomingEvents.first?.title == "Shell Event")
    }

    @Test("hasCalendarAccess reflects auth status")
    @MainActor
    func hasCalendarAccessReflectsAuth() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            testName: "AppShellUITests"
        )
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        #expect(shellVM.hasCalendarAccess == true)
    }

    @Test("hasCalendarAccess false when not determined")
    @MainActor
    func hasCalendarAccessFalseWhenNotDetermined() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            testName: "AppShellUITests"
        )
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        #expect(shellVM.hasCalendarAccess == false)
    }

    @Test("setMeetingsQuery forwards to core and routes to meetings")
    @MainActor
    func setMeetingsQueryForwards() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.setMeetingsQuery("meeting")
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsQuery == "meeting")
    }

    @Test("setMeetingsQuery empty clears search state")
    @MainActor
    func setMeetingsQueryEmptyClears() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.setMeetingsQuery("hello")
        shellVM.setMeetingsQuery("")
        #expect(fix.core.meetingsQuery == "")
        #expect(fix.core.meetingsResults.isEmpty)
    }

    @Test("showHome routes to home")
    @MainActor
    func showHomeRoutesToHome() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        fix.core.showSettings() // change route first
        shellVM.showHome()
        #expect(shellVM.route == .home)
    }

    @Test("showSettings routes to settings")
    @MainActor
    func showSettingsRoutesToSettings() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.showSettings()
        #expect(shellVM.route == .settings)
    }

    @Test("selectEvent routes to event preview")
    @MainActor
    func selectEventRoutes() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.selectEvent("event-key-123")
        #expect(shellVM.route == .event("event-key-123"))
    }

    @Test("timeText formats future events correctly")
    @MainActor
    func timeTextFormats() {
        let now = Date()
        let event = CalendarEvent(
            id: "e",
            title: "T",
            start: now.addingTimeInterval(1800), // 30 min
            end: now.addingTimeInterval(5400),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 2,
            calendarTitle: "W",
            calendarColorHex: "#000",
            isMeetingLike: true
        )
        let text = AppShellViewModel.timeText(for: event, relativeTo: now)
        #expect(text == "in 30m")

        let event2 = CalendarEvent(
            id: "e2",
            title: "T2",
            start: now.addingTimeInterval(5400), // 90 min
            end: now.addingTimeInterval(9000),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 2,
            calendarTitle: "W",
            calendarColorHex: "#000",
            isMeetingLike: true
        )
        let text2 = AppShellViewModel.timeText(for: event2, relativeTo: now)
        #expect(text2 == "in 1h 30m")
    }

    @Test("timeText returns 'now' for past events")
    @MainActor
    func timeTextPast() {
        let now = Date()
        let event = CalendarEvent(
            id: "e",
            title: "T",
            start: now.addingTimeInterval(-600), // started 10 min ago
            end: now.addingTimeInterval(1800),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 2,
            calendarTitle: "W",
            calendarColorHex: "#000",
            isMeetingLike: true
        )
        let text = AppShellViewModel.timeText(for: event, relativeTo: now)
        #expect(text == "now")
    }

    @Test("meetingsQuery passthrough reflects core state")
    @MainActor
    func meetingsQueryPassthrough() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.setMeetingsQuery("hello")
        #expect(shellVM.meetingsQuery == "hello")
    }

    @Test("homeViewModel is stable across accesses")
    @MainActor
    func homeVMStable() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        let home1 = shellVM.homeViewModel
        let home2 = shellVM.homeViewModel
        #expect(home1 === home2)
    }

    @Test("showMeetings routes to meetings")
    @MainActor
    func showMeetingsRoutes() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.showMeetings()
        #expect(shellVM.route == .meetings)
    }
}

// MARK: - isHome and searchFocusToken tests

@Suite("AppShellViewModel -- isHome")
struct AppShellIsHomeTests {
    @Test("isHome is true when route is .home")
    @MainActor
    func isHomeTrueOnHome() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        #expect(shellVM.isHome == true)
    }

    @Test("isHome is false when route is not .home")
    @MainActor
    func isHomeFalseOnOtherRoutes() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        fix.core.showSettings()
        #expect(shellVM.isHome == false)

        fix.core.showMeetings()
        #expect(shellVM.isHome == false)
    }
}

@Suite("AppShellViewModel -- searchFocusToken")
struct AppShellSearchFocusTests {
    @Test("searchFocusToken starts at zero")
    @MainActor
    func tokenStartsAtZero() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        #expect(shellVM.searchFocusToken == 0)
    }

    @Test("focusSearch increments searchFocusToken")
    @MainActor
    func focusSearchIncrementsToken() throws {
        let fix = try makeCoreFixture(testName: "AppShellUITests")
        defer { fix.cleanup() }

        let shellVM = AppShellViewModel(core: fix.core)
        shellVM.focusSearch()
        #expect(shellVM.searchFocusToken == 1)
        shellVM.focusSearch()
        #expect(shellVM.searchFocusToken == 2)
    }
}

// MARK: - Upcoming display cap tests

@Suite("AppShellViewModel -- upcoming display cap")
struct AppShellUpcomingCapTests {
    @Test("upcomingEvents capped at 6")
    @MainActor
    func upcomingEventsCappedAt6() async throws {
        let now = Date()
        let dtos = (0 ..< 9).map { idx in
            EKEventDTO(
                eventIdentifier: "ev-cap-\(idx)",
                calendarItemIdentifier: "ci-cap-\(idx)",
                calendarItemExternalIdentifier: "ext-cap-\(idx)",
                occurrenceDate: now.addingTimeInterval(
                    Double(idx + 1) * 600
                ),
                title: "Cap Event \(idx)",
                startDate: now.addingTimeInterval(
                    Double(idx + 1) * 600
                ),
                endDate: now.addingTimeInterval(
                    Double(idx + 1) * 600 + 3600
                ),
                isAllDay: false,
                location: "https://zoom.us/j/cap\(idx)",
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
            testName: "AppShellUITests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Core should have more than 6 upcoming
        #expect(fix.core.displayedUpcoming.count > 6)

        let shellVM = AppShellViewModel(core: fix.core)
        // Sidebar caps at 6
        #expect(shellVM.upcomingEvents.count == 6)
        // Preserves order (first 6)
        #expect(shellVM.upcomingEvents.first?.title == "Cap Event 0")
        #expect(shellVM.upcomingEvents.last?.title == "Cap Event 5")
    }
}
