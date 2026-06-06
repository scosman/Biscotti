import Foundation

/// Testable seam for the XPC connection layer.
///
/// The real implementation wraps `NSXPCConnection`; tests inject a mock that
/// simulates normal replies, interruptions, and unavailability without a
/// real XPC service process.
protocol TranscriberXPCConnecting: Sendable {
    /// Get a proxy object conforming to `TranscriberServiceProtocol`.
    /// Returns nil if the connection is unavailable.
    func remoteObjectProxy() -> (any TranscriberServiceProtocol)?

    /// Set a handler that fires when the XPC worker is interrupted (crash/jetsam).
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)

    /// Set a handler that fires when the XPC connection is invalidated.
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)

    /// Activate the connection (call `resume()` on `NSXPCConnection`).
    func activate()

    /// Invalidate and tear down the connection.
    func invalidate()
}

/// Production XPC connection wrapping `NSXPCConnection`.
///
/// Owns the connection lifecycle and configures the remote object interface
/// for `TranscriberServiceProtocol`.
final class TranscriberXPCConnectionImpl: TranscriberXPCConnecting, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: TranscriberServiceProtocol.self
        )
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

    func activate() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }
}
