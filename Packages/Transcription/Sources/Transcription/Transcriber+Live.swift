import Foundation
import LiveTranscriptModel

/// A live session this client started.
struct LiveClientSession {
    let id: UUID
    let generation: Int
    let window = LiveChunkWindow()
}

// MARK: - Live sessions

/// The live Whisper session runs in the worker, next to the final pass. The
/// worker hosts one live session at a time and never alongside a final pass;
/// `TranscriptionService`'s queue keeps them apart, and the worker rejects an
/// overlap with `TranscriptionError.workerBusy`.
public extension Transcriber {
    /// Starts a live session in the worker. Loading the live model can take
    /// minutes the first time a build runs it, while macOS compiles it for the
    /// Neural Engine.
    ///
    /// - Returns: The session's updates, in order. The stream ends with the
    ///   session: after `finishLiveSession` or `cancelLiveSession`, when the
    ///   worker ends it (a decode failed, or `cancelActiveWork` ended it) and
    ///   when the worker is interrupted.
    ///
    ///   The component spec has one `liveUpdates` stream on the client. A
    ///   stream per session ends when its session does, as
    ///   `LiveTranscriptionSession.updates` must, so a restart gets a new one.
    /// - Throws: `TranscriptionError.workerBusy` while this client's earlier
    ///   session is still open (finish or cancel it first) or during a final
    ///   pass; `.workerUnavailable` for the `.inProcess` backend;
    ///   `.needsDownload` when the live model is not on disk; `.cancelled` when
    ///   `cancelLiveSession` ran while it started; or the worker's start error.
    func startLiveSession(_ config: LiveSessionConfig) async throws -> AsyncStream<LiveTrackUpdate> {
        try checkInterrupted()
        guard case .hosted = backend else { throw TranscriptionError.workerUnavailable }
        guard openLiveSession == nil else { throw TranscriptionError.workerBusy }
        ensureConnected()
        let configData: Data
        do {
            configData = try JSONEncoder().encode(config)
        } catch {
            throw TranscriptionError.invalidInput("Failed to encode LiveSessionConfig: \(error.localizedDescription)")
        }
        // The route opens before the start message goes out, so no early update is dropped.
        let updates = liveRoute.begin(sessionID: config.sessionID, generation: config.generation)
        let session = LiveClientSession(id: config.sessionID, generation: config.generation)
        liveSession = session
        do {
            try await workerCall { proxy, reply in
                proxy.startLiveSession(configData: configData) { error in
                    reply.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        } catch {
            endLiveSession(session)
            throw error
        }
        guard isCurrent(session) else {
            // Cancelled while it started. The cancel can reach the worker
            // before the start does, so the worker may have started it anyway.
            try? await workerCall { proxy, reply in
                proxy.cancelLiveSession(sessionID: session.id.uuidString) { reply.resume(returning: ()) }
            }
            throw TranscriptionError.cancelled
        }
        return updates
    }

    /// Sends one chunk without waiting for the worker. At most
    /// `LiveChunkWindow.limit` chunks per track are unacknowledged at a time.
    ///
    /// - Returns: False when the chunk was not sent: its track has 8 chunks in
    ///   transit, or no session is open. The caller records the lost audio as
    ///   a gap and marks its next chunk discontinuous.
    /// - Throws: `TranscriptionError.workerInterrupted` once after the worker
    ///   was interrupted.
    @discardableResult
    func appendLiveAudio(_ chunk: LiveAudioChunk) throws -> Bool {
        try checkInterrupted()
        guard let session = openLiveSession, session.window.reserve(chunk.track) else { return false }
        let window = session.window
        let track = chunk.track
        guard let proxy = xpcConnection?.remoteObjectProxy(errorHandler: { _ in window.release(track) }) else {
            window.release(track)
            return false
        }
        proxy.appendLiveAudio(sessionID: session.id.uuidString, generation: session.generation, chunkData: chunk.encodedForXPC()) {
            window.release(track)
        }
        return true
    }

    func setLiveUpdateInterval(_ seconds: TimeInterval) {
        guard let session = openLiveSession else { return }
        oneWayProxy()?.setLiveUpdateInterval(sessionID: session.id.uuidString, seconds: seconds)
    }

    func setLivePaused(_ paused: Bool) {
        guard let session = openLiveSession else { return }
        oneWayProxy()?.setLivePaused(sessionID: session.id.uuidString, paused: paused)
    }

    /// Finishes the session: the worker decodes what it holds, at most until
    /// `timeout`, and replies once it is idle.
    /// - Returns: The final updates, at most one per track. On timeout, the
    ///   rows that could not settle come back marked incomplete.
    func finishLiveSession(timeout: Duration) async throws -> [LiveTrackUpdate] {
        try checkInterrupted()
        guard let session = openLiveSession else { return [] }
        defer { endLiveSession(session) }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let data: Data = try await workerCall { proxy, reply in
            proxy.finishLiveSession(sessionID: session.id.uuidString, timeoutSeconds: seconds) { data, error in
                if let error {
                    reply.resume(throwing: error)
                } else {
                    reply.resume(returning: data ?? Data("[]".utf8))
                }
            }
        }
        do {
            return try JSONDecoder().decode([LiveTrackUpdate].self, from: data)
        } catch {
            throw TranscriptionError.transcriptionFailed("Failed to decode the final live updates: \(error.localizedDescription)")
        }
    }

    /// Ends the session without finishing it. Returns once the worker is idle.
    func cancelLiveSession() async {
        guard let session = openLiveSession else { return }
        endLiveSession(session)
        try? await workerCall { proxy, reply in
            proxy.cancelLiveSession(sessionID: session.id.uuidString) { reply.resume(returning: ()) }
        }
    }

    /// Stops whatever the worker is running (a final pass fails with
    /// `TranscriptionError.cancelled`; a live session ends) and returns once
    /// the worker replies that it is idle, or its connection fails. Without a
    /// connection there is nothing of ours to stop.
    func cancelActiveWork() async {
        guard xpcConnection != nil else { return }
        try? await workerCall { proxy, reply in
            proxy.cancelActiveWork { reply.resume(returning: ()) }
        }
    }

    /// Returns once the worker is idle, without stopping anything, or when its
    /// connection fails. Without a connection there is nothing to wait for.
    func waitUntilWorkerIdle() async {
        guard xpcConnection != nil else { return }
        try? await workerCall { proxy, reply in
            proxy.waitUntilIdle { reply.resume(returning: ()) }
        }
    }
}

// MARK: - Model preparation

public extension Transcriber {
    /// Loads each named Whisper model in the worker, so macOS compiles it
    /// before a meeting needs it, and unloads it again, except `keepLoaded`,
    /// which stays loaded for the live sessions that follow while the worker
    /// runs. Models not on disk are skipped; nothing is downloaded.
    /// `cancelActiveWork` stops it after the model loading at the time.
    ///
    /// Sent from this actor, so a `cancelActiveWork` sent later reaches the
    /// worker after it.
    /// - Returns: The models prepared, also after a cancel; none for the
    ///   `.inProcess` backend, which has no separate worker to warm.
    /// - Throws: `TranscriptionError.workerBusy` while the worker runs other
    ///   work, or the connection's error.
    /// - Parameter reloadingKept: Loads `keepLoaded` again even when it is
    ///   loaded, for its new files.
    func prepareModels(_ models: [String], keepLoaded: String? = nil, reloadingKept: Bool = false) async throws -> [String] {
        try checkInterrupted()
        guard case .hosted = backend else { return [] }
        ensureConnected()
        let request = try JSONEncoder().encode(ModelPreparationRequest(models: models, keepLoaded: keepLoaded, reloadsKeptModel: reloadingKept))
        let data: Data = try await workerCall { proxy, reply in
            proxy.prepareModels(requestData: request) { data, error in
                if let error {
                    reply.resume(throwing: error)
                } else {
                    reply.resume(returning: data ?? Data("[]".utf8))
                }
            }
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - Helpers

extension Transcriber {
    /// The live session, while its stream is open.
    private var openLiveSession: LiveClientSession? {
        guard let liveSession, liveRoute.isCurrent(sessionID: liveSession.id, generation: liveSession.generation) else { return nil }
        return liveSession
    }

    private func endLiveSession(_ session: LiveClientSession) {
        liveRoute.end(sessionID: session.id, generation: session.generation)
        if isCurrent(session) {
            liveSession = nil
        }
    }

    private func isCurrent(_ session: LiveClientSession) -> Bool {
        liveSession?.id == session.id && liveSession?.generation == session.generation
    }

    /// A proxy for messages without a reply; a send error has nobody to tell.
    private func oneWayProxy() -> (any TranscriberServiceProtocol)? {
        xpcConnection?.remoteObjectProxy(errorHandler: { _ in })
    }

    /// Sends one message and waits for its reply or for the connection's error.
    private func workerCall<Value: Sendable>(
        _ send: (any TranscriberServiceProtocol, ReplyOnce<Value>) -> Void
    ) async throws -> Value {
        let connection = xpcConnection
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let reply = ReplyOnce(continuation)
                guard let proxy = connection?.remoteObjectProxy(errorHandler: { reply.resume(throwing: $0) }) else {
                    reply.resume(throwing: TranscriptionError.workerUnavailable)
                    return
                }
                send(proxy, reply)
            }
        } catch {
            throw XPCEngineAdapter.mapError(error)
        }
    }
}
