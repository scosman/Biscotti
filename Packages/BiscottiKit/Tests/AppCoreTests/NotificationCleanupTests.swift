import AudioCapture
import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import MeetingDetection
import Notifications
import Testing
@testable import AppCore

// MARK: - C1: Calendar notification expiry

@Suite("AppCore -- C1 calendar notification expiry")
struct CalendarNotificationExpiryTests {
    @Test("calendar notification removed after 300s")
    @MainActor
    func calendarNotificationRemovedAfterExpiry() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Standup",
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(3600)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            useFakeScheduler: true,
            testName: "C1Expiry"
        )
        defer { fix.cleanup() }
        let fakeScheduler = try #require(fix.fakeScheduler)

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Fire the calendar-start timer.
        fakeScheduler.advance(by: .seconds(65))
        try await pollUntil {
            !fix.fakeNotificationCenter.addedRequests.isEmpty
        }

        let postedID = try #require(
            fix.fakeNotificationCenter.addedRequests
                .first {
                    $0.content.categoryIdentifier
                        .contains("meeting-starting")
                }?.identifier
        )

        // Notification should NOT be removed yet.
        #expect(
            !fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        )

        // The expiry delay is computed from wall-clock Date(), so the
        // fake scheduler needs enough total advance to cover the full
        // ~360s (start + 60 + lifetime 300) from the wall-clock
        // perspective. Advance 365s more to be safe.
        fakeScheduler.advance(by: .seconds(365))
        try await pollUntil {
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        }

        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        )
    }

    @Test("C1 expiry survives calendar refresh (not cancelled by scheduleCalendarTimers)")
    @MainActor
    func expiryNotCancelledByCalendarRefresh() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Standup",
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(3600)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            useFakeScheduler: true,
            testName: "C1Refresh"
        )
        defer { fix.cleanup() }
        let fakeScheduler = try #require(fix.fakeScheduler)

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Fire calendar-start timer.
        fakeScheduler.advance(by: .seconds(65))
        try await pollUntil {
            !fix.fakeNotificationCenter.addedRequests.isEmpty
        }
        let postedID = try #require(
            fix.fakeNotificationCenter.addedRequests
                .first {
                    $0.content.categoryIdentifier
                        .contains("meeting-starting")
                }?.identifier
        )

        // Simulate a calendar refresh by clearing upcoming events.
        // This triggers scheduleCalendarTimers() via the mirror task.
        fix.fakeEventStore.eventDTOs = []
        let refreshNow = Date()
        await fix.calendarService.refreshUpcoming(
            window: DateInterval(
                start: refreshNow,
                end: refreshNow.addingTimeInterval(86400)
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        // Advance past the expiry -- the notification should still be
        // removed because calendarNotificationExpiryTasks is separate
        // from calendarTimerTasks.
        fakeScheduler.advance(by: .seconds(365))
        try await pollUntil {
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        }
        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        )
    }
}

// MARK: - C1: shouldPostCalendarNotification (pure)

@Suite("AppCore -- shouldPostCalendarNotification")
struct ShouldPostCalendarNotificationTests {
    @Test("true at event start")
    func trueAtStart() {
        let start = Date()
        #expect(
            AppCore.shouldPostCalendarNotification(
                eventStart: start, now: start
            )
        )
    }

    @Test("true at start + 299s")
    func trueBeforeExpiry() {
        let start = Date()
        #expect(
            AppCore.shouldPostCalendarNotification(
                eventStart: start,
                now: start.addingTimeInterval(299)
            )
        )
    }

    @Test("false at start + 300s")
    func falseAtExpiry() {
        let start = Date()
        #expect(
            !AppCore.shouldPostCalendarNotification(
                eventStart: start,
                now: start.addingTimeInterval(300)
            )
        )
    }

    @Test("false well after expiry")
    func falseWellAfter() {
        let start = Date()
        #expect(
            !AppCore.shouldPostCalendarNotification(
                eventStart: start,
                now: start.addingTimeInterval(600)
            )
        )
    }
}

// MARK: - C2: Recording start removes calendar notifications

@Suite("AppCore -- C2 recording start removes calendar notifications")
struct RecordingStartCancelCalendarTests {
    @Test("startRecording removes calendar notification and cancels expiry")
    @MainActor
    func startRecordingRemovesCalendar() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Standup",
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(3600)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            useFakeScheduler: true,
            testName: "C2"
        )
        defer { fix.cleanup() }
        let fakeScheduler = try #require(fix.fakeScheduler)

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Fire calendar-start timer.
        fakeScheduler.advance(by: .seconds(65))
        try await pollUntil {
            !fix.fakeNotificationCenter.addedRequests.isEmpty
        }

        let postedID = try #require(
            fix.fakeNotificationCenter.addedRequests
                .first {
                    $0.content.categoryIdentifier
                        .contains("meeting-starting")
                }?.identifier
        )

        // Start recording.
        await fix.core.startRecording()

        // The calendar notification should be removed via
        // cancelAllMeetingStarting().
        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(postedID)
        )

        // The expiry task was cancelled. Advancing past the expiry
        // should NOT produce another removal for the same ID.
        let removedCountAfterStart = fix.fakeNotificationCenter
            .backing.removedDeliveredIDs.count
        fakeScheduler.advance(by: .seconds(400))
        try await Task.sleep(for: .milliseconds(100))

        // Count should not increase (expiry task was cancelled).
        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .count == removedCountAfterStart
        )

        _ = await fix.core.stopRecording()
    }
}

// MARK: - D1: Detection stopped removes ad-hoc notification

@Suite("AppCore -- D1 detection stopped removes ad-hoc")
struct DetectionStoppedCancelAdHocTests {
    @Test("detector .stopped removes that app's ad-hoc notification")
    @MainActor
    func stoppedRemovesAdHoc() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "D1"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit Zoom in-call -> detectedPending.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }

        let adHocID = "biscotti.notif.adhoc.us.zoom.xos"

        // Zoom stops.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil { fix.core.runState == .idle }

        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains(adHocID)
        )
    }

    @Test("only the stopped app's notification is removed")
    @MainActor
    func onlyStoppedAppRemoved() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "D1Multi"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit two apps.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            ),
            makeAudioProcess(
                bundleID: "com.microsoft.teams2",
                input: true, output: true,
                pid: 2
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }

        // Stop only Zoom.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "com.microsoft.teams2",
                input: true, output: true,
                pid: 2
            )
        ])
        try await pollUntil {
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains("biscotti.notif.adhoc.us.zoom.xos")
        }

        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains("biscotti.notif.adhoc.us.zoom.xos")
        )
        // Teams' notification should NOT be removed.
        #expect(
            !fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains("biscotti.notif.adhoc.com.microsoft.teams2")
        )
    }

    @Test("D1 while recording still calls remove for the stopped app")
    @MainActor
    func d1WhileRecording() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "D1Recording"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit Zoom in-call -> detectedPending -> start recording.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }
        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        let adHocID = "biscotti.notif.adhoc.us.zoom.xos"

        // Count how many times the ad-hoc ID appears BEFORE Zoom stops.
        // The bulk cancelAdHocDetected() in startRecording already added
        // one occurrence.
        let countBefore = fix.fakeNotificationCenter.backing
            .removedDeliveredIDs.count(where: { $0 == adHocID })

        // Zoom stops while recording.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])

        // D1 fires cancelAdHocDetected(bundleID:) which adds another
        // occurrence of the ad-hoc ID to removedDeliveredIDs.
        try await pollUntil {
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .count(where: { $0 == adHocID }) > countBefore
        }

        let countAfter = fix.fakeNotificationCenter.backing
            .removedDeliveredIDs.count(where: { $0 == adHocID })
        #expect(countAfter > countBefore)

        _ = await fix.core.stopRecording()
    }
}

// MARK: - L1: Launch cleanup plan (pure)

@Suite("AppCore -- L1 launch cleanup plan")
struct LaunchCleanupPlanTests {
    @Test("ad-hoc always in remove list")
    func adHocAlwaysRemoved() {
        let plan = AppCore.launchNotificationCleanupPlan(
            [.adHocDetected(bundleID: "us.zoom.xos")],
            now: Date()
        )
        #expect(plan.adHocBundleIDsToRemove == ["us.zoom.xos"])
        #expect(plan.meetingEventKeysToRemove.isEmpty)
        #expect(plan.meetingExpiriesToSchedule.isEmpty)
    }

    @Test("expired meeting-start in remove list")
    func expiredMeetingStartRemoved() {
        let now = Date()
        let oldStart = now.addingTimeInterval(-600) // 10 min ago
        let plan = AppCore.launchNotificationCleanupPlan(
            [.meetingStarting(eventKey: "ev-1", meetingStart: oldStart)],
            now: now
        )
        #expect(plan.meetingEventKeysToRemove == ["ev-1"])
        #expect(plan.meetingExpiriesToSchedule.isEmpty)
    }

    @Test("fresh meeting-start in schedule list")
    func freshMeetingStartScheduled() {
        let now = Date()
        let recentStart = now.addingTimeInterval(-120) // 2 min ago
        let plan = AppCore.launchNotificationCleanupPlan(
            [.meetingStarting(
                eventKey: "ev-1", meetingStart: recentStart
            )],
            now: now
        )
        #expect(plan.meetingEventKeysToRemove.isEmpty)
        #expect(plan.meetingExpiriesToSchedule.count == 1)
        let scheduled = plan.meetingExpiriesToSchedule[0]
        #expect(scheduled.eventKey == "ev-1")
        // expiry = recentStart + 300 = now + 180
        let expectedExpiry = recentStart.addingTimeInterval(300)
        #expect(
            abs(
                scheduled.expiry.timeIntervalSince1970
                    - expectedExpiry.timeIntervalSince1970
            ) < 0.001
        )
    }

    @Test("boundary: expiry == now means remove")
    func boundaryExpiryEqualsNow() {
        let now = Date()
        let startAtBoundary = now.addingTimeInterval(-300)
        let plan = AppCore.launchNotificationCleanupPlan(
            [.meetingStarting(
                eventKey: "ev-1", meetingStart: startAtBoundary
            )],
            now: now
        )
        #expect(plan.meetingEventKeysToRemove == ["ev-1"])
        #expect(plan.meetingExpiriesToSchedule.isEmpty)
    }

    @Test("mixed input produces correct three lists")
    func mixedInput() {
        let now = Date()
        let plan = AppCore.launchNotificationCleanupPlan(
            [
                .adHocDetected(bundleID: "us.zoom.xos"),
                .meetingStarting(
                    eventKey: "old",
                    meetingStart: now.addingTimeInterval(-600)
                ),
                .meetingStarting(
                    eventKey: "fresh",
                    meetingStart: now.addingTimeInterval(-60)
                )
            ],
            now: now
        )
        #expect(plan.adHocBundleIDsToRemove == ["us.zoom.xos"])
        #expect(plan.meetingEventKeysToRemove == ["old"])
        #expect(plan.meetingExpiriesToSchedule.count == 1)
        #expect(plan.meetingExpiriesToSchedule[0].eventKey == "fresh")
    }
}

// MARK: - L1: Launch cleanup integration

@Suite("AppCore -- L1 launch cleanup integration")
struct LaunchCleanupIntegrationTests {
    @Test("onLaunch removes stale notifications and schedules fresh expiry")
    @MainActor
    func launchCleansUp() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "L1Integration"
        )
        defer { fix.cleanup() }
        let fakeScheduler = try #require(fix.fakeScheduler)

        let now = Date()
        fix.fakeNotificationCenter.backing.delivered =
            makeLaunchCleanupSeed(now: now)

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let removed = fix.fakeNotificationCenter.backing
            .removedDeliveredIDs

        // Ad-hoc and expired meeting-start should be removed.
        #expect(removed.contains("biscotti.notif.adhoc.us.zoom.xos"))
        #expect(
            removed.contains("biscotti.notif.meeting-start.old-ev")
        )

        // Countdown should NOT be removed.
        #expect(!removed.contains("biscotti.notif.countdown.xxx"))

        // Fresh meeting-start should NOT be removed yet.
        #expect(
            !removed.contains("biscotti.notif.meeting-start.fresh-ev")
        )

        // Advance past the remaining expiry (~180s from wall clock).
        fakeScheduler.advance(by: .seconds(185))
        try await pollUntil {
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains("biscotti.notif.meeting-start.fresh-ev")
        }

        #expect(
            fix.fakeNotificationCenter.backing.removedDeliveredIDs
                .contains("biscotti.notif.meeting-start.fresh-ev")
        )
    }
}

/// Build the seed array for the L1 launch-cleanup integration test.
private func makeLaunchCleanupSeed(
    now: Date
) -> [DeliveredNotification] {
    [
        DeliveredNotification(
            identifier: "biscotti.notif.adhoc.us.zoom.xos",
            date: now,
            userInfo: [
                "biscotti.kind": "ad-hoc",
                "biscotti.bundleID": "us.zoom.xos"
            ]
        ),
        DeliveredNotification(
            identifier: "biscotti.notif.meeting-start.old-ev",
            date: now.addingTimeInterval(-600),
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": "old-ev",
                "biscotti.eventStart": String(
                    now.addingTimeInterval(-600).timeIntervalSince1970
                )
            ]
        ),
        DeliveredNotification(
            identifier: "biscotti.notif.meeting-start.fresh-ev",
            date: now.addingTimeInterval(-120),
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": "fresh-ev",
                "biscotti.eventStart": String(
                    now.addingTimeInterval(-120).timeIntervalSince1970
                )
            ]
        ),
        DeliveredNotification(
            identifier: "biscotti.notif.countdown.xxx",
            date: now,
            userInfo: [
                "biscotti.kind": "countdown",
                "biscotti.meetingID": UUID().uuidString
            ]
        )
    ]
}

// MARK: - Helpers

private func makeMeetingDTO(
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
