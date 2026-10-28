import Foundation
import LiveTranscriptModel
import Synchronization
import Testing
@testable import Transcription

private struct LiveClient {
    let transcriber: Transcriber
    let connection: MockXPCConnection
    let service: MockTranscriberService

    init() {
        let service = MockTranscriberService()
        let connection = MockXPCConnection()
        connection.proxy = service
        self.service = service
        self.connection = connection
        transcriber = Transcriber(
            backend: .hosted(serviceName: "test.live"),
            interruptedFlag: InterruptedFlag(),
            connectionFactory: { connection }
        )
    }
}

private func config(_ sessionID: UUID = UUID(), generation: Int = 1) -> LiveSessionConfig {
    LiveSessionConfig(
        sessionID: sessionID,
        generation: generation,
        engine: .whisper,
        whisperModel: "openai_whisper-small",
        tracks: [.mic, .system],
        updateInterval: 1,
        language: .english,
        vocabulary: []
    )
}

private func update(_ config: LiveSessionConfig, revision: Int, text: String = "hello") -> LiveTrackUpdate {
    LiveTrackUpdate(
        sessionID: config.sessionID,
        generation: config.generation,
        track: .mic,
        revision: revision,
        rows: [LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: text, tailText: "")],
        gaps: [],
        transcribedThrough: 1,
        settledThrough: 1
    )
}

private func chunk(_ track: LiveTrack) -> LiveAudioChunk {
    LiveAudioChunk(track: track, startTime: 0, samples: Array(repeating: 0, count: 4000))
}

/// Everything the stream yields until it ends.
private func collect(_ stream: AsyncStream<LiveTrackUpdate>) async -> [LiveTrackUpdate] {
    var updates: [LiveTrackUpdate] = []
    for await update in stream {
        updates.append(update)
    }
    return updates
}

@Suite("Transcriber - live client")
struct TranscriberLiveClientTests {
    @Test("prepareModels sends the model names and returns the ones the worker prepared")
    func prepareModelsRoundTrips() async throws {
        let client = LiveClient()
        client.service.unpreparedModel = "missing"

        let prepared = try await client.transcriber.prepareModels(["openai_whisper-small", "missing"], keepLoaded: "openai_whisper-small")

        #expect(prepared == ["openai_whisper-small"])
        #expect(client.service.preparationRequests == [ModelPreparationRequest(models: ["openai_whisper-small", "missing"], keepLoaded: "openai_whisper-small")])

        _ = try await client.transcriber.prepareModels(["openai_whisper-small"], keepLoaded: "openai_whisper-small", reloadingKept: true)
        #expect(client.service.preparationRequests.last?.reloadsKeptModel == true)
    }

    @Test("a final pass's model loads that the worker reports reach the observer")
    func modelLoadsReachTheObserver() async throws {
        let client = LiveClient()
        let seen = Mutex<[Bool]>([])
        await client.transcriber.observeModelLoads { isLoading in seen.withLock { $0.append(isLoading) } }
        _ = try await client.transcriber.prepareModels(["openai_whisper-small"], keepLoaded: nil)

        client.connection.workerReportsModelLoading(true)
        client.connection.workerReportsModelLoading(false)
        #expect(seen.withLock { $0 } == [true, false])
    }

    @Test("a preparation request without the reload flag does not reload")
    func preparationRequestDefaultsToNoReload() throws {
        let older = Data(#"{"models":["a"],"keepLoaded":"a"}"#.utf8)
        #expect(try JSONDecoder().decode(ModelPreparationRequest.self, from: older) == ModelPreparationRequest(models: ["a"], keepLoaded: "a"))
    }

    @Test("updates from an earlier generation are dropped")
    func updatesFromOldGenerationAreDropped() async throws {
        let client = LiveClient()
        let sessionID = UUID()
        let first = config(sessionID, generation: 1)
        let restarted = config(sessionID, generation: 2)

        let firstUpdates = try await client.transcriber.startLiveSession(first)
        // The worker's session failed; the restart takes the next generation.
        client.connection.workerEnds(sessionID: sessionID, generation: 1)
        let restartedUpdates = try await client.transcriber.startLiveSession(restarted)
        client.connection.workerSends(update(first, revision: 7, text: "old"))
        client.connection.workerSends(update(restarted, revision: 1, text: "new"))
        _ = try await client.transcriber.finishLiveSession(timeout: .seconds(10))

        #expect(await collect(firstUpdates).isEmpty)
        #expect(await collect(restartedUpdates).map(\.rows.first?.settledText) == ["new"])
    }

    @Test("a start while a session is open is refused and keeps that session")
    func startWhileASessionIsOpenIsRefused() async throws {
        let client = LiveClient()
        let open = config()
        let updates = try await client.transcriber.startLiveSession(open)

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await client.transcriber.startLiveSession(config())
        }
        client.connection.workerSends(update(open, revision: 1))
        _ = try await client.transcriber.finishLiveSession(timeout: .seconds(1))

        #expect(await collect(updates).map(\.revision) == [1])
        #expect(client.service.finishTimeouts == [1])
    }

    @Test("a cancel during the start cancels the worker's session again after it")
    func cancelDuringStartCancelsAgainAfterIt() async throws {
        let client = LiveClient()
        client.service.holdsStartReply = true
        let started = config()
        let start = Task { try await client.transcriber.startLiveSession(started) }
        while !client.service.isHoldingStartReply {
            await Task.yield()
        }

        await client.transcriber.cancelLiveSession()
        client.service.releaseStartReply()

        await #expect(throws: TranscriptionError.cancelled) {
            _ = try await start.value
        }
        // The first cancel may reach the worker before the start does.
        #expect(client.service.cancelledSessions == [started.sessionID.uuidString, started.sessionID.uuidString])
    }

    @Test("an interruption ends the stream and surfaces on the next live call")
    func interruptionSurfacesOnNextLiveCall() async throws {
        let client = LiveClient()
        let updates = try await client.transcriber.startLiveSession(config())

        client.connection.simulateInterruption()

        #expect(await collect(updates).isEmpty)
        await #expect(throws: TranscriptionError.workerInterrupted) {
            try await client.transcriber.appendLiveAudio(chunk(.mic))
        }
        // Reported once; the session is gone, so nothing is sent.
        #expect(try await client.transcriber.appendLiveAudio(chunk(.mic)) == false)
        #expect(client.service.appendedSessions.isEmpty)
    }

    @Test("at most eight chunks per track are in transit")
    func atMostEightChunksInTransitPerTrack() async throws {
        let client = LiveClient()
        client.service.holdsAppendReplies = true
        _ = try await client.transcriber.startLiveSession(config())

        var micSent: [Bool] = []
        for _ in 0 ..< 9 {
            try await micSent.append(client.transcriber.appendLiveAudio(chunk(.mic)))
        }
        let systemSent = try await client.transcriber.appendLiveAudio(chunk(.system))

        #expect(micSent == Array(repeating: true, count: 8) + [false])
        #expect(systemSent)
        #expect(client.service.appendedSessions.count == 9)

        client.service.releaseAppendReply()
        #expect(try await client.transcriber.appendLiveAudio(chunk(.mic)))
    }

    @Test("a session the worker ended ends the stream")
    func workerEndedSessionEndsTheStream() async throws {
        let client = LiveClient()
        let started = config()
        let updates = try await client.transcriber.startLiveSession(started)

        client.connection.workerSends(update(started, revision: 1))
        client.connection.workerEnds(sessionID: started.sessionID, generation: started.generation)

        #expect(await collect(updates).map(\.revision) == [1])
        #expect(try await client.transcriber.appendLiveAudio(chunk(.mic)) == false)
    }

    @Test("finish returns the final updates and ends the stream")
    func finishReturnsFinalUpdatesAndEndsTheStream() async throws {
        let client = LiveClient()
        let started = config()
        client.service.finishUpdates = [update(started, revision: 9, text: "final")]
        let updates = try await client.transcriber.startLiveSession(started)

        let final = try await client.transcriber.finishLiveSession(timeout: .milliseconds(10500))

        #expect(final.map(\.rows.first?.settledText) == ["final"])
        #expect(client.service.finishTimeouts == [10.5])
        #expect(await collect(updates).isEmpty)
        #expect(try await client.transcriber.finishLiveSession(timeout: .seconds(1)).isEmpty)
    }

    @Test("a start the worker refuses ends the stream and throws its error")
    func refusedStartThrowsTheWorkerError() async throws {
        let client = LiveClient()
        client.service.startLiveError = TranscriptionError.workerBusy

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await client.transcriber.startLiveSession(config())
        }
        #expect(try await client.transcriber.appendLiveAudio(chunk(.mic)) == false)
    }

    @Test("cancelling the session tells the worker and ends the stream")
    func cancelEndsTheSession() async throws {
        let client = LiveClient()
        let started = config()
        let updates = try await client.transcriber.startLiveSession(started)

        await client.transcriber.cancelLiveSession()

        #expect(client.service.cancelledSessions == [started.sessionID.uuidString])
        #expect(await collect(updates).isEmpty)
    }

    @Test("cancelActiveWork asks the worker only when connected")
    func cancelActiveWorkNeedsAConnection() async throws {
        let client = LiveClient()
        await client.transcriber.cancelActiveWork()
        #expect(client.service.cancelActiveWorkCount == 0)

        _ = try await client.transcriber.startLiveSession(config())
        await client.transcriber.cancelActiveWork()
        #expect(client.service.cancelActiveWorkCount == 1)
    }

    @Test("the idle wait asks the worker only when connected")
    func idleWaitNeedsAConnection() async throws {
        let client = LiveClient()
        await client.transcriber.waitUntilWorkerIdle()
        #expect(client.service.idleWaitCount == 0)

        _ = try await client.transcriber.startLiveSession(config())
        await client.transcriber.waitUntilWorkerIdle()
        #expect(client.service.idleWaitCount == 1)
    }

    @Test("the in-process backend has no worker for live sessions")
    func inProcessBackendHasNoLiveSessions() async {
        let transcriber = Transcriber(backend: .inProcess, engine: StubTranscriptionEngine())
        await #expect(throws: TranscriptionError.workerUnavailable) {
            _ = try await transcriber.startLiveSession(config())
        }
    }
}

@Suite("TranscriptionError - XPC bridging")
struct TranscriptionErrorBridgingTests {
    /// What NSXPC does to an error: secure-code it as an NSError and decode it.
    private func throughXPC(_ error: TranscriptionError) throws -> NSError {
        let data = try NSKeyedArchiver.archivedData(withRootObject: error as NSError, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data)
        return try #require(decoded)
    }

    @Test("every case survives the trip through XPC")
    func everyCaseRoundTripsThroughNSError() throws {
        let cases: [TranscriptionError] = [
            .needsDownload,
            .insufficientDisk(requiredBytes: 750_000_000, availableBytes: 12),
            .downloadFailed("offline"),
            .modelLoadFailed("no encoder"),
            .workerUnavailable,
            .workerInterrupted,
            .invalidInput("empty"),
            .transcriptionFailed("decode"),
            .diarizationFailed("segmenter"),
            .cancelled,
            .workerBusy
        ]
        for error in cases {
            #expect(try TranscriptionError(bridged: throughXPC(error)) == error)
        }
    }

    @Test("other errors are not bridged")
    func foreignErrorsAreNotBridged() {
        #expect(TranscriptionError(bridged: NSError(domain: NSCocoaErrorDomain, code: 4097)) == nil)
        #expect(TranscriptionError(bridged: NSError(domain: TranscriptionError.errorDomain, code: 1)) == nil)
    }

    @Test("a worker error reaches the caller with its case")
    func bridgedWorkerErrorKeepsItsCase() async throws {
        let service = MockTranscriberService()
        service.processAudioError = try throughXPC(.cancelled)
        let adapter = XPCEngineAdapter(proxyProvider: { _ in service })

        await #expect(throws: TranscriptionError.cancelled) {
            _ = try await adapter.processAudio(micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: [])
        }
    }

    @Test("a connection error ends a call whose reply never comes")
    func connectionErrorResumesPendingCall() async {
        let handler = ErrorHandlerBox()
        let silent = MockTranscriberService()
        silent.repliesToProcessAudio = false
        let adapter = XPCEngineAdapter(proxyProvider: { errorHandler in
            handler.set(errorHandler)
            return silent
        })

        let pass = Task {
            try await adapter.processAudio(micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: [])
        }
        while !handler.isSet {
            await Task.yield()
        }
        handler.fire(NSError(domain: NSCocoaErrorDomain, code: 4099))

        await #expect(throws: TranscriptionError.workerUnavailable) {
            _ = try await pass.value
        }
    }
}

/// Holds the error handler a proxy was created with, so a test can fire it.
private final class ErrorHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (any Error) -> Void)?

    var isSet: Bool {
        lock.withLock { handler != nil }
    }

    func set(_ handler: @escaping @Sendable (any Error) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func fire(_ error: any Error) {
        lock.withLock { handler }?(error)
    }
}
