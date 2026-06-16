import AudioCapture
import BiscottiTestSupport
import Calendar
import CoreAudio
import DataStore
import Foundation
import MeetingDetection
import Notifications
import Permissions
import Recording
import Testing
import Transcription
import TranscriptionService
@testable import AppCore

// MARK: - Detection pipeline (fakeActivitySource -> MeetingDetector -> AppCore)

@Suite("AppCore -- detection pipeline")
struct AppCoreDetectionPipelineTests {
    @Test("detection started presents ad-hoc notification and sets detectedPending")
    @MainActor
    func detectionStartedPresentsNotification() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()
        #expect(fix.core.runState == .idle)

        let requestsBefore = fix.fakeNotificationCenter.addedRequests.count

        // Emit audio snapshot with Zoom doing input+output (in-call)
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])

        // ImmediateClock makes debounce fire immediately; poll for state
        try await pollUntil { fix.core.runState == .detectedPending }

        #expect(fix.core.runState == .detectedPending)

        // An ad-hoc notification should have been presented
        let requestsAfter = fix.fakeNotificationCenter.addedRequests.count
        #expect(requestsAfter > requestsBefore)
    }

    @Test("ad-hoc detection suppressed while already recording")
    @MainActor
    func suppressedWhileRecording() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start a manual recording first
        await fix.core.startRecording()
        #expect(fix.core.recording.state.isRecording == true)
        let meetingID = fix.core.recording.state.meetingID

        let requestsBefore = fix.fakeNotificationCenter.addedRequests.count

        // Emit Zoom in-call snapshot
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])

        // Give consumer time to process
        try await Task.sleep(for: .milliseconds(200))

        // Should still be recording the original meeting
        #expect(fix.core.recording.state.meetingID == meetingID)

        // No new notification (suppressed by recording guard)
        let requestsAfter = fix.fakeNotificationCenter.addedRequests.count
        #expect(requestsAfter == requestsBefore)
    }

    @Test("ad-hoc detection suppressed within calendar suppression window")
    @MainActor
    func suppressedAfterCalendarPrompt() async throws {
        let now = Date()
        // Create a meeting starting in 1 second so the calendar timer fires
        let dto = makeMeetingDTO(
            title: "Imminent Meeting",
            start: now.addingTimeInterval(1),
            end: now.addingTimeInterval(3600)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Fire the calendar-start timer and poll until the MainActor
        // task that posts the calendar notification runs.
        fakeScheduler.advance(by: .seconds(2))
        try await pollUntil {
            !fix.fakeNotificationCenter.addedRequests.isEmpty
        }

        let requestsAfterCal = fix.fakeNotificationCenter
            .addedRequests.count
        #expect(requestsAfterCal > 0) // calendar notification posted

        // Now emit a Zoom detection -- should be suppressed by de-dup
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await Task.sleep(for: .milliseconds(200))

        // Should NOT have transitioned to detectedPending
        #expect(fix.core.runState == .idle)
    }

    @Test("detectedPending reverts to idle when detected app stops")
    @MainActor
    func detectedPendingRevertsOnStop() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit Zoom in-call
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }
        #expect(fix.core.runState == .detectedPending)

        // Now emit Zoom idle (no input/output)
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])

        // Wait for stop debounce + consumer
        try await pollUntil { fix.core.runState == .idle }
        #expect(fix.core.runState == .idle)
    }
}

// MARK: - Detection pipeline: auto-stop + countdown

@Suite("AppCore -- detection auto-stop")
struct AppCoreDetectionAutoStopTests {
    @Test("auto-stop countdown fires after 10s when last mic user stops during recording")
    @MainActor
    func autoStopCountdownFiresAndStops() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Emit Zoom in-call -> detectedPending
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }

        // User taps "Record" via notification action
        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording state")
            return
        }
        #expect(fix.core.recording.state.isRecording == true)

        // Now Zoom's audio stops -- allMicUsersStopped fires,
        // triggering auto-stop countdown
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil {
            fakeScheduler.pendingCount > 0
        }
        #expect(fakeScheduler.pendingCount > 0)

        // Single 10s sleep for the countdown (no per-second loop)
        fakeScheduler.advance(by: .seconds(10))
        try await pollUntil { fix.core.runState == .idle }

        // Auto-stop should have fired: recording stopped
        #expect(fix.core.runState == .idle)
        #expect(fix.core.recording.state.isRecording == false)
    }

    @Test("keepRecording cancels an active auto-stop countdown")
    @MainActor
    func keepRecordingCancelsActiveCountdown() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Drive detection -> recording -> mic stop -> countdown
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await pollUntil { fix.core.runState == .detectedPending }
        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case let .recording(meetingID) = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        // All mic users stop -> triggers countdown
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil { fakeScheduler.pendingCount > 0 }

        // User taps "Keep Recording" via notification action
        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.stop-countdown",
            actionID: "biscotti.action.keep-recording",
            userInfo: [
                "biscotti.kind": "countdown",
                "biscotti.meetingID": meetingID.uuidString
            ]
        )

        // Wait for the action to be consumed
        try await Task.sleep(for: .milliseconds(200))

        // Advance past 10s -- countdown should have been cancelled
        fakeScheduler.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(100))

        // Should STILL be recording
        #expect(fix.core.recording.state.isRecording == true)
        if case .recording = fix.core.runState {
            // Good -- keepRecording prevented auto-stop
        } else {
            Issue.record("Expected still recording")
        }

        // Clean up
        _ = await fix.core.stopRecording()
    }

    @Test("manual recording auto-stops when last non-self mic user stops")
    @MainActor
    func manualRecordingAutoStopsOnMicUserStop() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start a MANUAL recording (not detection-driven)
        await fix.core.startRecording()
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        // Emit another app using mic, then have it stop
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await Task.sleep(for: .milliseconds(200))
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])

        // allMicUsersStopped fires -> countdown begins
        try await pollUntil {
            fakeScheduler.pendingCount > 0
        }

        // Advance past the 10s countdown
        fakeScheduler.advance(by: .seconds(10))
        try await pollUntil { fix.core.runState == .idle }

        // Auto-stop should have fired
        #expect(fix.core.runState == .idle)
        #expect(fix.core.recording.state.isRecording == false)
    }

    @Test("no auto-stop while another mic user remains active")
    @MainActor
    func noAutoStopWhileMicUserRemains() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start detection-driven recording via Zoom
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

        // Capture baseline pending count (minute-tick may have registered)
        let baselinePending = fakeScheduler.pendingCount

        // A DIFFERENT app (Teams) starts and stops -- Zoom is still active
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            ),
            makeAudioProcess(
                bundleID: "com.microsoft.teams2",
                input: true, output: true
            )
        ])
        try await Task.sleep(for: .milliseconds(200))
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            )
        ])
        try await Task.sleep(for: .milliseconds(200))

        // No countdown -- Zoom still has mic input, allMicUsersStopped hasn't fired
        #expect(fakeScheduler.pendingCount == baselinePending)
        #expect(fix.core.recording.state.isRecording == true)

        _ = await fix.core.stopRecording()
    }
}

// MARK: - Mic-user auto-stop (broad trigger)

@Suite("AppCore -- mic-user auto-stop")
struct AppCoreMicUserAutoStopTests {
    @Test("no auto-stop for recording that never had another mic user")
    @MainActor
    func noAutoStopWithoutMicUsers() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let baselinePending = fakeScheduler.pendingCount

        // Start a manual recording with no other mic users present
        await fix.core.startRecording()
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        // Emit empty snapshots (no mic users at all)
        fix.fakeActivitySource.emit([])
        try await Task.sleep(for: .milliseconds(200))
        fix.fakeActivitySource.emit([])
        try await Task.sleep(for: .milliseconds(200))

        // No countdown -- there was no >=1 -> 0 mic user transition
        #expect(fakeScheduler.pendingCount == baselinePending)
        #expect(fix.core.recording.state.isRecording == true)

        _ = await fix.core.stopRecording()
    }

    @Test("Biscotti's own process is excluded from mic user tracking")
    @MainActor
    func selfProcessExcludedFromMicUsers() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start recording while Zoom is using mic
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: true, output: true
            ),
            makeAudioProcess(
                bundleID: "net.scosman.biscotti",
                input: true, output: false, pid: 99
            )
        ])
        try await Task.sleep(for: .milliseconds(200))
        await fix.core.startRecording()
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording")
            return
        }

        let baselinePending = fakeScheduler.pendingCount

        // Zoom stops but Biscotti still has mic -- should still trigger
        // auto-stop because Biscotti is excluded from mic user tracking
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "net.scosman.biscotti",
                input: true, output: false, pid: 99
            )
        ])

        // allMicUsersStopped should fire (only Biscotti remains, which
        // is excluded) -> countdown begins
        try await pollUntil {
            fakeScheduler.pendingCount > baselinePending
        }
        #expect(fakeScheduler.pendingCount > baselinePending)

        _ = await fix.core.stopRecording()
    }

    @Test("auto-stop presents single notification, no per-second updates")
    @MainActor
    func singleNotificationNoPerSecondUpdates() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            useImmediateDetectorClock: true,
            testName: "Pipeline"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        // Start recording while Zoom has mic
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

        let requestsBefore = fix.fakeNotificationCenter.addedRequests.count

        // Zoom stops -> countdown begins
        fix.fakeActivitySource.emit([
            makeAudioProcess(
                bundleID: "us.zoom.xos",
                input: false, output: false
            )
        ])
        try await pollUntil {
            fakeScheduler.pendingCount > 0
        }

        // Wait for notification to be posted
        try await pollUntil {
            fix.fakeNotificationCenter.addedRequests.count > requestsBefore
        }

        let countdownRequests = fix.fakeNotificationCenter
            .addedRequests[requestsBefore...]
        // Exactly ONE countdown notification, not per-second updates
        #expect(countdownRequests.count == 1)
        #expect(countdownRequests.first?.content.title.contains("10") == true)

        // Advance time partially -- no new notifications should appear
        fakeScheduler.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(100))

        let countdownRequestsAfter = fix.fakeNotificationCenter
            .addedRequests[requestsBefore...]
        #expect(countdownRequestsAfter.count == 1)

        // Finish countdown
        fakeScheduler.advance(by: .seconds(10))
        try await pollUntil { fix.core.runState == .idle }
    }
}

// MARK: - Notification action dispatch

@Suite("AppCore -- notification action dispatch")
struct AppCoreNotificationActionTests {
    @Test("notification action record starts recording via stream")
    @MainActor
    func notificationActionRecordStartsRecording() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true, testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()
        #expect(fix.core.runState == .idle)

        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.ad-hoc-detected",
            actionID: "biscotti.action.record",
            userInfo: [
                "biscotti.kind": "ad-hoc",
                "biscotti.bundleID": "us.zoom.xos"
            ]
        )

        try await pollUntil {
            fix.core.recording.state.isRecording
        }

        #expect(fix.core.recording.state.isRecording == true)
        if case .recording = fix.core.runState {
            // Good
        } else {
            Issue.record("Expected .recording, got \(fix.core.runState)")
        }
    }

    @Test("notification action openAndRecord for calendar event associates correctly")
    @MainActor
    func notificationOpenAndRecordForCalendarEvent() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Design Review",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            useFakeScheduler: true,
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let eventKey = fix.core.upcoming.first?.id

        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.meeting-starting",
            actionID: "biscotti.action.open-and-record",
            userInfo: [
                "biscotti.kind": "meeting-starting",
                "biscotti.eventKey": eventKey ?? ""
            ]
        )

        try await pollUntil {
            fix.core.recording.state.isRecording
        }

        #expect(fix.core.recording.state.isRecording == true)

        guard let meetingID = fix.core.recording.state.meetingID
        else {
            Issue.record("Expected meeting ID")
            return
        }

        // The calendar association is persisted asynchronously after
        // isRecording flips true; poll until it lands.
        var detail: MeetingDetailData?
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(50))
            detail = try await fix.store.meetingDetail(id: meetingID)
            if detail?.calendar != nil { break }
        }
        #expect(detail?.calendar?.title == "Design Review")
    }

    @Test("recordDetectedEvent starts recording")
    @MainActor
    func recordDetectedEventStartsRecording() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.recordDetectedEvent(eventKey: nil)
        #expect(fix.core.recording.state.isRecording == true)
    }

    @Test("recordDetectedEvent with explicit key associates event")
    @MainActor
    func recordDetectedEventExplicitKey() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Standup",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        let eventKey = fix.core.upcoming.first?.id
        await fix.core.recordDetectedEvent(eventKey: eventKey)

        guard let meetingID = fix.core.recording.state.meetingID
        else {
            Issue.record("Expected meeting ID")
            return
        }

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar?.title == "Standup")
    }

    @Test("one recording at a time rejects second start")
    @MainActor
    func oneRecordingAtATimeRejectsSecondStart() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.recording.state.isRecording == true)
        let firstMeetingID = fix.core.recording.state.meetingID

        await fix.core.startRecording()
        #expect(fix.core.recording.state.meetingID == firstMeetingID)
    }
}

// MARK: - Run state transitions

@Suite("AppCore -- run state transitions")
struct AppCoreRunStateTests {
    @Test("manual flow: idle -> recording -> idle")
    @MainActor
    func runStateManualFlow() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        #expect(fix.core.runState == .idle)

        await fix.core.startRecording()
        if case .recording = fix.core.runState {
            // Good
        } else {
            Issue.record("Expected .recording, got \(fix.core.runState)")
        }

        _ = await fix.core.stopRecording()
        #expect(fix.core.runState == .idle)
    }

    @Test("stopRecording clears detection state")
    @MainActor
    func stopRecordingClearsDetectionState() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.recordDetectedEvent(eventKey: nil)
        if case .recording = fix.core.runState {
            // Good
        } else {
            Issue.record("Expected .recording after recordDetectedEvent")
        }

        _ = await fix.core.stopRecording()
        #expect(fix.core.runState == .idle)
    }

    @Test("startRecording from idle transitions to recording with correct meetingID")
    @MainActor
    func startRecordingTransitionsCorrectly() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        if case let .recording(meetingID) = fix.core.runState {
            #expect(meetingID == fix.core.recording.state.meetingID)
        } else {
            Issue.record("Expected .recording")
        }
    }

    @Test("recordDetectedEvent then stop resets all detection state")
    @MainActor
    func recordDetectedEventThenStopResets() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.recordDetectedEvent(eventKey: nil)
        if case .recording = fix.core.runState {
            #expect(fix.core.recording.state.isRecording == true)
        } else {
            Issue.record("Expected .recording")
        }

        _ = await fix.core.stopRecording()
        #expect(fix.core.runState == .idle)
    }
}

// MARK: - Auto-stop countdown

@Suite("AppCore -- auto-stop countdown")
struct AppCoreAutoStopTests {
    @Test("stopRecording cancels countdown and cleans up notification")
    @MainActor
    func stopRecordingCancelsCountdownAndNotification() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true, testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case .recording = fix.core.runState else {
            Issue.record("Expected recording state")
            return
        }

        _ = await fix.core.stopRecording()

        // cancelAutoStopCountdown removes pending + delivered countdown
        // notifications via a fire-and-forget Task (see note in AppCore)
        let removedIDs = fix.fakeNotificationCenter.backing.removedPendingIDs
        #expect(fix.core.runState == .idle)
        #expect(!removedIDs.isEmpty)
    }

    @Test("stopRecording saves meeting in summaries")
    @MainActor
    func stopRecordingSavesMeeting() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true, testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.recordDetectedEvent(eventKey: nil)
        guard case let .recording(meetingID) = fix.core.runState else {
            Issue.record("Expected recording state")
            return
        }

        _ = await fix.core.stopRecording()
        #expect(fix.core.runState == .idle)
        #expect(fix.core.summaries.contains { $0.id == meetingID })
    }
}

// MARK: - Onboarding gate

@Suite("AppCore -- onboarding gate")
struct AppCoreOnboardingGateTests {
    @Test("onLaunch with incomplete onboarding routes to onboarding")
    @MainActor
    func onboardingGateSkipsDetection() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)
    }

    @Test("onLaunch with complete onboarding routes to home")
    @MainActor
    func onboardingCompleteRoutesToHome() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()
        #expect(fix.core.route == .home)
    }

    @Test("onLaunch with complete onboarding loads upcoming events")
    @MainActor
    func onboardingCompleteLoadsUpcoming() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Future Meeting",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(4200)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        #expect(fix.core.route == .home)
        #expect(fix.core.upcoming.count == 1)
        #expect(fix.core.upcoming.first?.title == "Future Meeting")
    }

    @Test("completeOnboarding starts background services")
    @MainActor
    func completeOnboardingStartsServices() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)

        await fix.core.completeOnboarding()
        #expect(fix.core.route == .home)

        let settings = try await fix.store.settings()
        #expect(settings.onboardingComplete == true)
    }

    @Test("completeOnboarding loads upcoming calendar events")
    @MainActor
    func completeOnboardingLoadsCalendar() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "After Onboarding",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(4200)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)
        #expect(fix.core.upcoming.isEmpty)

        await fix.core.completeOnboarding()
        #expect(fix.core.route == .home)
        #expect(fix.core.upcoming.count == 1)
        #expect(fix.core.upcoming.first?.title == "After Onboarding")
    }
}

// MARK: - Search return route

@Suite("AppCore -- search return route")
struct AppCoreSearchReturnRouteTests {
    @Test("setMeetingsQuery non-empty routes to .meetings")
    @MainActor
    func setMeetingsQueryRoutesToMeetings() throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        fix.core.setMeetingsQuery("test")
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsQuery == "test")
    }

    @Test("setMeetingsQuery empty clears results")
    @MainActor
    func setMeetingsQueryEmptyClearsResults() throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        fix.core.setMeetingsQuery("test")
        fix.core.setMeetingsQuery("")
        #expect(fix.core.meetingsResults.isEmpty)
        #expect(fix.core.isSearchingMeetings == false)
    }
}

// MARK: - Recording with run state

@Suite("AppCore -- recording with run state")
struct AppCoreRecordingRunStateTests {
    @Test("startRecording sets runState to .recording with correct ID")
    @MainActor
    func startRecordingSetsRunState() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        if case let .recording(meetingID) = fix.core.runState {
            #expect(meetingID == fix.core.recording.state.meetingID)
        } else {
            Issue.record("Expected .recording")
        }
    }

    @Test("stopRecording resets runState to .idle")
    @MainActor
    func stopRecordingResetsRunState() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        _ = await fix.core.stopRecording()
        #expect(fix.core.runState == .idle)
    }

    @Test("startRecording no-ops when already recording")
    @MainActor
    func startRecordingGuardsRunState() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let firstID = fix.core.recording.state.meetingID

        await fix.core.startRecording()
        #expect(fix.core.recording.state.meetingID == firstID)
    }

    @Test("quit while recording stops and saves")
    @MainActor
    func quitWhileRecordingStopsAndSaves() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.recording.state.isRecording == true)

        let meetingID = await fix.core.stopRecording()
        #expect(meetingID != nil)
        #expect(fix.core.runState == .idle)
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.summaries.count == 1)
    }

    @Test("stopRecording routes to meetings with selection")
    @MainActor
    func stopRecordingRoutesToMeetings() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = await fix.core.stopRecording()
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == meetingID)
    }

    @Test("stopRecording enqueues transcription")
    @MainActor
    func stopRecordingEnqueuesTranscription() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        _ = await fix.core.stopRecording()
        #expect(fix.core.pendingTranscriptionTask != nil)
    }

    @Test("startRecording routes to recording screen")
    @MainActor
    func startRecordingRoutesToRecordingScreen() async throws {
        let fix = try makeCoreFixture(testName: "BackgroundTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)
    }
}

// MARK: - Calendar auto-association

@Suite("AppCore -- calendar auto-association")
struct AppCoreAutoAssociationTests {
    @Test("startRecording auto-associates best-match event")
    @MainActor
    func startRecordingAutoAssociates() async throws {
        let now = Date()
        let dto = makeMeetingDTO(
            title: "Team Sync",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()

        guard let meetingID = fix.core.recording.state.meetingID
        else {
            Issue.record("Expected meeting ID")
            return
        }

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar?.title == "Team Sync")
    }

    @Test("correctAssociation clears previous snapshot")
    @MainActor
    func correctAssociationClearsSnapshot() async throws {
        let now = Date()
        let dto1 = makeMeetingDTO(
            eventIdentifier: "ev-1",
            title: "Old Meeting",
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(1200)
        )
        let dto2 = makeMeetingDTO(
            eventIdentifier: "ev-2",
            title: "Correct Meeting",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto1, dto2],
            calendarRefreshResult: dto1,
            testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        guard let meetingID = fix.core.recording.state.meetingID
        else { return }

        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: nil
        )

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar == nil)
    }
}

// MARK: - De-dup suppression

@Suite("AppCore -- de-dup suppression")
struct AppCoreDedupTests {
    @Test("notification-driven start suppressed while already recording")
    @MainActor
    func detectionSuppressedWhileRecording() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true, testName: "BackgroundTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
        }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let firstMeetingID = fix.core.recording.state.meetingID

        fix.notificationService.handleResponseValues(
            categoryID: "biscotti.ad-hoc-detected",
            actionID: "biscotti.action.record",
            userInfo: [
                "biscotti.kind": "ad-hoc",
                "biscotti.bundleID": "us.zoom.xos"
            ]
        )

        try await Task.sleep(for: .milliseconds(200))

        #expect(fix.core.recording.state.meetingID == firstMeetingID)
    }
}

// MARK: - FakeScheduler tests

@Suite("FakeScheduler")
struct FakeSchedulerTests {
    @Test("advance resumes pending sleeps")
    @MainActor
    func advanceResumesPendingSleeps() async throws {
        let sched = FakeScheduler()
        var completed = false

        let task = Task { @MainActor in
            try await sched.sleep(for: .seconds(5))
            completed = true
        }

        // Poll until the sleep is actually pending
        try await pollUntil { sched.pendingCount == 1 }
        #expect(completed == false)

        sched.advance(by: .seconds(5))
        try await pollUntil { completed }

        #expect(sched.pendingCount == 0)
        task.cancel()
    }

    @Test("cancelAll throws CancellationError")
    @MainActor
    func cancelAllThrowsCancellation() async throws {
        let sched = FakeScheduler()
        var caughtCancellation = false

        let task = Task { @MainActor in
            do {
                try await sched.sleep(for: .seconds(10))
            } catch is CancellationError {
                caughtCancellation = true
            }
        }

        // Poll until the sleep is actually pending before cancelling
        try await pollUntil { sched.pendingCount == 1 }

        sched.cancelAll()

        // Poll until the catch block has executed
        try await pollUntil { caughtCancellation }

        #expect(sched.pendingCount == 0)
        task.cancel()
    }

    @Test("partial advance leaves non-elapsed sleeps pending")
    @MainActor
    func partialAdvanceLeavesRemaining() async throws {
        let sched = FakeScheduler()
        var shortCompleted = false
        var longCompleted = false

        let shortTask = Task { @MainActor in
            try await sched.sleep(for: .seconds(3))
            shortCompleted = true
        }
        let longTask = Task { @MainActor in
            try await sched.sleep(for: .seconds(10))
            longCompleted = true
        }

        // Poll until both sleeps are registered
        try await pollUntil { sched.pendingCount == 2 }

        sched.advance(by: .seconds(5))
        try await pollUntil { shortCompleted }

        #expect(longCompleted == false)
        #expect(sched.pendingCount == 1)

        sched.cancelAll()
        shortTask.cancel()
        longTask.cancel()
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

/// Creates an `AudioProcess` test stub for pipeline tests.
private func makeAudioProcess(
    bundleID: String,
    input: Bool,
    output: Bool,
    pid: pid_t = 1
) -> AudioProcess {
    AudioProcess(
        id: AudioObjectID(pid),
        bundleID: bundleID,
        pid: pid,
        isRunningInput: input,
        isRunningOutput: output
    )
}

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
