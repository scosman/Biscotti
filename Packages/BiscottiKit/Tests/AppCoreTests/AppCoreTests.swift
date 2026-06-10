import AudioCapture
import DataStore
import Foundation
import Permissions
import Recording
import Testing
import Transcription
import TranscriptionService
@testable import AppCore

// MARK: - FakeMicAuthorizer (local to these tests)

struct FakeMicAuthorizer: MicAuthorizing, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        var currentStatus: PermissionState
        var requestResult: Bool
        var requestCalled = false

        init(status: PermissionState, requestResult: Bool) {
            currentStatus = status
            self.requestResult = requestResult
        }
    }

    let backing: Backing

    @MainActor
    init(status: PermissionState = .authorized, requestResult: Bool = true) {
        backing = Backing(status: status, requestResult: requestResult)
    }

    func status() -> PermissionState {
        backing.currentStatus
    }

    func request() async -> Bool {
        backing.requestCalled = true
        return backing.requestResult
    }
}

// MARK: - FakeRecorder

struct FakeRecorder: RecorderControlling, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        var startCalled = false
        var stopCalled = false
        var requestPermissionsCalled = false
        var startError: (any Error)?
        var probableDenied: Bool
        var stateValues: [CaptureState]

        init(
            startError: (any Error)? = nil,
            probableDenied: Bool = false,
            stateValues: [CaptureState] = []
        ) {
            self.startError = startError
            self.probableDenied = probableDenied
            self.stateValues = stateValues
        }
    }

    let backing: Backing

    init(
        startError: (any Error)? = nil,
        probableDenied: Bool = false,
        stateValues: [CaptureState] = []
    ) {
        backing = Backing(
            startError: startError,
            probableDenied: probableDenied,
            stateValues: stateValues
        )
    }

    func requestPermissions(systemProbePath _: URL) async -> Bool {
        backing.requestPermissionsCalled = true
        return true
    }

    func start(paths _: CapturePaths) async throws {
        backing.startCalled = true
        if let error = backing.startError {
            throw error
        }
    }

    func stop() async {
        backing.stopCalled = true
    }

    func stateStream() -> AsyncStream<CaptureState> {
        let values = backing.stateValues
        return AsyncStream { continuation in
            for value in values {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    func probableSystemAudioDenied() async -> Bool {
        backing.probableDenied
    }
}

// MARK: - FakeTranscriber

struct FakeTranscriber: Transcribing, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        var ensureModelsCalled = false
        var processAudioCalled = false
        var lastMicURL: URL?
        var lastSystemURL: URL?
        var ensureModelsError: (any Error)?
        var processAudioError: (any Error)?
        var cannedResult: TranscriptResult

        init(cannedResult: TranscriptResult) {
            self.cannedResult = cannedResult
        }
    }

    let backing: Backing

    init(cannedResult: TranscriptResult? = nil) {
        backing = Backing(cannedResult: cannedResult ?? FakeTranscriber.defaultResult)
    }

    func ensureModelsDownloaded(
        status _: (@Sendable (String) -> Void)?
    ) async throws {
        backing.ensureModelsCalled = true
        if let error = backing.ensureModelsError {
            throw error
        }
    }

    func processAudio(
        mic: URL,
        system: URL,
        customVocabulary _: [String]
    ) async throws -> TranscriptResult {
        backing.processAudioCalled = true
        backing.lastMicURL = mic
        backing.lastSystemURL = system
        if let error = backing.processAudioError {
            throw error
        }
        return backing.cannedResult
    }

    private static let resultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ?? UUID()
    private static let segment0ID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")
        ?? UUID()
    private static let segment1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")
        ?? UUID()

    static let defaultResult = TranscriptResult(
        id: resultID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: [
            TranscriptSegment(
                id: segment0ID,
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0.0,
                endTime: 5.0,
                text: "Hello, how are you?",
                confidence: 0.95,
                noSpeechProbability: 0.01,
                words: nil
            ),
            TranscriptSegment(
                id: segment1ID,
                speakerID: 1,
                speakerLabel: "Speaker 1",
                startTime: 5.0,
                endTime: 10.0,
                text: "I'm doing well, thanks.",
                confidence: 0.92,
                noSpeechProbability: 0.02,
                words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 3.5
    )
}

// MARK: - Test fixture

@MainActor
struct TestFixture {
    let core: AppCore
    let store: DataStore
    let fakeRecorder: FakeRecorder
    let fakeEngine: FakeTranscriber
    let storageRoot: URL
    let permissions: Permissions

    func cleanup() {
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// Creates a meeting with present audio files and returns its ID.
    func createMeetingWithAudio(title: String = "Test Meeting") async throws -> UUID {
        let meetingID = try await store.createMeeting(title: title)
        let micRef = AudioFileRef(
            role: .mic,
            path: "/tmp/test/mic.aac",
            byteSize: 1024,
            isPresent: true
        )
        let sysRef = AudioFileRef(
            role: .system,
            path: "/tmp/test/system.aac",
            byteSize: 2048,
            isPresent: true
        )
        try await store.attachAudio([micRef, sysRef], to: meetingID)
        return meetingID
    }
}

@MainActor
private func makeFixture(
    micStatus: PermissionState = .authorized,
    micRequestResult: Bool = true,
    startError: (any Error)? = nil,
    probableDenied: Bool = false,
    summaryLimit: Int = 50
) throws -> TestFixture {
    let store = try DataStore(storage: .inMemory)
    let micAuth = FakeMicAuthorizer(status: micStatus, requestResult: micRequestResult)
    let permissions = Permissions(mic: micAuth)

    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

    let fakeRecorder = FakeRecorder(
        startError: startError,
        probableDenied: probableDenied
    )

    let recording = RecordingController(
        store: store,
        permissions: permissions,
        storageRoot: storageRoot,
        makeRecorder: { fakeRecorder },
        denialCheckDelay: .seconds(60) // disable auto denial check in tests
    )

    let fakeEngine = FakeTranscriber()
    let transcription = TranscriptionService(store: store, engine: fakeEngine)

    let core = AppCore(
        store: store,
        permissions: permissions,
        recording: recording,
        transcription: transcription,
        summaryLimit: summaryLimit
    )

    return TestFixture(
        core: core,
        store: store,
        fakeRecorder: fakeRecorder,
        fakeEngine: fakeEngine,
        storageRoot: storageRoot,
        permissions: permissions
    )
}

// MARK: - Launch and recovery tests

@Suite("AppCore -- launch and recovery")
struct AppCoreLaunchTests {
    @Test("onLaunch recovers orphans and loads summaries")
    @MainActor
    func onLaunchRecoverAndLoadSummaries() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        // Pre-populate a meeting so the sidebar has content
        _ = try await fix.store.createMeeting(title: "Previous Meeting")

        await fix.core.onLaunch()

        #expect(fix.core.summaries.count == 1)
        #expect(fix.core.summaries.first?.title == "Previous Meeting")
        #expect(fix.core.route == .empty)
    }

    @Test("onLaunch with orphaned recording reconciles and loads")
    @MainActor
    func onLaunchOrphanRecovery() async throws {
        let fix = try makeFixture()
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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.core.onLaunch()

        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.route == .empty)
    }
}

// MARK: - Recording coordination tests

@Suite("AppCore -- recording coordination")
struct AppCoreRecordingTests {
    @Test("startRecording creates meeting and routes to recording")
    @MainActor
    func startRecordingSuccess() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .recording)
        #expect(fix.core.recording.state.isRecording == true)
        #expect(fix.fakeRecorder.backing.startCalled == true)
    }

    @Test("startRecording with denied mic stays on current route")
    @MainActor
    func startRecordingDeniedMic() async throws {
        let fix = try makeFixture(micStatus: .denied, micRequestResult: false)
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .empty)
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.recording.lastError == .permissionDenied(.microphone))
    }

    @Test("startRecording with engine failure stays on current route")
    @MainActor
    func startRecordingEngineFailed() async throws {
        let fix = try makeFixture(startError: CaptureError.micEngineFailed("test"))
        defer { fix.cleanup() }

        await fix.core.startRecording()

        #expect(fix.core.route == .empty)
        #expect(fix.core.recording.state.isRecording == false)
    }

    @Test("stopRecording returns meeting ID and routes to meeting detail")
    @MainActor
    func stopRecordingRoutesToDetail() async throws {
        let fix = try makeFixture()
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let result = await fix.core.stopRecording()

        #expect(result == nil)
        #expect(fix.core.route == .empty)
    }
}

// MARK: - Navigation tests

@Suite("AppCore -- navigation")
struct AppCoreNavigationTests {
    @Test("select routes to meeting detail")
    @MainActor
    func selectRoutes() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)

        #expect(fix.core.route == .meeting(meetingID))
    }

    @Test("select different meetings updates route")
    @MainActor
    func selectDifferentMeetings() throws {
        let fix = try makeFixture()
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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        #expect(fix.core.route == .empty)

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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting A")
        _ = try await fix.store.createMeeting(title: "Meeting B")

        await fix.core.reloadSummaries()

        #expect(fix.core.summaries.count == 2)
    }

    @Test("reloadSummaries respects limit")
    @MainActor
    func reloadSummariesRespectsLimit() async throws {
        let fix = try makeFixture(summaryLimit: 2)
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        // Launch
        await fix.core.onLaunch()
        #expect(fix.core.route == .empty)
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
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
        let fix = try makeFixture()
        defer { fix.cleanup() }

        #expect(fix.core.route == .empty)
        #expect(fix.core.summaries.isEmpty)
    }
}
