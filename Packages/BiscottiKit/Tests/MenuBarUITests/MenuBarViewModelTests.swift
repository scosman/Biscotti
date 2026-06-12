import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MenuBarUI

// MARK: - Formatting helper tests

@Suite("MenuBarViewModel -- formatting helpers")
struct MenuBarFormattingTests {
    @Test("truncateTitle preserves short titles")
    func truncateShortTitle() {
        let result = MenuBarViewModel.truncateTitle(
            "Standup", maxLength: 20
        )
        #expect(result == "Standup")
    }

    @Test("truncateTitle truncates at word boundary with ellipsis")
    func truncateLongTitle() {
        let result = MenuBarViewModel.truncateTitle(
            "Very Long Meeting Name Here", maxLength: 15
        )
        #expect(result == "Very Long\u{2026}")
    }

    @Test("truncateTitle truncates mid-word when no spaces")
    func truncateNoSpaces() {
        let result = MenuBarViewModel.truncateTitle(
            "Superlongsingletitle", maxLength: 10
        )
        #expect(result == "Superlongs\u{2026}")
    }

    @Test("relativeTimeText formats minutes correctly")
    func relativeTimeMinutes() {
        let now = Date()
        let future = now.addingTimeInterval(5 * 60) // 5 min
        let result = MenuBarViewModel.relativeTimeText(
            future, relativeTo: now
        )
        #expect(result == "in 5m")
    }

    @Test("relativeTimeText formats hours and minutes")
    func relativeTimeHoursMinutes() {
        let now = Date()
        let future = now.addingTimeInterval(72 * 60) // 1h 12m
        let result = MenuBarViewModel.relativeTimeText(
            future, relativeTo: now
        )
        #expect(result == "in 1h 12m")
    }

    @Test("relativeTimeText returns now for past dates")
    func relativeTimePast() {
        let now = Date()
        let past = now.addingTimeInterval(-60)
        let result = MenuBarViewModel.relativeTimeText(
            past, relativeTo: now
        )
        #expect(result == "now")
    }

    @Test("relativeTimeText formats exact hours")
    func relativeTimeExactHours() {
        let now = Date()
        let future = now.addingTimeInterval(2 * 3600) // 2h
        let result = MenuBarViewModel.relativeTimeText(
            future, relativeTo: now
        )
        #expect(result == "in 2h")
    }

    @Test("isWithin2Hours returns true for 1h future")
    func isWithin2HoursTrue() {
        let now = Date()
        let future = now.addingTimeInterval(3600) // 1h
        #expect(
            MenuBarViewModel.isWithin2Hours(future, relativeTo: now)
                == true
        )
    }

    @Test("isWithin2Hours returns false for 3h future")
    func isWithin2HoursFalse() {
        let now = Date()
        let future = now.addingTimeInterval(3 * 3600) // 3h
        #expect(
            MenuBarViewModel.isWithin2Hours(future, relativeTo: now)
                == false
        )
    }

    @Test("isWithin2Hours returns false for past dates")
    func isWithin2HoursPast() {
        let now = Date()
        let past = now.addingTimeInterval(-60)
        #expect(
            MenuBarViewModel.isWithin2Hours(past, relativeTo: now)
                == false
        )
    }

    @Test("isWithin2Hours boundary: exactly 2h returns true")
    func isWithin2HoursBoundary() {
        let now = Date()
        let exactly2h = now.addingTimeInterval(2 * 3600)
        #expect(
            MenuBarViewModel.isWithin2Hours(
                exactly2h, relativeTo: now
            ) == true
        )
    }
}

// MARK: - Icon state tests

@Suite("MenuBarViewModel -- icon state")
struct MenuBarIconStateTests {
    @Test("iconState is idle when not recording and no upcoming within 2h")
    @MainActor
    func iconIdleNoUpcoming() throws {
        let fix = try makeCoreFixture(testName: "MenuBarTests")
        defer { fix.cleanup() }

        let model = MenuBarViewModel(core: fix.core)
        #expect(model.iconState == .idle)
    }

    @Test("iconState is recording when runState is recording")
    @MainActor
    func iconRecordingWhenActive() async throws {
        let fix = try makeCoreFixture(testName: "MenuBarTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let model = MenuBarViewModel(core: fix.core)
        #expect(model.iconState == .recording)
    }
}

// MARK: - Body state tests

@Suite("MenuBarViewModel -- body state")
struct MenuBarBodyTests {
    @Test("upcomingEvents limited to 2")
    @MainActor
    func upcomingLimitedTo2() async throws {
        let now = Date()
        let dtos = (0 ..< 5).map { idx in
            makeDTO(
                eventIdentifier: "ev-\(idx)",
                title: "Event \(idx)",
                start: now.addingTimeInterval(
                    Double(idx + 1) * 600
                ),
                end: now.addingTimeInterval(
                    Double(idx + 1) * 600 + 3600
                )
            )
        }

        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "MenuBarTests"
        )
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch populates upcoming
        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Verify core has >2 upcoming events loaded
        #expect(fix.core.upcoming.count > 2)

        let model = MenuBarViewModel(core: fix.core)
        // Menu bar should cap at 2
        #expect(model.upcomingEvents.count == 2)
    }

    @Test("recentMeetings limited to 2")
    @MainActor
    func recentLimitedTo2() async throws {
        let fix = try makeCoreFixture(testName: "MenuBarTests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting 1")
        _ = try await fix.store.createMeeting(title: "Meeting 2")
        _ = try await fix.store.createMeeting(title: "Meeting 3")
        await fix.core.reloadSummaries()

        let model = MenuBarViewModel(core: fix.core)
        #expect(model.recentMeetings.count == 2)
    }
}

// MARK: - Navigation action tests

@Suite("MenuBarViewModel -- navigation actions")
struct MenuBarNavigationTests {
    @Test("openEvent navigates to event route and calls windowOpener")
    @MainActor
    func openEventSetsRoute() async throws {
        let now = Date()
        let dtos = [
            makeDTO(
                eventIdentifier: "ev-1",
                title: "Team Standup",
                start: now.addingTimeInterval(600),
                end: now.addingTimeInterval(4200)
            )
        ]
        let fix = try makeCoreFixture(
            calendarEventDTOs: dtos,
            testName: "MenuBarNavTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        var windowOpened = false
        let model = MenuBarViewModel(
            core: fix.core,
            windowOpener: { windowOpened = true }
        )
        // Grab the composite key from the loaded event
        let eventKey = try #require(fix.core.upcoming.first?.id)

        model.openEvent(eventKey)

        #expect(fix.core.route == .event(eventKey))
        #expect(windowOpened)
    }

    @Test("openApp with meetingID navigates to meeting route and calls windowOpener")
    @MainActor
    func openAppMeetingRoute() async throws {
        let fix = try makeCoreFixture(
            testName: "MenuBarNavTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Test"
        )

        var windowOpened = false
        let model = MenuBarViewModel(
            core: fix.core,
            windowOpener: { windowOpened = true }
        )

        model.openApp(meetingID: meetingID)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == meetingID)
        #expect(windowOpened)
    }

    @Test("openApp without meetingID navigates to home and calls windowOpener")
    @MainActor
    func openAppHomeRoute() throws {
        let fix = try makeCoreFixture(
            testName: "MenuBarNavTests"
        )
        defer { fix.cleanup() }

        // Set an initial non-home route
        fix.core.selectEvent("ev")
        #expect(fix.core.route == .event("ev"))

        var windowOpened = false
        let model = MenuBarViewModel(
            core: fix.core,
            windowOpener: { windowOpened = true }
        )

        model.openApp()

        #expect(fix.core.route == .home)
        #expect(windowOpened)
    }
}

// MARK: - Record action icon tests

@Suite("MenuBarViewModel -- record action icon")
struct MenuBarRecordActionIconTests {
    @Test("recordActionIcon is circle.dotted.circle when idle")
    @MainActor
    func recordActionIconIdle() throws {
        let fix = try makeCoreFixture(
            testName: "MenuBarIconTests"
        )
        defer { fix.cleanup() }

        let model = MenuBarViewModel(core: fix.core)
        #expect(model.recordActionIcon == "circle.dotted.circle")
    }

    @Test("recordActionIcon is record.circle.fill when recording")
    @MainActor
    func recordActionIconRecording() async throws {
        let fix = try makeCoreFixture(
            testName: "MenuBarIconTests"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()

        let model = MenuBarViewModel(core: fix.core)
        #expect(model.recordActionIcon == "record.circle.fill")
    }
}

// MARK: - Helpers

private func makeDTO(
    eventIdentifier: String = "ev-1",
    title: String = "Standup",
    start: Date,
    end: Date,
    attendeeCount: Int = 3,
    location: String? = "https://zoom.us/j/123"
) -> EKEventDTO {
    EKEventDTO(
        eventIdentifier: eventIdentifier,
        calendarItemIdentifier: "ci-\(eventIdentifier)",
        calendarItemExternalIdentifier: "ext-\(eventIdentifier)",
        occurrenceDate: start,
        title: title,
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: location,
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
        attendeeCount: attendeeCount,
        attendees: [],
        organizer: nil
    )
}
