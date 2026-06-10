import Foundation

/// Testable seam for the XPC connection layer.
///
/// The real implementation wraps `NSXPCConnection`; tests inject a mock that
/// simulates normal replies, interruptions, and unavailability without a
/// real XPC service process.
protocol TranscriberXPCConnecting: AnyObject, Sendable {
    /// Get a proxy object conforming to `TranscriberServiceProtocol`.
    /// Returns nil if the connection is unavailable.
    func remoteObjectProxy() -> (any TranscriberServiceProtocol)?

    /// Set a handler that fires when the XPC worker is interrupted (crash/jetsam).
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)

    /// Set a handler that fires when the XPC connection is invalidated.
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)

    /// Set (or clear, with `nil`) the handler invoked when the worker streams
    /// model-download status messages back over the reverse XPC channel.
    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?)

    /// Activate the connection (call `resume()` on `NSXPCConnection`).
    func activate()

    /// Invalidate and tear down the connection.
    func invalidate()
}

/// The client-side object exported over XPC so the worker can push download
/// status messages back. Thread-safe: `reportDownloadStatus` is called by XPC on
/// an arbitrary queue while `setHandler` is called by the `Transcriber` actor.
final class TranscriberStatusReceiver: NSObject, TranscriberStatusReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func reportDownloadStatus(_ status: String) {
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

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.invalidationHandler = handler
    }

    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?) {
        statusReceiver.setHandler(handler)
    }

    func activate() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }
}
