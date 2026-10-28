import Foundation
import os.log

/// Testable seam for the XPC connection layer.
///
/// The real implementation wraps `NSXPCConnection`; tests inject a mock that
/// simulates normal replies, interruptions, and unavailability without a
/// real XPC service process.
protocol TranscriberXPCConnecting: AnyObject, Sendable {
    /// Get a proxy object conforming to `TranscriberServiceProtocol`.
    /// Returns nil if the connection is unavailable.
    func remoteObjectProxy() -> (any TranscriberServiceProtocol)?

    /// A proxy whose messages call `errorHandler` when the connection fails,
    /// so a message with a reply always gets either its reply or the error,
    /// once. Without it, a reply lost to a crash or an invalidation is never
    /// called and its caller waits forever.
    func remoteObjectProxy(errorHandler: @escaping @Sendable (any Error) -> Void) -> (any TranscriberServiceProtocol)?

    /// Set a handler that fires when the XPC worker is interrupted (crash/jetsam).
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)

    /// Set a handler that fires when the XPC connection is invalidated.
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)

    /// Set (or clear, with `nil`) the handler invoked when the worker streams
    /// model-download status messages back over the reverse XPC channel.
    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?)

    /// Where the worker's live updates go: the current live session's stream.
    func setLiveUpdateRoute(_ route: LiveUpdateRoute)

    /// Set the handler told when a final pass starts or ends a model load.
    func setModelLoadHandler(_ handler: @escaping @Sendable (Bool) -> Void)

    /// Activate the connection (call `resume()` on `NSXPCConnection`).
    func activate()

    /// Invalidate and tear down the connection.
    func invalidate()
}

/// The client-side object exported over XPC so the worker can push download
/// status messages and live updates back. Thread-safe: XPC calls it on an
/// arbitrary queue while the `Transcriber` actor sets its handlers.
final class TranscriberStatusReceiver: NSObject, TranscriberStatusReporting, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "Transcriber"
    )

    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var liveRoute: LiveUpdateRoute?
    private var modelLoadHandler: (@Sendable (Bool) -> Void)?

    func setModelLoadHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        modelLoadHandler = handler
        lock.unlock()
    }

    func reportModelLoading(_ isLoading: Bool) {
        lock.lock()
        let handler = modelLoadHandler
        lock.unlock()
        handler?(isLoading)
    }

    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setLiveRoute(_ route: LiveUpdateRoute) {
        lock.lock()
        liveRoute = route
        lock.unlock()
    }

    func liveSessionDidUpdate(_ updateData: Data) {
        currentLiveRoute()?.deliver(updateData)
    }

    func liveSessionDidEnd(sessionID: String, generation: Int) {
        guard let id = UUID(uuidString: sessionID) else { return }
        currentLiveRoute()?.end(sessionID: id, generation: generation)
    }

    private func currentLiveRoute() -> LiveUpdateRoute? {
        lock.lock()
        defer { lock.unlock() }
        return liveRoute
    }

    func reportDownloadStatus(_ status: String) {
        Self.log.debug("client: received download status callback: \(status)")
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(status)
    }
}

/// Production XPC connection wrapping `NSXPCConnection`.
///
/// Owns the connection lifecycle and configures the remote object interface
/// for `TranscriberServiceProtocol`.
final class TranscriberXPCConnectionImpl: TranscriberXPCConnecting, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let statusReceiver = TranscriberStatusReceiver()

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: TranscriberServiceProtocol.self
        )
        // Export the status receiver so the worker can call back into us
        // during downloads (the reverse XPC channel).
        connection.exportedInterface = NSXPCInterface(
            with: TranscriberStatusReporting.self
        )
        connection.exportedObject = statusReceiver
    }

    func remoteObjectProxy() -> (any TranscriberServiceProtocol)? {
        connection.remoteObjectProxy as? any TranscriberServiceProtocol
    }

    func remoteObjectProxy(errorHandler: @escaping @Sendable (any Error) -> Void) -> (any TranscriberServiceProtocol)? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? any TranscriberServiceProtocol
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.invalidationHandler = handler
    }

    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?) {
        statusReceiver.setHandler(handler)
    }

    func setLiveUpdateRoute(_ route: LiveUpdateRoute) {
        statusReceiver.setLiveRoute(route)
    }

    func setModelLoadHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        statusReceiver.setModelLoadHandler(handler)
    }

    func activate() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }
}
