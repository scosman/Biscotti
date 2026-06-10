import Foundation
import os.log
import Transcription

private let hostLog = Logger(
    subsystem: "net.scosman.biscotti",
    category: "TranscriberXPCHost"
)

// MARK: - Sendable box

/// Wraps a non-`Sendable` value so it can cross into a `@Sendable` closure.
/// Used here for the NSXPC remote-object proxy, which is thread-safe at runtime
/// but not statically `Sendable`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Exported object

/// The exported object vended to XPC clients. Bridges the `@objc`
/// reply-handler protocol to the async `InProcessTranscriptionEngine`.
///
/// Thread-safety: the only mutable state is `engine`, which is an actor.
/// All access goes through `await`, so `@unchecked Sendable` is safe.
final class TranscriberService: NSObject, TranscriberServiceProtocol, @unchecked Sendable {
    private let engine = InProcessTranscriptionEngine()

    /// The owning connection, used to reach the client's status callback.
    /// Weak to avoid a retain cycle (the connection retains this exported
    /// object). If the connection is torn down mid-download the proxy obtained
    /// from it simply drops further fire-and-forget status messages — there is
    /// no use-after-free, since NSXPC proxies tolerate a dead connection.
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection?) {
        self.connection = connection
        super.init()
    }

    func processAudio(
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

        let engine = engine
        Task {
            do {
                let result = try await engine.processAudio(
                    micPath: request.micPath,
                    systemPath: request.systemPath,
                    customVocabulary: request.customVocabulary
                )
                let data = try JSONEncoder().encode(result)
                reply(data, nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func ensureModelsDownloaded(
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let engine = engine
        // Grab the client's status callback proxy now (on the XPC queue) and
        // box it so it can cross into the @Sendable Task. NSXPC proxies are
        // thread-safe; the box documents the unchecked assumption. Status
        // calls are fire-and-forget (no reply), so a dropped update is harmless.
        let statusBox = UncheckedSendableBox(
            connection?.remoteObjectProxy as? TranscriberStatusReporting
        )
        Task {
            do {
                try await engine.ensureModelsDownloaded { status in
                    statusBox.value?.reportDownloadStatus(status)
                }
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    func unloadModels(reply: @escaping @Sendable () -> Void) {
        let engine = engine
        Task {
            await engine.unloadModels()
            reply()
        }
    }

    func healthCheck(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}

// MARK: - Active connection tracking

/// Thread-safe counter of active XPC connections. When the count drops to
/// zero the process exits, releasing multi-GB model memory immediately
/// instead of waiting for `NSXPCListener.service()`'s idle-exit heuristic
/// (which never fires while CoreML/Metal run-loop sources are alive).
private final class ConnectionCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Decrements the counter and returns `true` when it reaches zero.
    func decrementAndCheckZero() -> Bool {
        lock.lock()
        count -= 1
        let isZero = count == 0
        lock.unlock()
        return isZero
    }
}

private let connectionCounter = ConnectionCounter()

// MARK: - Listener delegate

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        connectionCounter.increment()
        hostLog.info("Accepted new XPC connection pid=\(pid)")
        connection.exportedInterface = NSXPCInterface(
            with: TranscriberServiceProtocol.self
        )
        // The client exports a status receiver; declare its interface so we
        // can obtain a proxy to push download status back during downloads.
        connection.remoteObjectInterface = NSXPCInterface(
            with: TranscriberStatusReporting.self
        )
        connection.exportedObject = TranscriberService(connection: connection)

        // Interruption fires on worker crash/jetsam. Log only — do NOT
        // decrement here. NSXPCConnection guarantees the invalidation
        // handler fires eventually (including after interruption), so
        // decrementing only in invalidationHandler avoids double-count.
        connection.interruptionHandler = {
            hostLog.info("Service-side connection interrupted pid=\(pid)")
        }

        // Invalidation fires exactly once per connection, whether the
        // client called invalidate(), the connection was interrupted,
        // or the process is shutting down. Decrement here and exit
        // when no connections remain.
        connection.invalidationHandler = {
            hostLog.info("Service-side connection invalidated pid=\(pid)")
            if connectionCounter.decrementAndCheckZero() {
                hostLog.info("XPC host exiting pid=\(pid) (no active connections)")
                // _exit(0) skips atexit/global destructors — CoreML/Metal/WhisperKit
                // teardown can block or deadlock, defeating the exit guarantee.
                // Race safety: the client-side inFlightMeetingID guard prevents
                // concurrent re-trigger; a lost in-flight connection surfaces as
                // a retriable workerInterrupted/workerUnavailable (launchd relaunches).
                _exit(0)
            }
        }

        connection.resume()
        return true
    }
}

// MARK: - Entry point

hostLog.info(
    "XPC host process started pid=\(ProcessInfo.processInfo.processIdentifier)"
)

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

hostLog.info("Listener resumed pid=\(ProcessInfo.processInfo.processIdentifier)")
