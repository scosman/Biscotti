import AudioCapture
import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Permissions
import Recording
import Testing
import Transcription
import TranscriptionService
@testable import AppCore

// MARK: - Launch and recovery tests

@Suite("AppCore -- launch and recovery")
struct AppCoreLaunchTests {
    @Test("onLaunch recovers orphans and loads summaries")
    @MainActor
    func onLaunchRecoverAndLoadSummaries() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch proceeds past the gate
        try await fix.store.updateSettings { $0.onboardingComplete = true }

        // Pre-populate a meeting so the sidebar has content
        _ = try await fix.store.createMeeting(title: "Previous Meeting")

        await fix.core.onLaunch()

        #expect(fix.core.summaries.count == 1)
        #expect(fix.core.summaries.first?.title == "Previous Meeting")
        #expect(fix.core.route == .home)
    }

    @Test("onLaunch with orphaned recording reconciles and loads")
    @MainActor
    func onLaunchOrphanRecovery() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch proceeds past the gate
        try await fix.store.updateSettings { $0.onboardingComplete = true }

        // Simulate a crashed recording: create meeting + marker file
        let meetingID = try await fix.store.createMeeting(title: "Crashed Recording")
        let meetingDir = fix.storageRoot.appendingPathComponent(meetingID.uuidString)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let markerURL = meetingDir.appendingPathComponent(RecordingController.markerFileName)
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)

        // Write fake audio files + attach refs
        let micPath = meetingDir.appendingPathComponent("mic.aac")
        let sysPath = meetingDir.appendingPathComponent("system.aac")
        try Data(repeating: 0xFF, count: 128).write(to: micPath)
        try Data(repeating: 0xAA, count: 256).write(to: sysPath)
        let micRef = AudioFileRef(role: .mic, path: micPath.path, byteSize: 0, isPresent: false)
        let sysRef = AudioFileRef(role: .system, path: sysPath.path, byteSize: 0, isPresent: false)
        try await fix.store.attachAudio([micRef, sysRef], to: meetingID)

        await fix.core.onLaunch()

        // Marker should be cleaned up
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        // Summaries should include the recovered meeting
        #expect(fix.core.summaries.count == 1)
        #expect(fix.core.summaries.first?.title == "Crashed Recording")
    }

    @Test("onLaunch with empty store produces empty summaries")
    @MainActor
    func onLaunchEmpty() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch proceeds past the gate
        try await fix.store.updateSettings { $0.onboardingComplete = true }

        await fix.core.onLaunch()

        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.route == .home)
    }

    @Test("onLaunch is idempotent: second call is a no-op")
    @MainActor
    func onLaunchIdempotent() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }

        // First launch: loads summaries and routes to home.
        await fix.core.onLaunch()
        #expect(fix.core.route == .home)

        // Add a meeting AFTER the first launch (simulates data that
        // would appear if onLaunch ran again -- a fresh AppCore would
        // reload summaries from a re-created store).
        _ = try await fix.store.createMeeting(title: "Post-Launch")

        // Navigate away from home so we can detect if route gets reset.
        fix.core.showSettings()
        #expect(fix.core.route == .settings)

        // Second call should be a no-op: route stays .settings,
        // summaries are NOT reloaded (so the new meeting doesn't appear).
        await fix.core.onLaunch()
        #expect(fix.core.route == .settings)
        #expect(
            fix.core.summaries.isEmpty,
            "Second onLaunch must not reload summaries"
        )
    }

    @Test("onLaunch routes to onboarding when incomplete")
    @MainActor
    func onLaunchOnboardingGate() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Don't mark onboarding complete
        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)
    }
}

// MARK: - Recording coordination tests

@Suite("AppCore -- recording coordination")
struct AppCoreRecordingTests {
    @Test("startRecording creates meeting and routes to recording")
    @MainActor
    func startRecordingSuccess() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == true)
        #expect(fix.fakeRecorder.backing.startCalled == true)
    }

    @Test("startRecording with denied mic routes to recording with failed startup")
    @MainActor
    func startRecordingDeniedMic() async throws {
        let fix = try makeCoreFixture(
            micStatus: .denied,
            micRequestResult: false,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()

        // Route is .recording (showing the error state in the pane)
        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.recording.lastError == .permissionDenied(.microphone))
        if case .failed = fix.core.recordingStartup {
            // Good -- startup failed with an error message
        } else {
            Issue.record(
                "Expected .failed, got \(String(describing: fix.core.recordingStartup))"
            )
        }
    }

    @Test("startRecording with engine failure routes to recording with failed startup")
    @MainActor
    func startRecordingEngineFailed() async throws {
        let fix = try makeCoreFixture(
            startError: CaptureError.micEngineFailed("test"),
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()

        // Route is .recording (showing the error state in the pane)
        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == false)
        if case .failed = fix.core.recordingStartup {
            // Good -- startup failed
        } else {
            Issue.record(
                "Expected .failed, got \(String(describing: fix.core.recordingStartup))"
            )
        }
    }

    @Test("stopRecording returns meeting ID and routes to meetings with selection")
    @MainActor
    func stopRecordingRoutesToMeetings() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)

        let meetingID = await fix.core.stopRecording()

        let unwrappedID = try #require(meetingID)
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [unwrappedID])
        #expect(fix.core.recording.state.isRecording == false)
    }

    @Test("stopRecording reloads summaries")
    @MainActor
    func stopRecordingReloadsSummaries() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        #expect(fix.core.summaries.isEmpty)

        await fix.core.startRecording()
        _ = await fix.core.stopRecording()

        // The newly created meeting should appear in summaries
        #expect(fix.core.summaries.count == 1)
        #expect(fix.core.summaries.first?.title == "Untitled Meeting")
    }

    @Test("stopRecording auto-enqueues transcription")
    @MainActor
    func stopRecordingAutoTranscribes() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = try #require(await fix.core.stopRecording())

        // Await the fire-and-forget transcription task deterministically.
        await fix.core.awaitPendingTranscription()

        // The fake audio files don't exist on disk, so audioPaths returns nil
        // and the job fails with "No audio files". That's correct behavior --
        // in production the files exist. Assert the exact expected status so a
        // silent change of failure mode is caught.
        let jobStatus = fix.core.transcription.jobs[meetingID]
        #expect(jobStatus == .failed(message: "No audio files available for this meeting.", retriable: false))
    }

    @Test("stopRecording when not recording returns nil")
    @MainActor
    func stopRecordingWhenIdle() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let result = await fix.core.stopRecording()

        #expect(result == nil)
        #expect(fix.core.route == .home)
    }

    @Test("toggleRecording starts when idle")
    @MainActor
    func toggleRecordingStartsWhenIdle() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let result = await fix.core.toggleRecording()

        #expect(result == nil) // start path returns nil
        #expect(fix.core.recording.state.isRecording == true)
        #expect(fix.core.route == .recording)
    }

    @Test("toggleRecording stops when recording")
    @MainActor
    func toggleRecordingStopsWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.recording.state.isRecording == true)

        let meetingID = await fix.core.toggleRecording()

        #expect(meetingID != nil) // stop path returns meeting ID
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.route == .meetings)
    }
}

// MARK: - Navigation tests

@Suite("AppCore -- navigation")
struct AppCoreNavigationTests {
    @Test("select routes to meetings with selection")
    @MainActor
    func selectRoutes() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
    }

    @Test("select clears search query and results")
    @MainActor
    func selectClearsSearch() throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        // Set up a query
        fix.core.setMeetingsQuery("test")
        #expect(fix.core.meetingsQuery == "test")

        // Select clears it
        fix.core.select(UUID())
        #expect(fix.core.meetingsQuery == "")
        #expect(fix.core.meetingsResults.isEmpty)
    }

    @Test("selectFromList sets selection, preserves query")
    @MainActor
    func selectFromListPreservesQuery() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        fix.core.select(UUID()) // get to .meetings
        // Manually set query state for this test
        fix.core.setMeetingsQuery("hello")

        let meetingID = UUID()
        fix.core.selectFromList([meetingID])
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.meetingsQuery == "hello")
    }

    @Test("selectFromList with multiple IDs sets multi-element selection")
    @MainActor
    func selectFromListMultiple() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        fix.core.select(UUID()) // get to .meetings
        let id1 = UUID()
        let id2 = UUID()
        fix.core.selectFromList([id1, id2])
        #expect(fix.core.meetingsSelection == [id1, id2])
    }

    @Test("selectFromList empty set clears selection")
    @MainActor
    func selectFromListEmpty() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        fix.core.select(UUID())
        fix.core.selectFromList([])
        #expect(fix.core.meetingsSelection.isEmpty)
    }

    @Test("showMeetings clears query but keeps selection")
    @MainActor
    func showMeetingsKeepsSelection() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)

        fix.core.showHome()
        fix.core.showMeetings()

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.meetingsQuery == "")
    }

    @Test("select different meetings updates selection")
    @MainActor
    func selectDifferentMeetings() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let id1 = UUID()
        let id2 = UUID()

        fix.core.select(id1)
        #expect(fix.core.meetingsSelection == [id1])

        fix.core.select(id2)
        #expect(fix.core.meetingsSelection == [id2])
    }

    @Test("route is .recording during active recording, then .meetings after stop")
    @MainActor
    func routeTransitionsThroughRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        #expect(fix.core.route == .home)

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)

        let meetingID = try #require(await fix.core.stopRecording())
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
    }
}

// MARK: - Summaries tests

@Suite("AppCore -- summaries")
struct AppCoreSummariesTests {
    @Test("reloadSummaries loads meetings from store")
    @MainActor
    func reloadSummariesFromStore() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting A")
        _ = try await fix.store.createMeeting(title: "Meeting B")

        await fix.core.reloadSummaries()

        #expect(fix.core.summaries.count == 2)
    }

    @Test("reloadSummaries loads all meetings (uncapped)")
    @MainActor
    func reloadSummariesUncapped() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting 1")
        _ = try await fix.store.createMeeting(title: "Meeting 2")
        _ = try await fix.store.createMeeting(title: "Meeting 3")

        await fix.core.reloadSummaries()

        #expect(fix.core.summaries.count == 3)
    }

    @Test("summaries are newest first")
    @MainActor
    func summariesNewestFirst() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "First")
        // Small delay to ensure distinct createdAt timestamps
        try await Task.sleep(for: .milliseconds(10))
        _ = try await fix.store.createMeeting(title: "Second")

        await fix.core.reloadSummaries()

        #expect(fix.core.summaries.count == 2)
        #expect(fix.core.summaries.first?.title == "Second")
        #expect(fix.core.summaries.last?.title == "First")
    }

    @Test("summaries update after recording cycle")
    @MainActor
    func summariesUpdateAfterRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        #expect(fix.core.summaries.isEmpty)

        await fix.core.startRecording()
        _ = await fix.core.stopRecording()

        // stopRecording calls reloadSummaries
        #expect(fix.core.summaries.count == 1)
    }
}

// MARK: - Full flow tests

@Suite("AppCore -- end-to-end flows")
struct AppCoreFlowTests {
    @Test("Full flow: launch -> start -> stop -> transcription enqueued")
    @MainActor
    func fullRecordTranscribeFlow() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch proceeds past the gate
        try await fix.store.updateSettings { $0.onboardingComplete = true }

        // Launch
        await fix.core.onLaunch()
        #expect(fix.core.route == .home)
        #expect(fix.core.summaries.isEmpty)

        // Start recording
        await fix.core.startRecording()
        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == true)

        // Stop recording
        let meetingID = try #require(await fix.core.stopRecording())
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.summaries.count == 1)

        // Await the fire-and-forget transcription task deterministically.
        await fix.core.awaitPendingTranscription()

        // Transcription was attempted for the meeting
        #expect(fix.core.transcription.jobs[meetingID] != nil)
    }

    @Test("Multiple recordings create separate meetings")
    @MainActor
    func multipleRecordingSessions() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        // First recording
        await fix.core.startRecording()
        let id1 = try #require(await fix.core.stopRecording())

        // Second recording
        await fix.core.startRecording()
        let id2 = try #require(await fix.core.stopRecording())

        #expect(id1 != id2)
        #expect(fix.core.summaries.count == 2)
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == [id2])
    }

    @Test("Select after stop navigates to a different meeting")
    @MainActor
    func selectAfterStop() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.onboardingComplete = true }
        let existingID = try await fix.store.createMeeting(title: "Earlier")
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let newID = try #require(await fix.core.stopRecording())
        #expect(fix.core.meetingsSelection == [newID])

        // Select the older meeting
        fix.core.select(existingID)
        #expect(fix.core.meetingsSelection == [existingID])
    }

    @Test("Initial route is empty")
    @MainActor
    func initialRouteIsEmpty() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        #expect(fix.core.route == .home)
        #expect(fix.core.summaries.isEmpty)
    }
}

// MARK: - Delete meeting tests

@Suite("AppCore -- delete meeting")
struct AppCoreDeleteMeetingTests {
    @Test("deleteMeeting removes on-disk files and DB row, stays on meetings")
    @MainActor
    func deleteMeetingRemovesFilesAndRow() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreDeleteTests")
        defer { fix.cleanup() }

        // Create a meeting with on-disk audio files
        let meetingID = try await fix.store.createMeeting(title: "Delete Me")
        let meetingDir = fix.storageRoot
            .appendingPathComponent(meetingID.uuidString)
        try FileManager.default.createDirectory(
            at: meetingDir, withIntermediateDirectories: true
        )
        let micPath = meetingDir.appendingPathComponent("mic.aac")
        let sysPath = meetingDir.appendingPathComponent("system.aac")
        try Data(repeating: 0xFF, count: 64).write(to: micPath)
        try Data(repeating: 0xAA, count: 64).write(to: sysPath)

        let micRef = AudioFileRef(
            role: .mic, path: micPath.path, byteSize: 64, isPresent: true
        )
        let sysRef = AudioFileRef(
            role: .system, path: sysPath.path, byteSize: 64, isPresent: true
        )
        try await fix.store.attachAudio([micRef, sysRef], to: meetingID)

        // Load summaries so the meeting appears
        await fix.core.reloadSummaries()
        #expect(fix.core.summaries.count == 1)

        // Navigate to the meeting's detail
        fix.core.select(meetingID)
        #expect(fix.core.route == .meetings)

        // Delete
        await fix.core.deleteMeeting(meetingID: meetingID)

        // Files should be gone
        #expect(!FileManager.default.fileExists(atPath: micPath.path))
        #expect(!FileManager.default.fileExists(atPath: sysPath.path))

        // Directory should be gone (was emptied)
        #expect(!FileManager.default.fileExists(atPath: meetingDir.path))

        // DB row should be gone
        #expect(try await fix.store.meetingExists(id: meetingID) == false)

        // Summaries refreshed
        #expect(fix.core.summaries.isEmpty)

        // Route stays on meetings (with nil selection = placeholder)
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection.isEmpty)
    }

    @Test("deleteMeeting with missing files does not throw")
    @MainActor
    func deleteMeetingMissingFilesNoThrow() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreDeleteTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Already Gone"
        )

        // Attach audio refs pointing to non-existent files
        let micRef = AudioFileRef(
            role: .mic,
            path: "/tmp/nonexistent-\(UUID())/mic.aac",
            byteSize: 0,
            isPresent: false
        )
        try await fix.store.attachAudio([micRef], to: meetingID)

        // Should not throw
        await fix.core.deleteMeeting(meetingID: meetingID)

        // Row still deleted
        #expect(try await fix.store.meetingExists(id: meetingID) == false)
        #expect(fix.core.route == .meetings)
    }

    @Test("deleteMeeting refuses to delete the actively-recording meeting")
    @MainActor
    func deleteMeetingRefusedWhileRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreDeleteTests")
        defer { fix.cleanup() }

        // Start a recording so a meeting is created
        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)
        #expect(fix.core.recording.state.isRecording == true)

        // The fake recorder doesn't write real audio files, so create
        // them manually (mirrors how the real engine would populate
        // the directory that RecordingController.setupMeetingStorage
        // already created).
        let meetingDir = fix.storageRoot
            .appendingPathComponent(meetingID.uuidString)
        let micPath = meetingDir.appendingPathComponent("mic.aac")
        let sysPath = meetingDir.appendingPathComponent("system.aac")
        try Data(repeating: 0xFF, count: 64).write(to: micPath)
        try Data(repeating: 0xAA, count: 64).write(to: sysPath)

        // Attempt to delete the actively-recording meeting
        await fix.core.deleteMeeting(meetingID: meetingID)

        // Meeting row must still exist
        #expect(try await fix.store.meetingExists(id: meetingID))

        // Files must still exist (not deleted mid-write)
        #expect(FileManager.default.fileExists(atPath: micPath.path))
        #expect(FileManager.default.fileExists(atPath: sysPath.path))

        // Route must NOT have changed to .home (still .recording)
        #expect(fix.core.route == .recording)

        // Recording must still be active
        #expect(fix.core.recording.state.isRecording == true)
    }
}

// MARK: - Batch delete tests (7b)

@Suite("AppCore -- batch delete meetings")
struct AppCoreBatchDeleteTests {
    @Test("deleteMeetings removes all selected and selects neighbor")
    @MainActor
    func deleteMeetingsBatchRemovesAllAndSelectsNeighbor() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreBatchDeleteTests")
        defer { fix.cleanup() }

        // Create 3 meetings: A (oldest), B, C (newest).
        // Summaries are reverse-chrono, so order is [C, B, A].
        let idA = try await fix.store.createMeeting(title: "Meeting A")
        let idB = try await fix.store.createMeeting(title: "Meeting B")
        let idC = try await fix.store.createMeeting(title: "Meeting C")
        await fix.core.reloadSummaries()
        #expect(fix.core.summaries.count == 3)

        // Select B and C
        fix.core.selectFromList([idB, idC])

        // Batch delete B and C
        await fix.core.deleteMeetings([idB, idC])

        // Both should be gone
        #expect(try await fix.store.meetingExists(id: idB) == false)
        #expect(try await fix.store.meetingExists(id: idC) == false)
        #expect(fix.core.summaries.count == 1)

        // Should select A (the remaining neighbor)
        #expect(fix.core.meetingsSelection == [idA])
        #expect(fix.core.route == .meetings)
    }

    @Test("deleteMeetings with empty set is no-op")
    @MainActor
    func deleteMeetingsEmptySetIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreBatchDeleteTests")
        defer { fix.cleanup() }

        let id = try await fix.store.createMeeting(title: "Keep Me")
        await fix.core.reloadSummaries()
        fix.core.select(id)

        // Batch delete with empty set
        await fix.core.deleteMeetings([])

        // Meeting still exists, selection unchanged
        #expect(try await fix.store.meetingExists(id: id))
        #expect(fix.core.summaries.count == 1)
        #expect(fix.core.meetingsSelection == [id])
    }

    @Test("deleteMeetings deleting all meetings clears selection")
    @MainActor
    func deleteMeetingsAllClearsSelection() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreBatchDeleteTests")
        defer { fix.cleanup() }

        let id1 = try await fix.store.createMeeting(title: "A")
        let id2 = try await fix.store.createMeeting(title: "B")
        await fix.core.reloadSummaries()

        await fix.core.deleteMeetings([id1, id2])

        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.meetingsSelection.isEmpty)
        #expect(fix.core.route == .meetings)
    }
}

// MARK: - Calendar auto-association tests (C4)

@Suite("AppCore -- calendar auto-association")
struct AppCoreCalendarAssociationTests {
    /// Helper to build a meeting-like EKEventDTO that CalendarService will
    /// accept as "meeting-like" (has attendees >= 2).
    private static func makeMeetingDTO(
        eventIdentifier: String = "ev-1",
        title: String = "Standup",
        start: Date,
        end: Date,
        attendeeCount: Int = 3,
        calendarTitle: String = "Work",
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
            calendarTitle: calendarTitle,
            calendarColorHex: "#0066CC",
            calendarSourceTitle: "iCloud",
            birthdayContactIdentifier: nil,
            attendeeCount: attendeeCount,
            attendees: [],
            organizer: nil
        )
    }

    @Test("startRecording auto-associates best match event")
    @MainActor
    func startRecordingAutoAssociatesBestMatch() async throws {
        let now = Date()
        let dto = Self.makeMeetingDTO(
            title: "Team Standup",
            start: now.addingTimeInterval(-300), // started 5 min ago
            end: now.addingTimeInterval(1500) // ends in 25 min
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch primes calendar
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        // Verify upcoming has our event
        #expect(fix.core.upcoming.count == 1)

        await fix.core.startRecording()

        // Should have created a meeting and associated
        guard let meetingID = fix.core.recording.state.meetingID else {
            Issue.record("Expected a meeting ID after start")
            return
        }

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar != nil)
        #expect(detail?.calendar?.title == "Team Standup")
    }

    @Test("startRecording with explicit key overrides best match")
    @MainActor
    func startRecordingExplicitKeyOverridesBestMatch() async throws {
        let now = Date()
        // Two events: one in-progress, one not yet started
        let dto1 = Self.makeMeetingDTO(
            eventIdentifier: "ev-inprogress",
            title: "In Progress Meeting",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1500)
        )
        let dto2 = Self.makeMeetingDTO(
            eventIdentifier: "ev-upcoming",
            title: "Upcoming Meeting",
            start: now.addingTimeInterval(600), // 10 min from now (within bestMatch window)
            end: now.addingTimeInterval(4200)
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto1, dto2],
            calendarRefreshResult: dto2, // refresh returns dto2 for snapshot
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        // Mark onboarding complete so onLaunch primes calendar
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        // Find the key for the upcoming meeting
        let upcomingEvent = fix.core.upcoming.first { $0.title == "Upcoming Meeting" }
        #expect(upcomingEvent != nil)

        // Start recording with explicit key for the upcoming meeting
        await fix.core.startRecording(eventKey: upcomingEvent?.id)

        guard let meetingID = fix.core.recording.state.meetingID else {
            Issue.record("Expected a meeting ID after start")
            return
        }

        let detail = try await fix.store.meetingDetail(id: meetingID)
        // Should be associated with the explicitly-chosen event
        #expect(detail?.calendar != nil)
        #expect(detail?.calendar?.title == "Upcoming Meeting")
    }

    @Test("startRecording with no match proceeds unlinked")
    @MainActor
    func startRecordingNoMatchProceedsUnlinked() async throws {
        // No events at all
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()

        guard let meetingID = fix.core.recording.state.meetingID else {
            Issue.record("Expected a meeting ID after start")
            return
        }

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar == nil)
    }
}

// MARK: - Calendar navigation tests

@Suite("AppCore -- calendar navigation")
struct AppCoreCalendarNavigationTests {
    @Test("selectEvent routes to event preview")
    @MainActor
    func selectEventRoutesToEventPreview() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        fix.core.selectEvent("some-event-key")
        #expect(fix.core.route == .event("some-event-key"))
    }

    @Test("showHome and showSettings change route")
    @MainActor
    func showHomeShowSettingsRouting() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        fix.core.showSettings()
        #expect(fix.core.route == .settings)

        fix.core.showHome()
        #expect(fix.core.route == .home)

        fix.core.showOnboardingReplay()
        #expect(fix.core.route == .onboarding)
    }

    @Test("onLaunch with onboarding incomplete routes to onboarding")
    @MainActor
    func onLaunchOnboardingIncomplete() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Default settings: onboardingComplete == false
        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)
    }

    @Test("completeOnboarding transitions to home and starts calendar")
    @MainActor
    func completeOnboardingTransitionsToHome() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        // Launch with onboarding incomplete -> routes to .onboarding
        await fix.core.onLaunch()
        #expect(fix.core.route == .onboarding)

        await fix.core.completeOnboarding()

        #expect(fix.core.route == .home)

        // Verify onboarding flag was persisted
        let settings = try await fix.store.settings()
        #expect(settings.onboardingComplete == true)
    }
}

// MARK: - Association correction tests

@Suite("AppCore -- association correction")
struct AppCoreAssociationCorrectionTests {
    @Test("correctAssociation with nil removes association")
    @MainActor
    func correctAssociationRemovesAssociation() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Test")

        // Set up a snapshot and participants
        let snapshot = CalendarSnapshot(
            eventIdentifier: "ev-1",
            calendarItemIdentifier: "ci-1",
            calendarItemExternalIdentifier: "ext-1",
            occurrenceStartDate: Date(),
            compositeKey: "key-1",
            title: "Old Event",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            url: nil,
            timeZone: nil,
            eventNotes: "",
            status: nil,
            availability: nil,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            conferenceURL: nil,
            conferencePlatform: nil
        )
        try await fix.store.setSnapshot(snapshot, for: meetingID)

        // Verify it's there
        let detailBefore = try await fix.store.meetingDetail(id: meetingID)
        #expect(detailBefore?.calendar != nil)

        // Remove association
        await fix.core.correctAssociation(meetingID: meetingID, eventKey: nil)

        // Verify it's gone
        let detailAfter = try await fix.store.meetingDetail(id: meetingID)
        #expect(detailAfter?.calendar == nil)
    }

    @Test("correctAssociation with non-nil key replaces snapshot")
    @MainActor
    func correctAssociationReplacesSnapshot() async throws {
        let now = Date()
        let newDTO = Self.makeReplacementDTO(at: now)

        let fix = try makeCoreFixture(
            calendarEventDTOs: [newDTO],
            calendarRefreshResult: newDTO,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        // Create a meeting with an existing snapshot
        let meetingID = try await fix.store.createMeeting(title: "Replace Test")
        let oldSnapshot = Self.makeOldSnapshot(at: now)
        try await fix.store.setSnapshot(oldSnapshot, for: meetingID)

        // Prime calendar with the new event
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()
        #expect(fix.core.upcoming.count == 1)

        let newEventKey = try #require(fix.core.upcoming.first?.id)

        // Correct the association to the new event
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: newEventKey
        )

        // Verify snapshot was replaced with the new event's data
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar != nil)
        #expect(detail?.calendar?.title == "New Event")
    }

    @Test(
        "correctAssociation via eventsNear succeeds (recurring-event regression)"
    )
    @MainActor
    func correctAssociationViaEventsNearSucceeds() async throws {
        // Regression: recurring calendar events share an eventIdentifier
        // across occurrences. The old LiveEventStore.refreshEvent used
        // event(withIdentifier:) which returns only the FIRST occurrence,
        // causing the occurrence-date check to fail and snapshot(forKey:)
        // to return nil. The fix falls back to a date-range search.
        //
        // This test exercises the eventsNear -> correctAssociation path
        // (the exact flow from the "Link calendar event" picker) and
        // verifies the association persists correctly. With the
        // FakeEventStore the refresh always succeeds, so this guards
        // against regressions in the CalendarService / AppCore plumbing.
        let now = Date()
        let recurringDTO = EKEventDTO(
            eventIdentifier: "ev-recurring",
            calendarItemIdentifier: "ci-recurring",
            calendarItemExternalIdentifier: "ext-recurring",
            occurrenceDate: now,
            title: "Weekly Standup",
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            isAllDay: false,
            location: "https://zoom.us/j/recurring",
            url: nil,
            timeZone: nil,
            notes: nil,
            status: nil,
            availability: nil,
            calendarIdentifier: "cal-1",
            calendarTitle: "Team",
            calendarColorHex: "#33CC33",
            calendarSourceTitle: "iCloud",
            birthdayContactIdentifier: nil,
            attendeeCount: 4,
            attendees: [],
            organizer: nil
        )

        let fix = try makeCoreFixture(
            calendarEventDTOs: [recurringDTO],
            calendarRefreshResult: recurringDTO,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Past Recording"
        )

        // Use eventsNear (the picker path), NOT onLaunch/refreshUpcoming.
        // This populates candidateDTOs, the exact flow that was broken.
        let nearby = await fix.core.eventsNear(now)
        #expect(nearby.count == 1)

        let eventKey = try #require(nearby.first?.id)
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: eventKey
        )

        // Verify the association was persisted
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar != nil)
        #expect(detail?.calendar?.title == "Weekly Standup")
        #expect(detail?.calendar?.calendarTitle == "Team")
    }

    @Test(
        "correctAssociation fails gracefully when refreshEvent returns nil"
    )
    @MainActor
    func correctAssociationFailsWhenRefreshNil() async throws {
        // When the provider's refreshEvent returns nil (e.g. the old
        // LiveEventStore behavior for recurring-event occurrences),
        // correctAssociation should leave the existing association intact
        // and not crash or corrupt data.
        let now = Date()
        let dto = EKEventDTO(
            eventIdentifier: "ev-gone",
            calendarItemIdentifier: "ci-gone",
            calendarItemExternalIdentifier: "ext-gone",
            occurrenceDate: now,
            title: "Vanished Event",
            startDate: now,
            endDate: now.addingTimeInterval(3600),
            isAllDay: false,
            location: "https://zoom.us/j/gone",
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
            attendeeCount: 2,
            attendees: [],
            organizer: nil
        )

        // calendarRefreshResult defaults to nil -- simulates the old
        // broken behavior where refreshEvent returned nil for a
        // non-first occurrence of a recurring event.
        let fix = try makeCoreFixture(
            calendarEventDTOs: [dto],
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Linked Meeting"
        )
        // Pre-populate an existing association
        let existingSnapshot = Self.makeOldSnapshot(at: now)
        try await fix.store.setSnapshot(existingSnapshot, for: meetingID)

        // Use eventsNear to populate candidateDTOs
        let nearby = await fix.core.eventsNear(now)
        #expect(nearby.count == 1)

        let eventKey = try #require(nearby.first?.id)
        await fix.core.correctAssociation(
            meetingID: meetingID, eventKey: eventKey
        )

        // Association should be preserved (old snapshot intact),
        // because the lookup failed gracefully.
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar != nil)
        #expect(detail?.calendar?.title == "Old Event")
    }

    // MARK: - Helpers

    private static func makeReplacementDTO(at now: Date) -> EKEventDTO {
        EKEventDTO(
            eventIdentifier: "ev-new",
            calendarItemIdentifier: "ci-new",
            calendarItemExternalIdentifier: "ext-new",
            occurrenceDate: now,
            title: "New Event",
            startDate: now,
            endDate: now.addingTimeInterval(3600),
            isAllDay: false,
            location: "https://zoom.us/j/999",
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

    private static func makeOldSnapshot(at now: Date) -> CalendarSnapshot {
        CalendarSnapshot(
            eventIdentifier: "ev-old",
            calendarItemIdentifier: "ci-old",
            calendarItemExternalIdentifier: "ext-old",
            occurrenceStartDate: now,
            compositeKey: "key-old",
            title: "Old Event",
            startDate: now,
            endDate: now.addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            url: nil,
            timeZone: nil,
            eventNotes: "",
            status: nil,
            availability: nil,
            calendarTitle: "Work",
            calendarColorHex: "#0066CC",
            conferenceURL: nil,
            conferencePlatform: nil
        )
    }
}
