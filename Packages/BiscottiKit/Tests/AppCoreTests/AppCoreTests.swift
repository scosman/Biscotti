import AudioCapture
import BiscottiTestSupport
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

        await fix.core.onLaunch()

        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.route == .home)
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

    @Test("startRecording with denied mic stays on current route")
    @MainActor
    func startRecordingDeniedMic() async throws {
        let fix = try makeCoreFixture(
            micStatus: .denied,
            micRequestResult: false,
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .home)
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.recording.lastError == .permissionDenied(.microphone))
    }

    @Test("startRecording with engine failure stays on current route")
    @MainActor
    func startRecordingEngineFailed() async throws {
        let fix = try makeCoreFixture(
            startError: CaptureError.micEngineFailed("test"),
            testName: "AppCoreTests"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .home)
        #expect(fix.core.recording.state.isRecording == false)
    }

    @Test("stopRecording returns meeting ID and routes to meeting detail")
    @MainActor
    func stopRecordingRoutesToDetail() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)

        let meetingID = await fix.core.stopRecording()

        #expect(meetingID != nil)
        #expect(try fix.core.route == .meeting(#require(meetingID)))
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
        #expect(fix.core.summaries.first?.title.hasPrefix("Recording") == true)
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
}

// MARK: - Navigation tests

@Suite("AppCore -- navigation")
struct AppCoreNavigationTests {
    @Test("select routes to meeting detail")
    @MainActor
    func selectRoutes() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)

        #expect(fix.core.route == .meeting(meetingID))
    }

    @Test("select different meetings updates route")
    @MainActor
    func selectDifferentMeetings() throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let id1 = UUID()
        let id2 = UUID()

        fix.core.select(id1)
        #expect(fix.core.route == .meeting(id1))

        fix.core.select(id2)
        #expect(fix.core.route == .meeting(id2))
    }

    @Test("route is .recording during active recording, then .meeting after stop")
    @MainActor
    func routeTransitionsThroughRecording() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        #expect(fix.core.route == .home)

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)

        let meetingID = try #require(await fix.core.stopRecording())
        #expect(fix.core.route == .meeting(meetingID))
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

    @Test("reloadSummaries respects limit")
    @MainActor
    func reloadSummariesRespectsLimit() async throws {
        let fix = try makeCoreFixture(summaryLimit: 2, testName: "AppCoreTests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting 1")
        _ = try await fix.store.createMeeting(title: "Meeting 2")
        _ = try await fix.store.createMeeting(title: "Meeting 3")

        await fix.core.reloadSummaries()

        #expect(fix.core.summaries.count == 2)
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
        #expect(fix.core.route == .meeting(meetingID))
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

        await fix.core.onLaunch()

        // First recording
        await fix.core.startRecording()
        let id1 = try #require(await fix.core.stopRecording())

        // Second recording
        await fix.core.startRecording()
        let id2 = try #require(await fix.core.stopRecording())

        #expect(id1 != id2)
        #expect(fix.core.summaries.count == 2)
        #expect(fix.core.route == .meeting(id2))
    }

    @Test("Select after stop navigates to a different meeting")
    @MainActor
    func selectAfterStop() async throws {
        let fix = try makeCoreFixture(testName: "AppCoreTests")
        defer { fix.cleanup() }

        let existingID = try await fix.store.createMeeting(title: "Earlier")
        await fix.core.onLaunch()

        await fix.core.startRecording()
        let newID = try #require(await fix.core.stopRecording())
        #expect(fix.core.route == .meeting(newID))

        // Select the older meeting
        fix.core.select(existingID)
        #expect(fix.core.route == .meeting(existingID))
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
