import BiscottiTestSupport
import Calendar
import DataStore
import DesignSystem
import Foundation
import Testing
@testable import AppCore
@testable import HomeUI

// MARK: - State tests

@Suite("HomeViewModel -- state")
struct HomeViewModelStateTests {
    @Test("upcomingPreview returns first 6 events from core.displayedUpcoming")
    @MainActor
    func homeShowsUpcomingPreview() async throws {
        let now = Date()
        let dtos = (0 ..< 8).map { idx in
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
        #expect(viewModel.upcomingPreview.count == 6)
        #expect(viewModel.upcomingPreview[0].title == "Event 0")
        #expect(viewModel.upcomingPreview[5].title == "Event 5")
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

// MARK: - Recent Meetings state tests

@Suite("HomeViewModel -- recentMeetings")
struct HomeViewModelRecentTests {
    @Test("recentMeetings returns at most 4, newest-first, order preserved")
    @MainActor
    func recentMeetingsCapAndOrder() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIRecentTests")
        defer { fix.cleanup() }

        // Create 5 meetings with distinct titles; createMeeting order
        // determines the effective date (createdAt, newest = last created).
        var ids: [UUID] = []
        for idx in 0 ..< 5 {
            let id = try await fix.createMeetingWithAudio(
                title: "Meeting \(idx)",
                recordingDuration: Double(idx + 1) * 60
            )
            ids.append(id)
        }

        // Reload summaries so core.summaries is populated
        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)

        // Should return exactly 4 (cap), not 5
        #expect(viewModel.recentMeetings.count == 4)

        // Newest-first: the last created meeting appears first.
        // Summaries are sorted by date descending; since all use
        // createdAt (no startDate set), the last inserted is newest.
        #expect(viewModel.recentMeetings[0].title == "Meeting 4")
        #expect(viewModel.recentMeetings[1].title == "Meeting 3")
        #expect(viewModel.recentMeetings[2].title == "Meeting 2")
        #expect(viewModel.recentMeetings[3].title == "Meeting 1")

        // Meeting 0 (oldest) is excluded by the cap
        let titles = viewModel.recentMeetings.map(\.title)
        #expect(!titles.contains("Meeting 0"))
    }

    @Test("showNoRecent is true when no meetings exist")
    @MainActor
    func showNoRecentWhenEmpty() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIRecentEmpty")
        defer { fix.cleanup() }

        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showNoRecent == true)
    }

    @Test("showNoRecent is false when meetings exist")
    @MainActor
    func showNoRecentFalseWhenMeetingsExist() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIRecentPresent")
        defer { fix.cleanup() }

        _ = try await fix.createMeetingWithAudio(title: "Exists")
        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showNoRecent == false)
    }

    @Test("selectMeeting routes to .meetings and sets selection")
    @MainActor
    func selectMeetingRoutes() async throws {
        let fix = try makeCoreFixture(testName: "HomeUISelectMeeting")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(title: "Test")
        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)
        viewModel.selectMeeting(meetingID)
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == meetingID)
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

// MARK: - Recent second-line formatting tests

@Suite("HomeViewModel -- recentSecondLine formatting")
struct HomeViewModelRecentFormattingTests {
    @Test("recentSecondLine matches sidebar format with duration")
    @MainActor
    func recentSecondLineWithDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600)
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 34 * 60
        )
        let text = HomeViewModel.recentSecondLine(for: summary)
        let expected = "\(TimeFormatting.shortDate(date)) \u{00B7} 34m"
        #expect(text == expected)
    }

    @Test("recentSecondLine shows date only when no duration")
    @MainActor
    func recentSecondLineNoDuration() {
        let date = Date(timeIntervalSince1970: 1_781_193_600)
        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: nil
        )
        let text = HomeViewModel.recentSecondLine(for: summary)
        #expect(text == TimeFormatting.shortDate(date))
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

    @Test("showMeetings routes to .meetings (See all)")
    @MainActor
    func showMeetingsRoutes() throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        // Start from home
        #expect(fix.core.route == .home)

        viewModel.showMeetings()
        #expect(fix.core.route == .meetings)
    }

    @Test("showMeetings keeps existing selection (D4)")
    @MainActor
    func showMeetingsKeepsSelection() throws {
        let fix = try makeCoreFixture(testName: "HomeUITests")
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(fix.core.meetingsSelection == meetingID)

        // Navigate away then use "See all"
        fix.core.showHome()
        let viewModel = HomeViewModel(core: fix.core)
        viewModel.showMeetings()
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == meetingID)
    }
}
