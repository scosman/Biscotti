import BiscottiTestSupport
import Calendar
import DataStore
import DesignSystem
import Foundation
import Testing
@testable import AppCore

// MARK: - Upcoming filtering tests

@Suite("AppCore -- displayedUpcoming filtering")
struct DisplayedUpcomingTests {
    /// Helper to create a CalendarEvent with the given start/end.
    private static func makeEvent(
        id: String = UUID().uuidString,
        title: String = "Meeting",
        start: Date,
        end: Date
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            start: start,
            end: end,
            conferencePlatform: nil,
            conferenceURL: nil,
            attendeeCount: 3,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            isMeetingLike: true
        )
    }

    @Test("ended event excluded from displayedUpcoming")
    @MainActor
    func endedEventExcluded() throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MinuteTickTests"
        )
        defer { fix.cleanup() }

        let now = Date()
        let endedEvent = Self.makeEvent(
            id: "ended",
            title: "Past Meeting",
            start: now.addingTimeInterval(-7200), // 2h ago
            end: now.addingTimeInterval(-3600) // 1h ago
        )
        let futureEvent = Self.makeEvent(
            id: "future",
            title: "Future Meeting",
            start: now.addingTimeInterval(1800),
            end: now.addingTimeInterval(5400)
        )

        // Directly set upcoming (bypassing CalendarService for unit test)
        fix.core.upcoming = [endedEvent, futureEvent]
        fix.core.setMinuteTick(now)

        let displayed = fix.core.displayedUpcoming
        #expect(displayed.count == 1)
        #expect(displayed.first?.id == "future")
    }

    @Test("in-progress event included in displayedUpcoming")
    @MainActor
    func inProgressEventIncluded() throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MinuteTickTests"
        )
        defer { fix.cleanup() }

        let now = Date()
        let inProgressEvent = Self.makeEvent(
            id: "in-progress",
            title: "Current Meeting",
            start: now.addingTimeInterval(-1800), // started 30m ago
            end: now.addingTimeInterval(1800) // ends in 30m
        )

        fix.core.upcoming = [inProgressEvent]
        fix.core.setMinuteTick(now)

        let displayed = fix.core.displayedUpcoming
        #expect(displayed.count == 1)
        #expect(displayed.first?.id == "in-progress")
    }

    @Test("advancing minuteTick past event end drops it from displayedUpcoming")
    @MainActor
    func tickAdvancePastEndDropsEvent() throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MinuteTickTests"
        )
        defer { fix.cleanup() }

        let now = Date()
        let event = Self.makeEvent(
            id: "soon-ending",
            title: "Ending Soon",
            start: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(120) // ends in 2 minutes
        )

        fix.core.upcoming = [event]
        fix.core.setMinuteTick(now)

        // Still visible
        #expect(fix.core.displayedUpcoming.count == 1)

        // Advance tick past end
        fix.core.setMinuteTick(now.addingTimeInterval(180))

        // Now filtered out
        #expect(fix.core.displayedUpcoming.isEmpty)
    }

    @Test("relative time label changes as minuteTick advances")
    @MainActor
    func relativeTimeLabelUpdatesWithTick() throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MinuteTickTests"
        )
        defer { fix.cleanup() }

        let baseTime = Date()
        let eventStart = baseTime.addingTimeInterval(2 * 60) // 2m from now

        fix.core.setMinuteTick(baseTime)

        // At baseTime, event is "in 2m"
        let text1 = TimeFormatting.relativeTimeText(
            eventStart, relativeTo: fix.core.minuteTick
        )
        #expect(text1 == "in 2m")

        // Advance tick by 1 minute
        fix.core.setMinuteTick(baseTime.addingTimeInterval(60))
        let text2 = TimeFormatting.relativeTimeText(
            eventStart, relativeTo: fix.core.minuteTick
        )
        #expect(text2 == "in 1m")

        // Advance tick past event start
        fix.core.setMinuteTick(baseTime.addingTimeInterval(150))
        let text3 = TimeFormatting.relativeTimeText(
            eventStart, relativeTo: fix.core.minuteTick
        )
        #expect(text3 == "now")
    }
}

// MARK: - Minute tick scheduling tests

@Suite("AppCore -- minute tick scheduling")
struct MinuteTickSchedulingTests {
    @Test("minute tick fires via fake scheduler")
    @MainActor
    func minuteTickFiresViaScheduler() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MinuteTickTests"
        )
        defer { fix.cleanup() }

        let scheduler = try #require(fix.fakeScheduler)

        // Complete onboarding to start background services (which
        // starts the minute tick task).
        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Wait for the minute tick task to register its sleep.
        try await pollUntil { scheduler.pendingCount >= 1 }

        #expect(scheduler.pendingCount >= 1)

        // Capture the initial minuteTick
        let initialTick = fix.core.minuteTick

        // Advance the scheduler past the sleep duration
        scheduler.advance(by: .seconds(61))

        // Wait for the tick to update minuteTick
        try await pollUntil { fix.core.minuteTick > initialTick }

        // minuteTick should have been updated
        #expect(fix.core.minuteTick > initialTick)
    }
}

// MARK: - Helpers

/// Polls a condition until true, up to 2 seconds.
private func pollUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< 40 {
        try await Task.sleep(for: .milliseconds(50))
        if await condition() { return }
    }
}
