import AppCore
import AudioCapture
import DataStore
import Foundation
import Permissions
import Recording
import TranscriptionService

/// Bundles all test dependencies for AppCore-based tests.
///
/// Provides a pre-wired `AppCore` with in-memory storage and configurable
/// fakes. Shared across all UI and integration test targets.
@MainActor
public struct CoreFixture {
    public let core: AppCore
    public let store: DataStore
    public let fakeRecorder: FakeRecorder
    public let fakeEngine: FakeTranscriber
    public let storageRoot: URL
    public let permissions: Permissions

    public func cleanup() {
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// Creates a meeting with present audio files and returns its ID.
    public func createMeetingWithAudio(title: String = "Test Meeting") async throws -> UUID {
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

/// Creates a `CoreFixture` with configurable fakes.
///
/// - Parameters:
///   - micStatus: Initial mic permission status (default `.authorized`).
///   - micRequestResult: Whether mic permission request succeeds (default `true`).
///   - startError: Error to throw from the recorder's `start` method.
///   - probableDenied: Whether the recorder reports probable system audio denial.
///   - stateValues: Capture state values to emit from the recorder's state stream.
///   - summaryLimit: Max meetings to load for the sidebar (default `50`).
///   - denialCheckDelay: Delay before the denial check task runs (default `60s`).
///   - testName: Used to namespace the storage directory (default `"Test"`).
@MainActor
public func makeCoreFixture(
    micStatus: PermissionState = .authorized,
    micRequestResult: Bool = true,
    startError: (any Error)? = nil,
    probableDenied: Bool = false,
    stateValues: [CaptureState] = [],
    summaryLimit: Int = 50,
    denialCheckDelay: Duration = .seconds(60),
    testName: String = "Test"
) throws -> CoreFixture {
    let store = try DataStore(storage: .inMemory)
    let micAuth = FakeMicAuthorizer(status: micStatus, requestResult: micRequestResult)
    let permissions = Permissions(mic: micAuth)

    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(testName)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

    let fakeRecorder = FakeRecorder(
        startError: startError,
        probableDenied: probableDenied,
        stateValues: stateValues
    )

    let recording = RecordingController(
        store: store,
        permissions: permissions,
        storageRoot: storageRoot,
        makeRecorder: { fakeRecorder },
        denialCheckDelay: denialCheckDelay
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

    return CoreFixture(
        core: core,
        store: store,
        fakeRecorder: fakeRecorder,
        fakeEngine: fakeEngine,
        storageRoot: storageRoot,
        permissions: permissions
    )
}
