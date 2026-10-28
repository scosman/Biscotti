import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Testing
import Transcription

/// A worker client that refuses the first starts as busy and records calls.
private actor FakeWorkerClient: LiveWorkerClient {
    private(set) var calls: [String] = []
    private var busyStarts: Int
    private var continuation: AsyncStream<LiveTrackUpdate>.Continuation?

    init(busyStarts: Int = 0) {
        self.busyStarts = busyStarts
    }

    func startLiveSession(_: LiveSessionConfig) async throws -> AsyncStream<LiveTrackUpdate> {
        calls.append("start")
        if busyStarts > 0 {
            busyStarts -= 1
            throw TranscriptionError.workerBusy
        }
        let (stream, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self)
        self.continuation = continuation
        return stream
    }

    func appendLiveAudio(_: LiveAudioChunk) async throws -> Bool {
        calls.append("append")
        return true
    }

    func setLiveUpdateInterval(_ seconds: TimeInterval) async {
        calls.append("interval \(seconds)")
    }

    func setLivePaused(_ paused: Bool) async {
        calls.append("paused \(paused)")
    }

    func finishLiveSession(timeout _: Duration) async throws -> [LiveTrackUpdate] {
        calls.append("finish")
        continuation?.finish()
        return []
    }

    func cancelActiveWork() async {
        calls.append("cancelActiveWork")
    }

    func shutdown() async {
        calls.append("shutdown")
        continuation?.finish()
    }

    func send(_ update: LiveTrackUpdate) {
        continuation?.yield(update)
    }

    /// The worker ended the session on its own.
    func endSession() {
        continuation?.finish()
    }
}

private let config = LiveTranscriptionDefaults.sessionConfig(sessionID: UUID(), generation: 1, language: .english)

@Suite("WhisperXPCSession")
struct WhisperXPCSessionTests {
    @Test("A start refused as busy cancels the worker's work and starts once more")
    func busyStartCancelsActiveWorkAndRetriesOnce() async throws {
        let client = FakeWorkerClient(busyStarts: 1)
        let session = WhisperXPCSession(client: client)
        try await session.start(config)
        #expect(await client.calls == ["start", "cancelActiveWork", "start"])

        let stubborn = FakeWorkerClient(busyStarts: 2)
        await #expect(throws: TranscriptionError.workerBusy) {
            try await WhisperXPCSession(client: stubborn).start(config)
        }
        #expect(await stubborn.calls == ["start", "cancelActiveWork", "start"])
    }

    @Test("Updates pass through, and the stream ends when the worker ends the session")
    func updatesEndWhenTheWorkerEndsTheSession() async throws {
        let client = FakeWorkerClient()
        let session = WhisperXPCSession(client: client)
        try await session.start(config)
        #expect(await session.offer(LiveAudioChunk(track: .mic, startTime: 0, samples: [0])))
        let update = LiveTrackUpdate(
            sessionID: config.sessionID, generation: 1, track: .mic, revision: 1,
            rows: [], gaps: [], transcribedThrough: 1, settledThrough: 1
        )
        await client.send(update)
        await client.endSession()

        var received: [LiveTrackUpdate] = []
        for await next in session.updates {
            received.append(next)
        }
        #expect(received == [update])
    }

    @Test("Finish and cancel shut the client down; nothing is sent after")
    func cancelShutsTheClientDown() async throws {
        let client = FakeWorkerClient()
        let session = WhisperXPCSession(client: client)
        try await session.start(config)
        await session.cancel()
        #expect(await !session.offer(LiveAudioChunk(track: .mic, startTime: 0, samples: [0])))
        #expect(await session.finish(timeout: .seconds(1)).isEmpty)
        #expect(await client.calls == ["start", "shutdown"])

        let finishing = FakeWorkerClient()
        let finished = WhisperXPCSession(client: finishing)
        try await finished.start(config)
        _ = await finished.finish(timeout: .seconds(1))
        #expect(await finishing.calls == ["start", "finish", "shutdown"])
    }
}
