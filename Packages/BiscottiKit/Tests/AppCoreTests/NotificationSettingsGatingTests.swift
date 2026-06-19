import AudioCapture
import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import MeetingDetection
import Testing
@testable import AppCore

// MARK: - eventsToNotify (pure filter)

@Suite("AppCore.eventsToNotify")
struct EventsToNotifyTests {
    private func makeEvent(
        id: String = "ev-1",
        title: String = "Meeting",
        conferenceURL: URL? = nil,
        isMeetingLike: Bool = true
    ) -> CalendarEvent {
        let now = Date()
        return CalendarEvent(
            id: id,
            title: title,
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(4200),
            conferencePlatform: conferenceURL != nil ? "zoom" : nil,
            conferenceURL: conferenceURL,
            attendeeCount: 3,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            isMeetingLike: isMeetingLike
        )
    }

    @Test(".never returns empty")
    func neverReturnsEmpty() {
        let events = [
            makeEvent(id: "1", conferenceURL: URL(string: "https://zoom.us/j/1")),
            makeEvent(id: "2")
        ]
        let filtered = AppCore.eventsToNotify(events, mode: .never)
        #expect(filtered.isEmpty)
    }

    @Test(".allMeetings returns only isMeetingLike events")
    func allMeetingsFiltersMeetingLike() {
        let events = [
            makeEvent(id: "1", isMeetingLike: true),
            makeEvent(id: "2", isMeetingLike: false),
            makeEvent(id: "3", isMeetingLike: true)
        ]
        let filtered = AppCore.eventsToNotify(events, mode: .allMeetings)
        #expect(filtered.count == 2)
        #expect(filtered.map(\.id) == ["1", "3"])
    }

    @Test(".videoConferencing returns only events with conferenceURL")
    func videoConferencingFiltersURL() {
        let zoomURL = URL(string: "https://zoom.us/j/123")
        let events = [
            makeEvent(id: "with-link", conferenceURL: zoomURL),
            makeEvent(id: "no-link", conferenceURL: nil),
            makeEvent(id: "also-no-link", conferenceURL: nil, isMeetingLike: true)
        ]
        let filtered = AppCore.eventsToNotify(events, mode: .videoConferencing)
        #expect(filtered.count == 1)
        #expect(filtered[0].id == "with-link")
    }

    @Test("empty upcoming returns empty for all modes")
    func emptyUpcoming() {
        for mode in CalendarNotificationMode.allCases {
            let filtered = AppCore.eventsToNotify([], mode: mode)
            #expect(filtered.isEmpty)
        }
    }
}

// MARK: - Detection gating (monitorForMeetings)

@Suite("AppCore -- detection notification gating")
struct DetectionNotificationGatingTests {
    @Test("detection suppressed when monitorForMeetings is off")
    @MainActor
    func detectionSuppressedWhenMonitorOff() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "MonitorGate"
        )
        defer { fix.cleanup() }

        // Set monitorForMeetings = false before launch
        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
            settings.monitorForMeetings = false
        }
        await fix.core.onLaunch()
        #expect(fix.core.runState == .idle)
        #expect(fix.core.monitorForMeetings == false)

        let requestsBefore = fix.fakeNotificationCenter.addedRequests.count

        // Emit audio snapshot with Zoom doing input+output
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])

        // Give consumer time to process
        try await Task.sleep(for: .milliseconds(300))

        // Should still be idle (no detectedPending transition)
        #expect(fix.core.runState == .idle)
        // No notification should have been presented
        #expect(fix.fakeNotificationCenter.addedRequests.count == requestsBefore)
    }

    @Test("detection works when monitorForMeetings is on (default)")
    @MainActor
    func detectionWorksWhenMonitorOn() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "MonitorGate"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
            settings.monitorForMeetings = true
        }
        await fix.core.onLaunch()
        #expect(fix.core.monitorForMeetings == true)

        let requestsBefore = fix.fakeNotificationCenter.addedRequests.count

        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])

        try await pollUntil { fix.core.runState == .detectedPending }
        #expect(fix.core.runState == .detectedPending)
        #expect(fix.fakeNotificationCenter.addedRequests.count > requestsBefore)
    }
}

// MARK: - Auto-stop gating (stopRecordingAutomatically)

@Suite("AppCore -- auto-stop gating")
struct AutoStopGatingTests {
    @Test("auto-stop suppressed when stopRecordingAutomatically is off")
    @MainActor
    func autoStopSuppressedWhenOff() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "AutoStopGate"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
            settings.stopRecordingAutomatically = false
        }
        await fix.core.onLaunch()
        #expect(fix.core.stopRecordingAutomatically == false)

        // Start recording with Zoom active
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

        let baselinePending = fakeScheduler.pendingCount

        // Zoom stops -- allMicUsersStopped fires
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])

        // Give consumer time to process
        try await Task.sleep(for: .milliseconds(300))

        // No countdown should have started
        #expect(fakeScheduler.pendingCount == baselinePending)
        #expect(fix.core.autoStop == nil)
        #expect(fix.core.recording.state.isRecording == true)

        _ = await fix.core.stopRecording()
    }

    @Test("auto-stop works when stopRecordingAutomatically is on (default)")
    @MainActor
    func autoStopWorksWhenOn() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "AutoStopGate"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
            settings.stopRecordingAutomatically = true
        }
        await fix.core.onLaunch()
        #expect(fix.core.stopRecordingAutomatically == true)

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

        // Zoom stops
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])

        // Countdown should start
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        #expect(fix.core.autoStop != nil)

        _ = await fix.core.stopRecording()
    }
}

// MARK: - Notification settings loading

@Suite("AppCore -- notification settings loading")
struct NotificationSettingsLoadingTests {
    @Test("onLaunch loads notification settings from store")
    @MainActor
    func onLaunchLoadsSettings() async throws {
        let fix = try makeCoreFixture(testName: "NotifSettingsLoad")
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
            settings.monitorForMeetings = false
            settings.stopRecordingAutomatically = false
            settings.calendarNotificationMode = .videoConferencing
        }

        await fix.core.onLaunch()

        #expect(fix.core.monitorForMeetings == false)
        #expect(fix.core.stopRecordingAutomatically == false)
        #expect(fix.core.calendarNotificationMode == .videoConferencing)
    }

    @Test("default values when settings not explicitly set")
    @MainActor
    func defaultValues() async throws {
        let fix = try makeCoreFixture(testName: "NotifSettingsLoad")
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
        }

        await fix.core.onLaunch()

        #expect(fix.core.monitorForMeetings == true)
        #expect(fix.core.stopRecordingAutomatically == true)
        #expect(fix.core.calendarNotificationMode == .allMeetings)
    }
}

// MARK: - Cancel ad-hoc on record start

@Suite("AppCore -- cancel ad-hoc on record start")
struct CancelAdHocOnRecordStartTests {
    @Test("startRecording dismisses lingering ad-hoc notifications")
    @MainActor
    func startRecordingDismissesAdHoc() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "CancelAdHoc"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit audio snapshot so a meeting is detected.
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }

        // An ad-hoc notification should have been presented.
        let adHocRequests = fix.fakeNotificationCenter.addedRequests.filter {
            $0.content.categoryIdentifier == "biscotti.ad-hoc-detected"
        }
        #expect(!adHocRequests.isEmpty)

        let removedBefore = fix.fakeNotificationCenter.backing.removedPendingIDs.count

        // Start recording -- should cancel the ad-hoc notification.
        await fix.core.startRecording()

        let removedAfter = fix.fakeNotificationCenter.backing.removedPendingIDs
        #expect(removedAfter.count > removedBefore)

        // The ad-hoc notification ID should be in the removed list.
        let adHocID = adHocRequests[0].identifier
        #expect(removedAfter.contains(adHocID))

        _ = await fix.core.stopRecording()
    }
}
