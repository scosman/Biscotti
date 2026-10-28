import Foundation
import os.log
import TranscriberWorker
import Transcription

private let hostLog = Logger(
    subsystem: "net.scosman.biscotti",
    category: "TranscriberXPCHost"
)

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

/// Every connection's service shares the process's one host. A live decode
/// stuck past `LiveWorkerLimits.stuckDecode` ends the process (exit code 70,
/// EX_SOFTWARE): the model it holds must not be unloaded under it, and the
/// app's connections, interrupted, start a fresh worker.
private let engineHost = EngineHost.workerProcessHost(onStuckDecode: {
    hostLog.fault("A live decode is stuck; ending the worker process")
    _exit(70)
})

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
        let service = TranscriberService(connection: connection, host: engineHost)
        connection.exportedObject = service

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
            // A live session this connection started must not outlive it,
            // or the host would stay busy for every other connection.
            service.connectionDidClose()
            if connectionCounter.decrementAndCheckZero() {
                hostLog.info("XPC host exiting pid=\(pid) (no active connections)")
                // _exit(0) skips atexit/global destructors — CoreML/Metal/WhisperKit
                // teardown can block or deadlock, defeating the exit guarantee.
                // Race safety: the client-side job queue runs one pass at a time, so it
                // does not re-trigger concurrently; a lost in-flight connection surfaces as
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
