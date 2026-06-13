import AudioCapture
import BiscottiTestSupport
import DataStore
import Foundation
import Permissions
import Recording
import Testing

// MARK: - Test fixture

/// Bundles recording-specific test dependencies.
@MainActor
struct RecordingTestFixture {
    let controller: RecordingController
    let store: DataStore
    let fakeRecorder: FakeRecorder
    let storageRoot: URL
    let permissions: Permissions

    func cleanup() {
        try? FileManager.default.removeItem(at: storageRoot)
    }
}

@MainActor
private func makeFixture(
    micStatus: PermissionState = .authorized,
    micRequestResult: Bool = true,
    startError: (any Error)? = nil,
    probableDenied: Bool = false,
    stateValues: [CaptureState] = [],
    denialCheckDelay: Duration = .seconds(2)
) throws -> RecordingTestFixture {
    let store = try DataStore(storage: .inMemory)
    let micAuth = FakeMicAuthorizer(status: micStatus, requestResult: micRequestResult)
    let permissions = Permissions(mic: micAuth)

    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

    let fakeRecorder = FakeRecorder(
        startError: startError,
        probableDenied: probableDenied,
        stateValues: stateValues
    )

    let controller = RecordingController(
        store: store,
        permissions: permissions,
        storageRoot: storageRoot,
        makeRecorder: { fakeRecorder },
        denialCheckDelay: denialCheckDelay
    )

    return RecordingTestFixture(
        controller: controller,
        store: store,
        fakeRecorder: fakeRecorder,
        storageRoot: storageRoot,
        permissions: permissions
    )
}

// MARK: - Start / Stop tests

@Suite("RecordingController -- start and stop")
struct RecordingStartStopTests {
    @Test("Start creates meeting and links audio refs")
    @MainActor
    func startCreatesMeetingAndLinksAudioRefs() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()

        #expect(fix.controller.state.isRecording == true)
        #expect(fix.controller.state.meetingID != nil)
        #expect(fix.controller.lastError == nil)
        #expect(fix.fakeRecorder.backing.startCalled == true)

        // System-audio prompt must be triggered before recording starts
        #expect(fix.fakeRecorder.backing.requestPermissionsCalled == true)

        // Verify meeting was created in the store
        let meetingID = try #require(fix.controller.state.meetingID)
        try await fix.store.read { store in
            let meeting = try #require(try store.meeting(id: meetingID))
            #expect(meeting.title == "Untitled Meeting")
        }

        // Verify audio refs were attached
        try await fix.store.read { store in
            let audioRefs = try store.fetchAllAudioRefs()
            let count = audioRefs.count
            let hasMic = audioRefs.contains(where: { $0.role == .mic })
            let hasSystem = audioRefs.contains(where: { $0.role == .system })
            #expect(count == 2)
            #expect(hasMic)
            #expect(hasSystem)
        }
    }

    @Test("Start requests mic permission when not determined")
    @MainActor
    func startRequestsMicPermission() async throws {
        let store = try DataStore(storage: .inMemory)
        let micAuth = FakeMicAuthorizer(status: .notDetermined, requestResult: true)
        let permissions = Permissions(mic: micAuth)
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let controller = RecordingController(
            store: store,
            permissions: permissions,
            storageRoot: storageRoot,
            makeRecorder: { FakeRecorder() }
        )

        await controller.start()

        #expect(micAuth.backing.requestCalled == true)
        #expect(controller.state.isRecording == true)
    }

    @Test("Start denied mic permission produces error")
    @MainActor
    func startDeniedMicPermission() async throws {
        let fix = try makeFixture(micStatus: .denied, micRequestResult: false)
        defer { fix.cleanup() }

        await fix.controller.start()

        #expect(fix.controller.state.isRecording == false)
        #expect(fix.controller.lastError == .permissionDenied(.microphone))

        let summaries = try await fix.store.meetingSummaries(limit: 10)
        #expect(summaries.isEmpty)
    }

    @Test("Start while already recording produces error")
    @MainActor
    func startAlreadyRecording() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()
        #expect(fix.controller.state.isRecording == true)

        await fix.controller.start()
        #expect(fix.controller.lastError == .alreadyRecording)
    }

    @Test("Start engine failure surfaces error")
    @MainActor
    func startEngineFailure() async throws {
        let fix = try makeFixture(startError: CaptureError.micEngineFailed("test failure"))
        defer { fix.cleanup() }

        await fix.controller.start()

        #expect(fix.controller.state.isRecording == false)
        #expect(fix.controller.lastError != nil)
        if case let .engineFailed(msg) = fix.controller.lastError {
            #expect(msg.contains("test failure"))
        } else {
            Issue.record("Expected engineFailed error")
        }
    }

    @Test("Start engine failure cleans up meeting and directory")
    @MainActor
    func startEngineFailureCleansUp() async throws {
        let fix = try makeFixture(startError: CaptureError.micEngineFailed("boom"))
        defer { fix.cleanup() }

        await fix.controller.start()

        #expect(fix.controller.state.isRecording == false)

        // Deterministically await the retained cleanup task (no fixed sleep)
        await fix.controller.awaitPendingCleanup()

        // The meeting should be deleted from the store (no orphan)
        let summaries = try await fix.store.meetingSummaries(limit: 10)
        #expect(summaries.isEmpty)

        // The recording directory + marker should be removed
        let contents = try? FileManager.default.contentsOfDirectory(
            at: fix.storageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        // Only the storage root itself should remain (no meeting subdirectory)
        #expect((contents ?? []).isEmpty)
    }

    @Test("Start with notDetermined mic that denies produces error")
    @MainActor
    func startNotDeterminedMicDenied() async throws {
        let fix = try makeFixture(micStatus: .notDetermined, micRequestResult: false)
        defer { fix.cleanup() }

        await fix.controller.start()

        #expect(fix.controller.state.isRecording == false)
        #expect(fix.controller.lastError == .permissionDenied(.microphone))

        let summaries = try await fix.store.meetingSummaries(limit: 10)
        #expect(summaries.isEmpty)
    }

    @Test("Stop finalizes and returns meeting ID")
    @MainActor
    func stopFinalizesAndReturnsMeetingID() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()
        let meetingID = fix.controller.state.meetingID

        let returnedID = await fix.controller.stop()

        #expect(returnedID == meetingID)
        #expect(fix.controller.state.isRecording == false)
        #expect(fix.controller.state == .idle)
        #expect(fix.fakeRecorder.backing.stopCalled == true)

        // Marker file should be deleted
        let markerURL = try fix.storageRoot
            .appendingPathComponent(#require(meetingID).uuidString)
            .appendingPathComponent(RecordingController.markerFileName)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Stop when not recording returns nil")
    @MainActor
    func stopWhenNotRecording() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let result = await fix.controller.stop()
        #expect(result == nil)
    }

    @Test("Stop clears state to idle")
    @MainActor
    func stopClearsState() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()
        _ = await fix.controller.stop()

        #expect(fix.controller.state == .idle)
        #expect(fix.controller.state.meetingID == nil)
    }

    @Test("Auto-title is date-free")
    @MainActor
    func autoTitleFormat() {
        let title = RecordingController.autoTitle()
        #expect(title == "Untitled Meeting")
        // Date must NOT be embedded in the title -- it is shown
        // separately from MeetingDetailData.date metadata.
        #expect(!title.contains("\u{2014}")) // no em dash
    }
}

// MARK: - State, inference, and recovery tests

@Suite("RecordingController -- state and recovery")
struct RecordingStateRecoveryTests {
    @Test("System audio denial inference sets warning and notifies permissions")
    @MainActor
    func systemAudioDenialInference() async throws {
        let fix = try makeFixture(probableDenied: true, denialCheckDelay: .milliseconds(50))
        defer { fix.cleanup() }

        await fix.controller.start()
        #expect(fix.controller.state.isRecording == true)

        // Poll until the denial check task completes and sets the warning.
        for _ in 0 ..< 200 {
            if fix.controller.systemAudioWarning == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(fix.controller.systemAudioWarning == true)
        #expect(fix.permissions.systemAudio == .denied)
    }

    @Test("System audio authorized inference notifies permissions")
    @MainActor
    func systemAudioAuthorizedInference() async throws {
        let fix = try makeFixture(probableDenied: false, denialCheckDelay: .milliseconds(50))
        defer { fix.cleanup() }

        await fix.controller.start()

        // Poll until the denial check task completes and reports authorized.
        for _ in 0 ..< 200 {
            if fix.permissions.systemAudio == .authorized { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(fix.controller.systemAudioWarning == false)
        #expect(fix.permissions.systemAudio == .authorized)
    }

    @Test("Recover orphans reconciles stale markers")
    @MainActor
    func recoverOrphansReconciles() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        // Simulate a crashed recording
        let meetingID = try await fix.store.createMeeting(title: "Crashed Recording")
        let meetingDir = fix.storageRoot.appendingPathComponent(meetingID.uuidString)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        let markerURL = meetingDir.appendingPathComponent(RecordingController.markerFileName)
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)

        // Write fake audio files
        let micPath = meetingDir.appendingPathComponent("mic.aac")
        let sysPath = meetingDir.appendingPathComponent("system.aac")
        try Data(repeating: 0xFF, count: 128).write(to: micPath)
        try Data(repeating: 0xAA, count: 256).write(to: sysPath)

        let micRef = AudioFileRef(role: .mic, path: micPath.path, byteSize: 0, isPresent: false)
        let sysRef = AudioFileRef(role: .system, path: sysPath.path, byteSize: 0, isPresent: false)
        try await fix.store.attachAudio([micRef, sysRef], to: meetingID)

        await fix.controller.recoverOrphans()

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        try await fix.store.read { store in
            let audioRefs = try store.fetchAllAudioRefs()
            let micRefAfter = audioRefs.first(where: { $0.role == .mic })
            let sysRefAfter = audioRefs.first(where: { $0.role == .system })
            #expect(micRefAfter?.isPresent == true)
            #expect(micRefAfter?.byteSize == 128)
            #expect(sysRefAfter?.isPresent == true)
            #expect(sysRefAfter?.byteSize == 256)
        }
    }

    @Test("Recover orphans is no-op when no markers exist")
    @MainActor
    func recoverOrphansNoMarkers() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let meetingDir = fix.storageRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        await fix.controller.recoverOrphans()
    }

    @Test("Storage paths match expected structure")
    @MainActor
    func storagePaths() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()
        let meetingID = try #require(fix.controller.state.meetingID)

        let expectedMic = fix.storageRoot
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent("mic.aac")
        let expectedSys = fix.storageRoot
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent("system.aac")

        try await fix.store.read { store in
            let audioRefs = try store.fetchAllAudioRefs()
            let micRef = audioRefs.first(where: { $0.role == .mic })
            let sysRef = audioRefs.first(where: { $0.role == .system })
            let micPath = try #require(micRef?.path)
            let sysPath = try #require(sysRef?.path)
            #expect(micPath == expectedMic.path)
            #expect(sysPath == expectedSys.path)
        }
    }

    @Test("Elapsed time pumps from engine state stream")
    @MainActor
    func elapsedTimePumping() async throws {
        let captureState = CaptureState(
            isRecording: true,
            elapsed: 42.5,
            micLevel: 0,
            systemLevel: 0,
            startTimestamp: 0
        )
        let fix = try makeFixture(stateValues: [captureState])
        defer { fix.cleanup() }

        await fix.controller.start()

        // Poll until the state-stream consumer pumps the elapsed value.
        for _ in 0 ..< 200 {
            if fix.controller.state.elapsed == 42.5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(fix.controller.state.elapsed == 42.5)
    }

    @Test("Marker file exists during recording")
    @MainActor
    func markerFileDuringRecording() async throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        await fix.controller.start()
        let meetingID = try #require(fix.controller.state.meetingID)

        let markerURL = fix.storageRoot
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent(RecordingController.markerFileName)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }
}
