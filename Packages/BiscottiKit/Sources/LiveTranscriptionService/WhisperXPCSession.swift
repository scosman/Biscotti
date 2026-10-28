import Foundation
import LiveTranscriptModel
import os
import Transcription

/// What `WhisperXPCSession` needs from the transcription worker's client.
/// `Transcriber` is the real one.
public protocol LiveWorkerClient: Sendable {
    func startLiveSession(_ config: LiveSessionConfig) async throws -> AsyncStream<LiveTrackUpdate>
    func appendLiveAudio(_ chunk: LiveAudioChunk) async throws -> Bool
    func setLiveUpdateInterval(_ seconds: TimeInterval) async
    func setLivePaused(_ paused: Bool) async
    func finishLiveSession(timeout: Duration) async throws -> [LiveTrackUpdate]
    func cancelActiveWork() async
    func shutdown() async
}

extension Transcriber: LiveWorkerClient {}

/// The live Whisper session in the transcription worker, driven over XPC.
///
/// Each session has its own client, so its connection ends with it: `finish`
/// and `cancel` shut the client down. Closing the connection also ends the
/// worker's session when no reply comes, and a worker stuck in a decode exits
/// once no connection is left.
public actor WhisperXPCSession: LiveEngineSession {
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    public nonisolated let updates: AsyncStream<LiveTrackUpdate>
    private let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    private let client: any LiveWorkerClient
    private var forwarder: Task<Void, Never>?
    private var isEnded = false

    public init(client: any LiveWorkerClient) {
        self.client = client
        (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self, bufferingPolicy: .unbounded)
    }

    /// Starts the worker's session. There is no timeout: loading the model can
    /// take minutes the first time a build runs it.
    ///
    /// A start refused as `workerBusy` cancels the worker's active work and
    /// tries once more: a final pass that reached the worker after the queue's
    /// cancel, or an earlier recording's session, still holds it.
    public func start(_ config: LiveSessionConfig) async throws {
        guard !isEnded else { throw TranscriptionError.cancelled }
        let workerUpdates: AsyncStream<LiveTrackUpdate>
        do {
            workerUpdates = try await client.startLiveSession(config)
        } catch let error as TranscriptionError where error == .workerBusy && !isEnded {
            Self.log.notice("The transcription worker was busy; cancelling its work and starting the live session again")
            await client.cancelActiveWork()
            workerUpdates = try await client.startLiveSession(config)
        }
        guard !isEnded else { throw TranscriptionError.cancelled }
        let continuation = continuation
        forwarder = Task {
            for await update in workerUpdates {
                continuation.yield(update)
            }
            // The worker ended the session, or the connection was lost.
            continuation.finish()
        }
    }

    public func offer(_ chunk: LiveAudioChunk) async -> Bool {
        guard !isEnded else { return false }
        return await (try? client.appendLiveAudio(chunk)) ?? false
    }

    public func append(_ chunk: LiveAudioChunk) async {
        _ = await offer(chunk)
    }

    public func setUpdateInterval(_ seconds: TimeInterval) async {
        guard !isEnded else { return }
        await client.setLiveUpdateInterval(seconds)
    }

    public func setPaused(_ paused: Bool) async {
        guard !isEnded else { return }
        await client.setLivePaused(paused)
    }

    /// Finishes the worker's session and returns its final updates. A worker
    /// that never replies keeps this waiting until `cancel()`.
    public func finish(timeout: Duration) async -> [LiveTrackUpdate] {
        guard !isEnded else { return [] }
        let finals = await (try? client.finishLiveSession(timeout: timeout)) ?? []
        await end()
        return finals
    }

    public func cancel() async {
        await end()
    }

    private func end() async {
        guard !isEnded else { return }
        isEnded = true
        await client.shutdown()
        forwarder?.cancel()
        continuation.finish()
    }
}

/// The live Whisper model in the app's model cache.
public struct WhisperLiveModel: LiveModelProviding {
    public let name: String

    public init(name: String = LiveTranscriptionDefaults.whisperModel) {
        self.name = name
    }

    public func isPresent() -> Bool {
        WhisperModelFiles.isPresent(model: name)
    }

    public func download(status: @escaping @Sendable (String) -> Void) async throws {
        try await WhisperModelFiles.download(model: name, status: status)
    }
}
