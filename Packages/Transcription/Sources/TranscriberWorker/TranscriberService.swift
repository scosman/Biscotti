import Foundation
import LiveTranscriptModel
import os.log
import Synchronization
import Transcription

/// Wraps a non-`Sendable` value so it can cross into a `@Sendable` closure.
/// Used for the NSXPC remote-object proxy, which is thread-safe at runtime
/// but not statically `Sendable`.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

/// The object `BiscottiTranscriber.xpc` exports on each connection. It turns
/// the `@objc` reply-handler protocol into calls on the process's `EngineHost`.
///
/// NSXPC delivers one connection's messages in order, but a `Task` per
/// message may reach the `EngineHost` in any order, so two inboxes keep the
/// order that matters:
/// - Final-pass admission and `cancelActiveWork` share one, so a cancel sent
///   after a pass always stops it. The pass itself is awaited outside it.
/// - Live messages share the other, so chunks arrive in order and a finish
///   comes after the last chunk. A live cancel skips it, so it can cut short
///   a finish that is still running.
///
/// A model preparation is admitted like a final pass. Downloads, unloads,
/// the idle wait and the health check run as they arrive.
///
/// Thread-safety: the state is the `EngineHost` actor, the inboxes, a locked
/// connection state and a weak reference to the connection, so
/// `@unchecked Sendable` is safe.
public final class TranscriberService: NSObject, TranscriberServiceProtocol, LiveSessionOwner, @unchecked Sendable {
    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "TranscriberXPCHost")

    /// One lock for both, so a pass admitted as the connection closes is
    /// either seen by the close or sees it.
    private struct ConnectionState {
        var isClosed = false
        var runningPass: EngineHost.FinalPass?
    }

    private let host: EngineHost
    private let admissionInbox = SerialInbox()
    private let liveInbox = SerialInbox()
    private let state = Mutex(ConnectionState())

    /// The owning connection, used to reach the client's status callback.
    /// Weak to avoid a retain cycle (the connection retains this exported
    /// object). If the connection is torn down, the proxy obtained from it
    /// drops further fire-and-forget messages; NSXPC proxies tolerate a dead
    /// connection.
    private weak var connection: NSXPCConnection?

    /// - Parameter host: The process's one host; the worker's `main` passes
    ///   `EngineHost.workerProcessHost(onStuckDecode:)`.
    public init(connection: NSXPCConnection?, host: EngineHost) {
        self.connection = connection
        self.host = host
        super.init()
    }

    /// Call from the connection's invalidation handler. Nobody waits for this
    /// connection's work any more, and another connection may keep the
    /// process alive, so its work stops: the running pass is cancelled,
    /// queued passes and starts are refused, a start in progress is stopped
    /// and the live session ends. The end also runs after the starts already
    /// queued, so no session outlives the connection.
    public func connectionDidClose() {
        let runningPass = state.withLock { state in
            state.isClosed = true
            return state.runningPass
        }
        runningPass?.cancel()
        let host = host
        Task { [self] in await host.ownerDidDisconnect(self) }
        liveInbox.add { [self] in await host.ownerDidDisconnect(self) }
        liveInbox.close()
        admissionInbox.close()
    }

    // MARK: - Final pass

    public func processAudio(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let request: XPCProcessRequest
        do {
            request = try JSONDecoder().decode(XPCProcessRequest.self, from: requestData)
        } catch {
            reply(nil, error)
            return
        }

        let host = host
        // Told on the XPC queue's proxy, fire and forget, as download status is.
        let statusBox = UncheckedSendableBox(statusProxy)
        admissionInbox.add { [self] in
            guard !isClosed else {
                reply(nil, TranscriptionError.cancelled)
                return
            }
            let pass: EngineHost.FinalPass
            do {
                pass = try await host.startFinalPass(
                    micPath: request.micPath,
                    systemPath: request.systemPath,
                    customVocabulary: request.customVocabulary,
                    onModelLoad: { statusBox.value?.reportModelLoading($0) }
                )
            } catch {
                reply(nil, error)
                return
            }
            let isTracked = state.withLock { state in
                guard !state.isClosed else { return false }
                state.runningPass = pass
                return true
            }
            if !isTracked {
                pass.cancel()
            }
            // Awaited outside the inbox, so a cancel behind it can stop it.
            Task { [self] in
                defer { untrack(pass) }
                do {
                    let data = try await JSONEncoder().encode(pass.result)
                    reply(data, nil)
                } catch {
                    reply(nil, error)
                }
            }
        }
    }

    public func ensureModelsDownloaded(
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let host = host
        // Grab the client's status callback proxy now (on the XPC queue) and
        // box it so it can cross into the @Sendable Task. NSXPC proxies are
        // thread-safe; the box documents the unchecked assumption. Status
        // calls are fire-and-forget (no reply), so a dropped update is harmless.
        let statusBox = UncheckedSendableBox(statusProxy)
        Task {
            do {
                try await host.ensureModelsDownloaded { status in
                    statusBox.value?.reportDownloadStatus(status)
                }
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    public func unloadModels(reply: @escaping @Sendable () -> Void) {
        let host = host
        Task {
            await host.unloadModels()
            reply()
        }
    }

    public func healthCheck(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }

    /// A finishing live session is cut short at once, outside the inbox: a
    /// pass waiting ahead of this cancel waits for that session to end.
    public func cancelActiveWork(reply: @escaping @Sendable () -> Void) {
        let host = host
        Task { await host.cutEndingSessionShort() }
        admissionInbox.add {
            await host.cancelActiveWork()
            reply()
        }
    }

    public func waitUntilIdle(reply: @escaping @Sendable () -> Void) {
        let host = host
        Task {
            await host.waitUntilIdle()
            reply()
        }
    }

    // MARK: - Live session

    public func startLiveSession(configData: Data, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let config: LiveSessionConfig
        do {
            config = try JSONDecoder().decode(LiveSessionConfig.self, from: configData)
        } catch {
            reply(error)
            return
        }
        let host = host
        liveInbox.add { [self] in
            guard !isClosed else {
                reply(TranscriptionError.cancelled)
                return
            }
            do {
                try await host.startLiveSession(config, owner: self)
                reply(nil)
            } catch {
                Self.log.error("Live session did not start: \(error.localizedDescription, privacy: .public)")
                reply(error)
            }
        }
    }

    public func appendLiveAudio(sessionID: String, generation: Int, chunkData: Data, reply: @escaping @Sendable () -> Void) {
        let host = host
        liveInbox.add {
            if let id = UUID(uuidString: sessionID), let chunk = try? LiveAudioChunk(xpcData: chunkData) {
                await host.appendLiveAudio(sessionID: id, generation: generation, chunk: chunk)
            } else {
                Self.log.error("Dropped a live chunk that did not decode (\(chunkData.count, privacy: .public) bytes)")
            }
            reply()
        }
    }

    public func setLiveUpdateInterval(sessionID: String, seconds: Double) {
        guard let id = UUID(uuidString: sessionID) else { return }
        let host = host
        liveInbox.add { await host.setLiveUpdateInterval(sessionID: id, seconds: seconds) }
    }

    public func setLivePaused(sessionID: String, paused: Bool) {
        guard let id = UUID(uuidString: sessionID) else { return }
        let host = host
        liveInbox.add { await host.setLivePaused(sessionID: id, paused: paused) }
    }

    public func finishLiveSession(sessionID: String, timeoutSeconds: Double, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        guard let id = UUID(uuidString: sessionID) else {
            reply(Data("[]".utf8), nil)
            return
        }
        let host = host
        liveInbox.add {
            let updates = await host.finishLiveSession(sessionID: id, timeout: .seconds(timeoutSeconds))
            do {
                try reply(JSONEncoder().encode(updates), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    public func cancelLiveSession(sessionID: String, reply: @escaping @Sendable () -> Void) {
        guard let id = UUID(uuidString: sessionID) else {
            reply()
            return
        }
        // Not through the live inbox: it must reach a finish still running ahead of it.
        let host = host
        Task {
            await host.cancelLiveSession(sessionID: id)
            reply()
        }
    }

    // MARK: - LiveSessionOwner

    public func deliver(_ update: LiveTrackUpdate) {
        guard let data = try? JSONEncoder().encode(update) else {
            Self.log.error("A live update did not encode; it was not sent")
            return
        }
        statusProxy?.liveSessionDidUpdate(data)
    }

    public func sessionDidEnd(sessionID: UUID, generation: Int) {
        statusProxy?.liveSessionDidEnd(sessionID: sessionID.uuidString, generation: generation)
    }

    private var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    private func untrack(_ pass: EngineHost.FinalPass) {
        state.withLock { state in
            if state.runningPass?.id == pass.id {
                state.runningPass = nil
            }
        }
    }

    private var statusProxy: (any TranscriberStatusReporting)? {
        connection?.remoteObjectProxy as? any TranscriberStatusReporting
    }
}

// MARK: - Model preparation

public extension TranscriberService {
    /// Admitted through the admission inbox, like a final pass, so a
    /// `cancelActiveWork` sent after it always stops it. Closing the
    /// connection cancels it too.
    func prepareModels(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let request: ModelPreparationRequest
        do {
            request = try JSONDecoder().decode(ModelPreparationRequest.self, from: requestData)
        } catch {
            reply(nil, error)
            return
        }
        let host = host
        admissionInbox.add { [self] in
            guard !isClosed else {
                reply(nil, TranscriptionError.cancelled)
                return
            }
            let preparation: EngineHost.Preparation
            do {
                preparation = try await host.startPreparation(models: request.models, keepLoaded: request.keepLoaded, reloadingKept: request.reloadsKeptModel, owner: self)
            } catch {
                reply(nil, error)
                return
            }
            // The close may have come while it was admitted.
            if isClosed {
                preparation.cancel()
            }
            Task {
                let prepared = await preparation.prepared
                reply(try? JSONEncoder().encode(prepared), nil)
            }
        }
    }
}
