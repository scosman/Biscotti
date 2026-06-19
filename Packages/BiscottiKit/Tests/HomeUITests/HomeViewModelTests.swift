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
    @Test("upcomingPreview returns first 3 events from core.displayedUpcoming")
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
    @Test("recentMeetings returns at most 3, newest-first, order preserved")
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

        // Should return exactly 3 (cap), not 5
        #expect(viewModel.recentMeetings.count == 3)

        // Newest-first: the last created meeting appears first.
        // Summaries are sorted by date descending; since all use
        // createdAt (no startDate set), the last inserted is newest.
        #expect(viewModel.recentMeetings[0].title == "Meeting 4")
        #expect(viewModel.recentMeetings[1].title == "Meeting 3")
        #expect(viewModel.recentMeetings[2].title == "Meeting 2")

        // Meetings 0 and 1 (oldest) are excluded by the cap
        let titles = viewModel.recentMeetings.map(\.title)
        #expect(!titles.contains("Meeting 1"))
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

    @Test("pastMeetingsCount returns total count, not capped at 3")
    @MainActor
    func pastMeetingsCountReflectsTotal() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIPastCount")
        defer { fix.cleanup() }

        for idx in 0 ..< 5 {
            _ = try await fix.createMeetingWithAudio(
                title: "Meeting \(idx)",
                recordingDuration: Double(idx + 1) * 60
            )
        }
        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)
        // recentMeetings is capped at 3, but pastMeetingsCount is the full total
        #expect(viewModel.recentMeetings.count == 3)
        #expect(viewModel.pastMeetingsCount == 5)
    }

    @Test("pastMeetingsCount is zero when no meetings exist")
    @MainActor
    func pastMeetingsCountZeroWhenEmpty() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIPastCountEmpty")
        defer { fix.cleanup() }

        await fix.core.reloadSummaries()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.pastMeetingsCount == 0)
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
        #expect(fix.core.meetingsSelection == [meetingID])
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

        // 5 hours in the future (>3h tier: hours only, no minutes)
        let text5h = HomeViewModel.timeText(
            for: makeEvent(startOffset: 5 * 3600 + 1800),
            relativeTo: now
        )
        #expect(text5h == "in 5h")

        // 2 days in the future (>=1 day tier: days only)
        let text2d = HomeViewModel.timeText(
            for: makeEvent(startOffset: 2 * 86400),
            relativeTo: now
        )
        #expect(text2d == "in 2 days")
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
        #expect(fix.core.meetingsSelection == [meetingID])

        // Navigate away then use "See all"
        fix.core.showHome()
        let viewModel = HomeViewModel(core: fix.core)
        viewModel.showMeetings()
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
    }

    @Test("joinAndRecord opens conference URL and starts recording")
    @MainActor
    func joinAndRecordWithURL() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIJoinAndRecord")
        defer { fix.cleanup() }

        var openedURLs: [URL] = []
        let viewModel = HomeViewModel(core: fix.core) { url in
            openedURLs.append(url)
        }

        let event = try CalendarEvent(
            id: "ev-join",
            title: "Standup",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            conferencePlatform: "Zoom",
            conferenceURL: #require(URL(string: "https://zoom.us/j/123")),
            attendeeCount: 3,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            isMeetingLike: true
        )

        await viewModel.joinAndRecord(event)

        #expect(openedURLs.count == 1)
        #expect(openedURLs[0].absoluteString == "https://zoom.us/j/123")
        // Recording was attempted (the fake recorder's start was called)
        #expect(fix.fakeRecorder.backing.startCalled)
    }

    @Test("joinAndRecord skips URL when no conference link (record-only)")
    @MainActor
    func joinAndRecordNoURL() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIRecordOnly")
        defer { fix.cleanup() }

        var openedURLs: [URL] = []
        let viewModel = HomeViewModel(core: fix.core) { url in
            openedURLs.append(url)
        }

        let event = CalendarEvent(
            id: "ev-nourl",
            title: "1:1",
            start: Date(),
            end: Date().addingTimeInterval(1800),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 2,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            isMeetingLike: true
        )

        await viewModel.joinAndRecord(event)

        // No URL opened
        #expect(openedURLs.isEmpty)
        // Recording was still attempted
        #expect(fix.fakeRecorder.backing.startCalled)
    }

    @Test("openInCalendar produces ical ekevent deep-link URL")
    @MainActor
    func openInCalendar() throws {
        let fix = try makeCoreFixture(testName: "HomeUIOpenCal")
        defer { fix.cleanup() }

        var openedURLs: [URL] = []
        let viewModel = HomeViewModel(core: fix.core) { url in
            openedURLs.append(url)
        }

        let eventDate = Date(timeIntervalSinceReferenceDate: 123_456)
        // Use a realistic composite key: "eventIdentifier|calendarItemIdentifier|timestamp"
        let event = CalendarEvent(
            id: "EV-42|CI-42|123456",
            title: "Meeting",
            start: eventDate,
            end: eventDate.addingTimeInterval(3600),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 1,
            calendarTitle: "Work",
            calendarColorHex: "#000",
            isMeetingLike: true
        )

        viewModel.openInCalendar(event)

        #expect(openedURLs.count == 1)
        #expect(openedURLs[0].scheme == "ical")
        // Uses the event identifier extracted from the composite key
        #expect(openedURLs[0].absoluteString.contains("ekevent/EV-42"))
        // No fractional timestamp in the URL
        #expect(!openedURLs[0].absoluteString.contains(".0"))
    }
}

// MARK: - Greeting tests

@Suite("HomeViewModel -- greeting & date")
struct HomeViewModelGreetingTests {
    @Test("greeting returns correct time-of-day text")
    @MainActor
    func greetingBoundaries() throws {
        let fix = try makeCoreFixture(testName: "HomeUIGreeting")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)

        // Morning: 9 AM
        let morning = try #require(Foundation.Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: Date()
        ))
        fix.core.setMinuteTick(morning)
        #expect(viewModel.greeting == "Good morning")

        // Afternoon: 2 PM
        let afternoon = try #require(Foundation.Calendar.current.date(
            bySettingHour: 14, minute: 0, second: 0, of: Date()
        ))
        fix.core.setMinuteTick(afternoon)
        #expect(viewModel.greeting == "Good afternoon")

        // Evening: 8 PM
        let evening = try #require(Foundation.Calendar.current.date(
            bySettingHour: 20, minute: 0, second: 0, of: Date()
        ))
        fix.core.setMinuteTick(evening)
        #expect(viewModel.greeting == "Good evening")
    }

    @Test("greeting boundary at noon is afternoon")
    @MainActor
    func greetingNoon() throws {
        let fix = try makeCoreFixture(testName: "HomeUIGreetingNoon")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        let noon = try #require(Foundation.Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: Date()
        ))
        fix.core.setMinuteTick(noon)
        #expect(viewModel.greeting == "Good afternoon")
    }

    @Test("greeting boundary at 6 PM is evening")
    @MainActor
    func greetingEvening() throws {
        let fix = try makeCoreFixture(testName: "HomeUIGreetingEve")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        let sixPM = try #require(Foundation.Calendar.current.date(
            bySettingHour: 18, minute: 0, second: 0, of: Date()
        ))
        fix.core.setMinuteTick(sixPM)
        #expect(viewModel.greeting == "Good evening")
    }

    @Test("dateText is formatted as EEEE, MMMM d")
    @MainActor
    func dateTextFormat() throws {
        let fix = try makeCoreFixture(testName: "HomeUIDateText")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)

        // Use a well-known date
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = 10
        let date = try #require(Foundation.Calendar.current.date(from: components))
        fix.core.setMinuteTick(date)

        #expect(viewModel.dateText == "Friday, June 12")
    }
}

// MARK: - Stat chip tests

@Suite("HomeViewModel -- stat chips")
struct HomeViewModelStatChipTests {
    @Test("showStatChips is false when not authorized")
    @MainActor
    func showStatChipsFalseWhenNotAuthorized() throws {
        let fix = try makeCoreFixture(
            calendarAuthStatus: .notDetermined,
            testName: "HomeUIChipsNoAuth"
        )
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.showStatChips == false)
        #expect(viewModel.meetingsLeftText == nil)
    }

    @Test("meetingsLeftText counts same-day meeting-like events")
    @MainActor
    func meetingsLeftCountsSameDay() async throws {
        // Use a fixed date at 10 AM to avoid midnight-boundary flakiness
        var comp = DateComponents()
        comp.year = 2026; comp.month = 6; comp.day = 15; comp.hour = 10
        let now = try #require(Foundation.Calendar.current.date(from: comp))

        let tomorrow = try #require(Foundation.Calendar.current.date(
            byAdding: .day, value: 1, to: now
        ))

        let dtos = [
            makeEventDTO(id: "today-1", startOffset: 600, from: now, isMeetingLike: true),
            makeEventDTO(id: "today-2", startOffset: 1800, from: now, isMeetingLike: true),
            makeEventDTO(id: "tomorrow-1", startOffset: 600, from: tomorrow, isMeetingLike: true)
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIChipsSameDay"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.meetingsLeftText == "2 meetings left today")
    }

    @Test("meetingsLeftText singular when 1 meeting")
    @MainActor
    func meetingsLeftSingular() async throws {
        var comp = DateComponents()
        comp.year = 2026; comp.month = 6; comp.day = 15; comp.hour = 10
        let now = try #require(Foundation.Calendar.current.date(from: comp))
        let dtos = [
            makeEventDTO(id: "solo", startOffset: 600, from: now, isMeetingLike: true)
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIChipsSingular"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.meetingsLeftText == "1 meeting left today")
    }

    @Test("nextInText present when upcoming events exist")
    @MainActor
    func nextInTextPresent() async throws {
        var comp = DateComponents()
        comp.year = 2026; comp.month = 6; comp.day = 15; comp.hour = 10
        let now = try #require(Foundation.Calendar.current.date(from: comp))
        let dtos = [
            makeEventDTO(id: "next", startOffset: 360, from: now, isMeetingLike: true)
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIChipsNextIn"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.nextInText != nil)
        #expect(try #require(viewModel.nextInText?.hasPrefix("in ")))
    }

    @Test("nextInText uses coarse formatting for multi-day events")
    @MainActor
    func nextInTextCoarseDays() async throws {
        var comp = DateComponents()
        comp.year = 2026; comp.month = 6; comp.day = 15; comp.hour = 10
        let now = try #require(Foundation.Calendar.current.date(from: comp))
        // Event 2 days away
        let dtos = [
            makeEventDTO(
                id: "far", startOffset: 2 * 24 * 3600,
                from: now, isMeetingLike: true
            )
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIChipsNextInDays"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.nextInText == "in 2 days")
    }

    @Test("nextInText uses coarse formatting for >3h events")
    @MainActor
    func nextInTextCoarseHours() async throws {
        var comp = DateComponents()
        comp.year = 2026; comp.month = 6; comp.day = 15; comp.hour = 10
        let now = try #require(Foundation.Calendar.current.date(from: comp))
        // Event 5h 30m away -- should show "in 5h" (minutes dropped)
        let dtos = [
            makeEventDTO(
                id: "hrs", startOffset: 5 * 3600 + 30 * 60,
                from: now, isMeetingLike: true
            )
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIChipsNextInHrs"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.nextInText == "in 5h")
    }

    @Test("nextInText nil when no upcoming events")
    @MainActor
    func nextInTextNilWhenEmpty() async throws {
        let fix = try makeCoreFixture(
            calendarEventDTOs: [],
            testName: "HomeUIChipsNextInNil"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.nextInText == nil)
    }
}

// MARK: - Hero detection tests

@Suite("HomeViewModel -- hero detection")
struct HomeViewModelHeroTests {
    @Test("heroEvent is non-nil when first event within join window")
    @MainActor
    func heroEventWithinWindow() async throws {
        let now = Date()
        // Event starts 5 minutes from now (within 15-min window)
        let dtos = [
            makeEventDTO(id: "soon", startOffset: 300, from: now, isMeetingLike: true)
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIHeroIn"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.heroEvent != nil)
        #expect(viewModel.heroEvent?.title == "Event soon")
    }

    @Test("heroEvent is nil when first event outside join window")
    @MainActor
    func heroEventOutsideWindow() async throws {
        let now = Date()
        // Event starts 20 minutes from now (outside 15-min window)
        let dtos = [
            makeEventDTO(id: "later", startOffset: 1200, from: now, isMeetingLike: true)
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIHeroOut"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.heroEvent == nil)
    }

    @Test("heroEvent is nil when no upcoming events")
    @MainActor
    func heroEventNilWhenEmpty() async throws {
        let fix = try makeCoreFixture(
            calendarEventDTOs: [],
            testName: "HomeUIHeroEmpty"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.heroEvent == nil)
    }

    @Test("heroIsRecordOnly is true when no conference URL")
    @MainActor
    func heroRecordOnly() async throws {
        let now = Date()
        let dtos = [
            makeEventDTO(
                id: "nourl", startOffset: 60, from: now,
                isMeetingLike: true, conferenceURL: nil,
                location: "Conference Room B"
            )
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIHeroRecordOnly"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.heroEvent != nil)
        #expect(viewModel.heroIsRecordOnly == true)
    }

    @Test("heroIsRecordOnly is false when conference URL present")
    @MainActor
    func heroNotRecordOnly() async throws {
        let now = Date()
        let dtos = [
            makeEventDTO(
                id: "withurl", startOffset: 60, from: now,
                isMeetingLike: true,
                conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij")
            )
        ]

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "HomeUIHeroNotRecOnly"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        fix.core.setMinuteTick(now)

        let viewModel = HomeViewModel(core: fix.core)
        #expect(viewModel.heroEvent != nil)
        #expect(viewModel.heroIsRecordOnly == false)
    }

    @Test("recordDisabled reflects recording state")
    @MainActor
    func recordDisabledReflectsState() async throws {
        let fix = try makeCoreFixture(testName: "HomeUIRecordDisabled")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        // Not recording
        #expect(viewModel.recordDisabled == false)

        // Start a recording
        await fix.core.startRecording()
        #expect(viewModel.recordDisabled == true)
    }
}

// MARK: - Avatar mapping tests

@Suite("HomeViewModel -- avatar mapping")
struct HomeViewModelMappingTests {
    @Test("avatarData for CalendarEvent deduplicates by email")
    @MainActor
    func avatarDataCalendarEventDedup() throws {
        let fix = try makeCoreFixture(testName: "HomeUIMappingDedup")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)

        let event = CalendarEvent(
            id: "ev-dedup",
            title: "Standup",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 4,
            calendarTitle: "Work",
            calendarColorHex: "#000",
            isMeetingLike: true,
            organizer: AttendeeInfo(name: "Alice", email: "alice@example.com"),
            attendees: [
                AttendeeInfo(name: "Alice", email: "alice@example.com"),
                AttendeeInfo(name: "Bob", email: "bob@example.com")
            ]
        )

        let data = viewModel.avatarData(for: event)
        // Alice deduped (organizer + attendee)
        #expect(data.people.count == 2)
        #expect(data.people[0].displayName == "Alice")
        #expect(data.people[1].displayName == "Bob")
        // total uses attendeeCount since it's larger
        #expect(data.total == 4)
    }

    @Test("avatarData for MeetingSummary maps participants")
    @MainActor
    func avatarDataMeetingSummary() throws {
        let fix = try makeCoreFixture(testName: "HomeUIMappingSummary")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)

        let summary = MeetingSummary(
            id: UUID(),
            title: "Past Meeting",
            date: Date(),
            hasTranscript: false,
            participants: [
                PersonData(id: UUID(), name: "Carol", email: "carol@example.com"),
                PersonData(id: UUID(), name: "Dave", email: nil)
            ],
            participantCount: 5
        )

        let data = viewModel.avatarData(for: summary)
        #expect(data.people.count == 2)
        #expect(data.people[0].displayName == "Carol")
        #expect(data.people[0].email == "carol@example.com")
        #expect(data.people[1].displayName == "Dave")
        #expect(data.total == 5)
    }

    @Test("pastSecondLine includes names when participants present")
    @MainActor
    func pastSecondLineWithNames() throws {
        let fix = try makeCoreFixture(testName: "HomeUIPastSecondLine")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        let date = Date(timeIntervalSince1970: 1_781_193_600)

        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 34 * 60,
            participants: [
                PersonData(id: UUID(), name: "Alice"),
                PersonData(id: UUID(), name: "Bob")
            ],
            participantCount: 2
        )

        let text = viewModel.pastSecondLine(for: summary)
        let base = "\(TimeFormatting.shortDate(date)) \u{00B7} 34m"
        #expect(text == "\(base) \u{00B7} Alice, Bob")
    }

    @Test("pastSecondLine omits names when no participants")
    @MainActor
    func pastSecondLineNoNames() throws {
        let fix = try makeCoreFixture(testName: "HomeUIPastSecondLineNoName")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        let date = Date(timeIntervalSince1970: 1_781_193_600)

        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 34 * 60,
            participants: [],
            participantCount: 0
        )

        let text = viewModel.pastSecondLine(for: summary)
        let expected = "\(TimeFormatting.shortDate(date)) \u{00B7} 34m"
        #expect(text == expected)
    }

    @Test("pastSecondLine caps names at 3")
    @MainActor
    func pastSecondLineCapsNames() throws {
        let fix = try makeCoreFixture(testName: "HomeUIPastSecondLineCap")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)
        let date = Date(timeIntervalSince1970: 1_781_193_600)

        let summary = MeetingSummary(
            id: UUID(),
            title: "Test",
            date: date,
            hasTranscript: false,
            recordingDuration: 60 * 60,
            participants: [
                PersonData(id: UUID(), name: "Alice"),
                PersonData(id: UUID(), name: "Bob"),
                PersonData(id: UUID(), name: "Carol"),
                PersonData(id: UUID(), name: "Dave"),
                PersonData(id: UUID(), name: "Eve")
            ],
            participantCount: 5
        )

        let text = viewModel.pastSecondLine(for: summary)
        // Only first 3 names shown
        #expect(text.contains("Alice, Bob, Carol"))
        #expect(!text.contains("Dave"))
    }

    @Test("avatarData returns empty people for meeting with no participants")
    @MainActor
    func avatarDataEmptyForNoParticipants() throws {
        let fix = try makeCoreFixture(testName: "HomeUIMappingEmpty")
        defer { fix.cleanup() }

        let viewModel = HomeViewModel(core: fix.core)

        let summary = MeetingSummary(
            id: UUID(),
            title: "Audio Only Recording",
            date: Date(),
            hasTranscript: false,
            participants: [],
            participantCount: 0
        )

        let data = viewModel.avatarData(for: summary)
        #expect(data.people.isEmpty)
        #expect(data.total == 0)
        // The recording avatar in AvatarCluster (showLeadingRecordingAvatar)
        // guarantees the cluster is never blank even when people is empty.
    }
}

// MARK: - Test helpers

/// Creates an EKEventDTO for testing with configurable parameters.
private func makeEventDTO(
    id: String,
    startOffset: TimeInterval,
    from baseDate: Date,
    durationSeconds: TimeInterval = 3600,
    isMeetingLike: Bool = true,
    conferenceURL: URL? = URL(string: "https://meet.google.com/abc-defg-hij"),
    location: String? = nil
) -> EKEventDTO {
    let start = baseDate.addingTimeInterval(startOffset)
    // Default location: a realistic Zoom link when meeting-like, nil otherwise.
    // Callers can override via the location parameter.
    let resolvedLocation = location ?? (isMeetingLike ? "https://zoom.us/j/1234567890" : nil)
    return EKEventDTO(
        eventIdentifier: id,
        calendarItemIdentifier: "ci-\(id)",
        calendarItemExternalIdentifier: "ext-\(id)",
        occurrenceDate: start,
        title: "Event \(id)",
        startDate: start,
        endDate: start.addingTimeInterval(durationSeconds),
        isAllDay: false,
        location: resolvedLocation,
        url: conferenceURL,
        timeZone: nil,
        notes: nil,
        status: nil,
        availability: nil,
        calendarIdentifier: "cal-1",
        calendarTitle: "Work",
        calendarColorHex: "#0066CC",
        calendarSourceTitle: "iCloud",
        birthdayContactIdentifier: nil,
        attendeeCount: isMeetingLike ? 3 : 0,
        attendees: [],
        organizer: nil
    )
}
