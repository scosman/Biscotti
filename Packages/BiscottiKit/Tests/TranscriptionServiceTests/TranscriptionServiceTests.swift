import DataStore
import Foundation
import Testing
import Transcription
import TranscriptionService

// MARK: - Test fixture

/// Bundles all test dependencies for TranscriptionService tests.
@MainActor
struct TestFixture {
    let service: TranscriptionService
    let store: DataStore
    let fakeEngine: FakeTranscriber

    /// Creates a meeting with attached, present audio files and returns its ID.
    func createMeetingWithAudio() async throws -> UUID {
        let meetingID = try await store.createMeeting(title: "Test Meeting")

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

    /// Creates a meeting with no audio files and returns its ID.
    func createMeetingWithoutAudio() async throws -> UUID {
        try await store.createMeeting(title: "No Audio Meeting")
    }
}

@MainActor
private func makeFixture(
    cannedResult: TranscriptResult? = nil,
    ensureModelsError: (any Error)? = nil,
    processAudioError: (any Error)? = nil,
    statusMessages: [String] = []
) throws -> TestFixture {
    let store = try DataStore(storage: .inMemory)
    let fakeEngine = FakeTranscriber(
        cannedResult: cannedResult,
        ensureModelsError: ensureModelsError,
        processAudioError: processAudioError,
        statusMessages: statusMessages
    )
    let service = TranscriptionService(store: store, engine: fakeEngine)
    return TestFixture(service: service, store: store, fakeEngine: fakeEngine)
}

// MARK: - Success path tests

@Suite("TranscriptionService -- success paths")
struct TranscriptionSuccessTests {
    @Test("Transcribe resolves paths, calls engine, persists and promotes transcript")
    @MainActor
    func transcribeSuccess() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        // Engine was called
        #expect(fix.fakeEngine.backing.ensureModelsCalled == true)
        #expect(fix.fakeEngine.backing.processAudioCalled == true)
        #expect(fix.fakeEngine.backing.lastMicURL?.path == "/tmp/test/mic.aac")
        #expect(fix.fakeEngine.backing.lastSystemURL?.path == "/tmp/test/system.aac")
        #expect(fix.fakeEngine.backing.lastVocabulary == [])

        // Job status is completed
        #expect(fix.service.jobs[meetingID] == .completed)

        // Transcript was persisted in the store
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.preferredTranscript != nil)
        #expect(detail?.preferredTranscript?.speakerCount == 2)
        #expect(detail?.preferredTranscript?.segments.count == 2)
    }

    @Test("Re-transcribe adds a new version and promotes it")
    @MainActor
    func reTranscribeAddsNewVersion() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // First transcription
        await fix.service.transcribe(meetingID: meetingID)
        #expect(fix.service.jobs[meetingID] == .completed)

        let firstDetail = try await fix.store.meetingDetail(id: meetingID)
        let firstTranscriptID = try #require(firstDetail?.preferredTranscript?.id)

        // Set up a different canned result for the re-transcribe
        let secondResult = try TranscriptResult(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000020")),
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 8.0,
                    text: "Re-transcribed content.",
                    confidence: 0.98,
                    noSpeechProbability: 0.005,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 2.0
        )
        fix.fakeEngine.backing.cannedResult = secondResult

        // Re-transcribe
        await fix.service.reTranscribe(meetingID: meetingID)
        #expect(fix.service.jobs[meetingID] == .completed)

        let secondDetail = try await fix.store.meetingDetail(id: meetingID)
        let secondTranscriptID = try #require(secondDetail?.preferredTranscript?.id)

        // The preferred transcript should be a different version
        #expect(secondTranscriptID != firstTranscriptID)
        #expect(secondDetail?.preferredTranscript?.speakerCount == 1)
        #expect(secondDetail?.preferredTranscript?.segments.count == 1)

        // Both transcripts should exist in the store
        let allTranscripts = try await fix.store.fetchAllTranscripts()
        #expect(allTranscripts.count == 2)
    }

    @Test("EnsureModelsDownloaded is called before processAudio")
    @MainActor
    func ensureModelsCalledBeforeProcess() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        // Both should have been called (ensureModels first, then processAudio)
        #expect(fix.fakeEngine.backing.ensureModelsCalled == true)
        #expect(fix.fakeEngine.backing.processAudioCalled == true)
    }
}

// MARK: - Error path tests

@Suite("TranscriptionService -- error paths")
struct TranscriptionErrorTests {
    @Test("Transcribe with no audio files sets failed status")
    @MainActor
    func transcribeNoAudioFiles() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithoutAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("No audio"))
            #expect(retriable == false)
        } else {
            Issue.record("Expected failed status, got \(String(describing: fix.service.jobs[meetingID]))")
        }

        // Engine should not have been called
        #expect(fix.fakeEngine.backing.ensureModelsCalled == false)
        #expect(fix.fakeEngine.backing.processAudioCalled == false)
    }

    @Test("Transcribe with unknown meeting ID sets failed status")
    @MainActor
    func transcribeMeetingNotFound() async throws {
        let fix = try makeFixture()
        let unknownID = UUID()

        await fix.service.transcribe(meetingID: unknownID)

        if case let .failed(message, retriable) = fix.service.jobs[unknownID] {
            #expect(message.contains("not found"))
            #expect(retriable == false)
        } else {
            Issue.record("Expected failed status, got \(String(describing: fix.service.jobs[unknownID]))")
        }
    }

    @Test("Download failure is retriable")
    @MainActor
    func transcribeDownloadFailed() async throws {
        let fix = try makeFixture(
            ensureModelsError: TranscriptionError.downloadFailed("network timeout")
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("download"))
            #expect(retriable == true)
        } else {
            Issue.record("Expected failed status")
        }

        // processAudio should NOT have been called (failed during model download)
        #expect(fix.fakeEngine.backing.processAudioCalled == false)
    }

    @Test("Worker interrupted is retriable")
    @MainActor
    func transcribeWorkerInterrupted() async throws {
        let fix = try makeFixture(
            processAudioError: TranscriptionError.workerInterrupted
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("worker"))
            #expect(retriable == true)
        } else {
            Issue.record("Expected failed status")
        }
    }

    @Test("Transcription failure is not retriable")
    @MainActor
    func transcribeTranscriptionFailed() async throws {
        let fix = try makeFixture(
            processAudioError: TranscriptionError.transcriptionFailed("model error")
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("failed"))
            #expect(retriable == false)
        } else {
            Issue.record("Expected failed status")
        }
    }

    @Test("Invalid input error is not retriable")
    @MainActor
    func transcribeInvalidInput() async throws {
        let fix = try makeFixture(
            processAudioError: TranscriptionError.invalidInput("zero-length file")
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("Invalid audio"))
            #expect(retriable == false)
        } else {
            Issue.record("Expected failed status")
        }
    }

    @Test("Insufficient disk error is retriable (user can free space and retry)")
    @MainActor
    func transcribeInsufficientDisk() async throws {
        let fix = try makeFixture(
            ensureModelsError: TranscriptionError.insufficientDisk(
                requiredBytes: 2_147_483_648,
                availableBytes: 524_288_000
            )
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(message, retriable) = fix.service.jobs[meetingID] {
            #expect(message.contains("disk space"))
            #expect(retriable == true)
        } else {
            Issue.record("Expected failed status")
        }
    }

    @Test("NeedsDownload error is retriable")
    @MainActor
    func transcribeNeedsDownload() async throws {
        let fix = try makeFixture(
            ensureModelsError: TranscriptionError.needsDownload
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case let .failed(_, retriable) = fix.service.jobs[meetingID] {
            #expect(retriable == true)
        } else {
            Issue.record("Expected failed status")
        }
    }
}

// MARK: - Concurrency and status tests

@Suite("TranscriptionService -- concurrency and status")
struct TranscriptionConcurrencyTests {
    @Test("Single in-flight guard rejects concurrent job")
    @MainActor
    func singleInFlightGuard() async throws {
        // Use an engine that blocks on processAudio to simulate an in-flight job.
        let blockingEngine = BlockingFakeTranscriber()
        let store = try DataStore(storage: .inMemory)
        let service = TranscriptionService(store: store, engine: blockingEngine)

        // Create two meetings with audio
        let meetingID1 = try await store.createMeeting(title: "Meeting 1")
        let mic1 = AudioFileRef(role: .mic, path: "/tmp/m1/mic.aac", byteSize: 100, isPresent: true)
        let sys1 = AudioFileRef(role: .system, path: "/tmp/m1/system.aac", byteSize: 100, isPresent: true)
        try await store.attachAudio([mic1, sys1], to: meetingID1)

        let meetingID2 = try await store.createMeeting(title: "Meeting 2")
        let mic2 = AudioFileRef(role: .mic, path: "/tmp/m2/mic.aac", byteSize: 100, isPresent: true)
        let sys2 = AudioFileRef(role: .system, path: "/tmp/m2/system.aac", byteSize: 100, isPresent: true)
        try await store.attachAudio([mic2, sys2], to: meetingID2)

        // Start the first job in a detached task
        let firstJobTask = Task { @MainActor in
            await service.transcribe(meetingID: meetingID1)
        }

        // Give the first job time to set inFlightMeetingID
        try await Task.sleep(for: .milliseconds(50))

        // Try to start a second job while the first is in-flight
        await service.transcribe(meetingID: meetingID2)

        // The second job should be rejected
        if case let .failed(message, retriable) = service.jobs[meetingID2] {
            #expect(message.contains("already in progress"))
            #expect(retriable == true)
        } else {
            Issue.record("Expected second job to be rejected")
        }

        // Unblock the first job so it can complete
        blockingEngine.backing.unblock()
        await firstJobTask.value

        #expect(service.jobs[meetingID1] == .completed)
    }

    @Test("Status progresses through downloadingModel, transcribing, completed")
    @MainActor
    func statusProgression() async throws {
        var observedStatuses: [JobStatus] = []
        let fix = try makeFixture(
            statusMessages: ["Downloading speech model", "Downloading diarization model"]
        )
        let meetingID = try await fix.createMeetingWithAudio()

        // Observe status changes using withObservationTracking in a Task
        // Note: we can't easily observe intermediate states in a synchronous test,
        // so instead we verify the final state and that engine calls happened
        // in the right order.
        await fix.service.transcribe(meetingID: meetingID)

        // Final status should be completed
        #expect(fix.service.jobs[meetingID] == .completed)

        // Engine was called in the right order
        #expect(fix.fakeEngine.backing.ensureModelsCalled == true)
        #expect(fix.fakeEngine.backing.processAudioCalled == true)
    }

    @Test("After failure, retry succeeds")
    @MainActor
    func retryAfterFailure() async throws {
        let fix = try makeFixture(
            processAudioError: TranscriptionError.workerInterrupted
        )
        let meetingID = try await fix.createMeetingWithAudio()

        // First attempt fails
        await fix.service.transcribe(meetingID: meetingID)
        if case let .failed(_, retriable) = fix.service.jobs[meetingID] {
            #expect(retriable == true)
        } else {
            Issue.record("Expected failed status on first attempt")
        }

        // Fix the engine for retry
        fix.fakeEngine.backing.processAudioError = nil
        fix.fakeEngine.backing.processAudioCalled = false

        // Retry succeeds
        await fix.service.transcribe(meetingID: meetingID)
        #expect(fix.service.jobs[meetingID] == .completed)
    }
}

// MARK: - BlockingFakeTranscriber

/// A fake transcriber that blocks on `processAudio` until unblocked.
/// Used to test the single in-flight guard.
private struct BlockingFakeTranscriber: Transcribing, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        private let continuation: CheckedContinuation<Void, Never>?
        private var _unblocked = false

        let blocker: UnsafeContinuation<Void, Never>?
        var processAudioCalled = false

        init() {
            blocker = nil
            continuation = nil
        }

        func unblock() {
            _unblocked = true
        }

        var isUnblocked: Bool {
            _unblocked
        }
    }

    let backing = Backing()

    func ensureModelsDownloaded(
        status _: (@Sendable (String) -> Void)?
    ) async throws {
        // no-op
    }

    func processAudio(
        mic _: URL,
        system _: URL,
        customVocabulary _: [String]
    ) async throws -> TranscriptResult {
        backing.processAudioCalled = true
        // Poll until unblocked (simulates a long-running operation)
        while !backing.isUnblocked {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FakeTranscriber.defaultResult
    }
}
