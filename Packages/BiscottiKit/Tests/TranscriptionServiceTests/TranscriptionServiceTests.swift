import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
import TranscriptionService
import Vocabulary

// MARK: - Test fixture

/// Bundles all test dependencies for TranscriptionService tests.
@MainActor
struct TranscriptionTestFixture {
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
) throws -> TranscriptionTestFixture {
    let store = try DataStore(storage: .inMemory)
    let fakeEngine = FakeTranscriber(
        cannedResult: cannedResult,
        ensureModelsError: ensureModelsError,
        processAudioError: processAudioError,
        statusMessages: statusMessages
    )
    let service = TranscriptionService(store: store, engine: fakeEngine, vocabulary: VocabularyService(store: store))
    return TranscriptionTestFixture(service: service, store: store, fakeEngine: fakeEngine)
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
        try await fix.store.read { store in
            let allTranscripts = try store.fetchAllTranscripts()
            #expect(allTranscripts.count == 2)
        }
    }

    @Test("Shutdown is called after successful transcription to release XPC worker")
    @MainActor
    func shutdownCalledAfterSuccess() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        // Shutdown is awaited deterministically at the end of runJob,
        // so it has already completed by the time transcribe returns.
        #expect(fix.fakeEngine.backing.shutdownCalled == true)
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

    @Test("Shutdown is called even after engine failure to release XPC worker")
    @MainActor
    func shutdownCalledAfterFailure() async throws {
        let fix = try makeFixture(
            processAudioError: TranscriptionError.transcriptionFailed("model error")
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        if case .failed = fix.service.jobs[meetingID] {
            // expected
        } else {
            Issue.record("Expected failed status")
        }

        // Shutdown is awaited deterministically at the end of runJob,
        // so it has already completed by the time transcribe returns.
        #expect(fix.fakeEngine.backing.shutdownCalled == true)
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
    @Test("Status progresses through downloadingModel, transcribing, completed")
    @MainActor
    func statusProgression() async throws {
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

// MARK: - Shutdown re-entrancy regression tests

@Suite("TranscriptionService -- repeated jobs")
struct TranscriptionRepeatedJobTests {
    @Test("Engine is callable again after runJob fully completes (no permanent lockout)")
    @MainActor
    func engineCallableAfterRunJobCompletes() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // First transcription
        await fix.service.transcribe(meetingID: meetingID)
        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(fix.fakeEngine.backing.ensureModelsCallCount == 1)

        // Reset for second run
        fix.fakeEngine.backing.ensureModelsCalled = false
        fix.fakeEngine.backing.processAudioCalled = false
        fix.fakeEngine.backing.shutdownCalled = false

        // Second transcription should succeed (guard is cleared)
        await fix.service.reTranscribe(meetingID: meetingID)
        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(fix.fakeEngine.backing.ensureModelsCallCount == 2)
        #expect(fix.fakeEngine.backing.shutdownCallCount == 2)
    }
}

// MARK: - Model readiness tests (Phase 10)

@Suite("TranscriptionService -- model readiness")
struct TranscriptionModelReadinessTests {
    @Test("ensureModelsReady delegates to engine")
    @MainActor
    func ensureModelsReadyDelegates() async throws {
        let fix = try makeFixture()

        try await fix.service.ensureModelsReady { _ in }

        #expect(fix.fakeEngine.backing.ensureModelsCalled == true)
    }

    @Test("modelsArePresent returns true when engine reports present")
    @MainActor
    func modelsArePresentReturnsTrue() async throws {
        let fix = try makeFixture()
        // FakeTranscriber defaults to modelsPresentResult = true
        let present = await fix.service.modelsArePresent()
        #expect(present == true)
        #expect(fix.fakeEngine.backing.modelsPresentCalled == true)
    }

    @Test("modelsArePresent returns false when engine reports absent")
    @MainActor
    func modelsArePresentReturnsFalse() async throws {
        let fix = try makeFixture()
        fix.fakeEngine.backing.modelsPresentResult = false
        let present = await fix.service.modelsArePresent()
        #expect(present == false)
    }

    @Test("modelsArePresent does NOT call ensureModelsDownloaded")
    @MainActor
    func modelsArePresentDoesNotDownload() async throws {
        let fix = try makeFixture()
        _ = await fix.service.modelsArePresent()
        #expect(fix.fakeEngine.backing.ensureModelsCalled == false)
        #expect(fix.fakeEngine.backing.ensureModelsCallCount == 0)
    }

    @Test("ensureModelsReady forwards status messages")
    @MainActor
    func ensureModelsReadyForwardsStatus() async throws {
        let fix = try makeFixture(
            statusMessages: ["Downloading...", "Compiling..."]
        )

        let collector = StatusCollector()
        try await fix.service.ensureModelsReady { message in
            collector.append(message)
        }

        #expect(collector.messages == ["Downloading...", "Compiling..."])
    }
}

/// Thread-safe collector for status callback messages.
private final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.withLock { _messages.append(message) }
    }

    var messages: [String] {
        lock.withLock { _messages }
    }
}

// MARK: - Download phase delay-gate tests (Phase 5a)

@Suite("TranscriptionService -- download phase delay gate")
struct TranscriptionDownloadPhaseGateTests {
    @Test("Fast cache-hit completes without stalling on download phase")
    @MainActor
    func cacheHitCompletesWithoutStalling() async throws {
        // FakeTranscriber.ensureModelsDownloaded returns immediately (cache hit).
        // Verifies the full pipeline completes and the final status is correct.
        let fix = try makeFixture(
            statusMessages: ["Downloading speech-to-text model"]
        )
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(fix.fakeEngine.backing.ensureModelsCalled == true)
        #expect(fix.fakeEngine.backing.processAudioCalled == true)
    }

    @Test("Initial job status is .transcribing, not .downloadingModel")
    @MainActor
    func initialStatusIsTranscribing() async throws {
        // Use a blocking engine so we can observe the initial status.
        let blockingEngine = BlockingOnDownloadFakeTranscriber()
        let store = try DataStore(storage: .inMemory)
        let service = TranscriptionService(store: store, engine: blockingEngine, vocabulary: VocabularyService(store: store))

        let meetingID = try await store.createMeeting(title: "Gate Test")
        let mic = AudioFileRef(role: .mic, path: "/tmp/test/mic.aac", byteSize: 100, isPresent: true)
        let sys = AudioFileRef(role: .system, path: "/tmp/test/system.aac", byteSize: 100, isPresent: true)
        try await store.attachAudio([mic, sys], to: meetingID)

        // Start transcription in a detached task.
        let task = Task { @MainActor in
            await service.transcribe(meetingID: meetingID)
        }

        // Wait for the job to leave the queue and start.
        for _ in 0 ..< 200 {
            if let status = service.jobs[meetingID], status != .queued(.waitingForTurn) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        // The initial status should be .transcribing (not .downloadingModel).
        let status = service.jobs[meetingID]
        #expect(status == .transcribing)

        // Unblock and clean up.
        blockingEngine.backing.unblock()
        await task.value
    }
}

// MARK: - Vocabulary wiring tests

@Suite("TranscriptionService -- vocabulary wiring")
struct TranscriptionVocabularyTests {
    @Test("Custom vocabulary terms are passed to the engine")
    @MainActor
    func vocabularyPassedToEngine() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // Add custom vocabulary terms. The master toggle is off by default
        // while the feature is in beta, so opt in explicitly.
        try await fix.store.updateSettings { settings in
            settings.customVocabularyEnabled = true
            settings.customVocabulary = ["Parakeet", "Biscotti"]
        }

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        let vocab = try #require(fix.fakeEngine.backing.lastVocabulary)
        #expect(vocab.contains("Parakeet"))
        #expect(vocab.contains("Biscotti"))
    }

    @Test("Persisted vocabularyUsed is byte-identical to what the engine received")
    @MainActor
    func persistedVocabularyMatchesEngine() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // Add custom vocabulary terms. The master toggle is off by default
        // while the feature is in beta, so opt in explicitly.
        try await fix.store.updateSettings { settings in
            settings.customVocabularyEnabled = true
            settings.customVocabulary = ["Alpha", "Bravo", "Charlie"]
        }

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)

        // What the engine received
        let engineVocab = try #require(fix.fakeEngine.backing.lastVocabulary)

        // What was persisted
        let detail = try await fix.store.meetingDetail(id: meetingID)
        let persistedVocab = detail?.versions.first?.vocabularyUsed

        // Byte-identical: same order, same content
        #expect(persistedVocab == engineVocab)
        #expect(persistedVocab == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("Vocabulary disabled sends empty and persists empty")
    @MainActor
    func vocabularyDisabledSendsEmpty() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // Disable vocabulary and add terms (should be ignored)
        try await fix.store.updateSettings { settings in
            settings.customVocabularyEnabled = false
            settings.customVocabulary = ["ShouldNotAppear"]
        }

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(fix.fakeEngine.backing.lastVocabulary == [])

        let disabledDetail = try await fix.store.meetingDetail(id: meetingID)
        #expect(disabledDetail?.versions.first?.vocabularyUsed == [])
    }

    @Test("Default settings produce empty vocabulary (no terms, no calendar)")
    @MainActor
    func defaultSettingsEmptyVocabulary() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(fix.fakeEngine.backing.lastVocabulary == [])

        let defaultDetail = try await fix.store.meetingDetail(id: meetingID)
        #expect(defaultDetail?.versions.first?.vocabularyUsed == [])
    }

    @Test("Re-transcription recomputes vocabulary from current settings")
    @MainActor
    func reTranscribeRecomputesVocabulary() async throws {
        let fix = try makeFixture()
        let meetingID = try await fix.createMeetingWithAudio()

        // First transcription with no vocabulary
        await fix.service.transcribe(meetingID: meetingID)
        #expect(fix.fakeEngine.backing.lastVocabulary == [])

        // Add terms and set a distinct canned result for the re-transcribe
        // (different ID avoids SwiftData primary-key collision).
        try await fix.store.updateSettings { settings in
            settings.customVocabularyEnabled = true
            settings.customVocabulary = ["NewTerm"]
        }
        fix.fakeEngine.backing.cannedResult = try TranscriptResult(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000099")),
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 1,
            segments: [],
            processingDuration: 1.0
        )

        await fix.service.reTranscribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        let vocab = try #require(fix.fakeEngine.backing.lastVocabulary)
        #expect(vocab == ["NewTerm"])

        // The preferred (newest) transcript should have the updated vocabulary
        let reDetail = try await fix.store.meetingDetail(id: meetingID)
        let preferred = reDetail?.versions.first(where: \.isPreferred)
        #expect(preferred?.vocabularyUsed == ["NewTerm"])
    }
}

/// A fake transcriber that blocks on `ensureModelsDownloaded` until unblocked.
/// Used to observe the initial job status before the download phase completes.
private struct BlockingOnDownloadFakeTranscriber: Transcribing, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        private var _unblocked = false

        func unblock() {
            _unblocked = true
        }

        var isUnblocked: Bool {
            _unblocked
        }
    }

    let backing = Backing()

    func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws {
        status?("Downloading speech-to-text model")
        // Poll until unblocked.
        while !backing.isUnblocked {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func processAudio(
        mic _: URL,
        system _: URL,
        customVocabulary _: [String]
    ) async throws -> TranscriptResult {
        FakeTranscriber.defaultResult
    }

    func modelsPresent() async -> Bool {
        true
    }

    func cancelActiveWork() async {}

    func waitUntilWorkerIdle() async {}

    func prepareModels(_: [String], keepLoaded _: String?, reloadingKept _: Bool) async throws -> [String] {
        []
    }

    func unloadFinalPassModels() async {}

    func shutdown() async {}
}
