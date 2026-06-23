import Foundation
import os

/// Client-side object exported over XPC so the service can push streaming
/// events back during `generateStreaming`.
///
/// `public` because `NSXPCConnection.exportedObject` requires the exported
/// class and its `@objc` protocol-conformance methods to be publicly visible
/// from the module boundary. Internal surface is limited to `setHandlers` and
/// `clearHandlers`, called only by `XPCBackend`.
///
/// Thread-safe: XPC delivers callbacks on an arbitrary queue while the
/// `XPCBackend` sets/clears handlers from its own context. A lock guards all
/// handler access. When handlers are cleared (at stream terminal or
/// cancellation), late callbacks from the service are silently dropped.
public final class LLMEventReceiver: NSObject, LLMEventReporting, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "LLMEventReceiver"
    )

    private let lock = NSLock()
    private var onToken: (@Sendable (String) -> Void)?
    private var onReasoningToken: (@Sendable (String) -> Void)?
    private var onDone: (@Sendable (Data) -> Void)?
    private var onError: (@Sendable (Data) -> Void)?

    /// Install the handler closures for a single streaming request.
    ///
    /// Must be called before the XPC `generateStreaming` call so the service's
    /// callbacks have somewhere to land. Replaces any previously-set handlers.
    func setHandlers(
        onToken: @escaping @Sendable (String) -> Void,
        onReasoningToken: @escaping @Sendable (String) -> Void,
        onDone: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Data) -> Void
    ) {
        lock.lock()
        self.onToken = onToken
        self.onReasoningToken = onReasoningToken
        self.onDone = onDone
        self.onError = onError
        lock.unlock()
    }

    /// Detach all handlers so late/stale callbacks are dropped.
    ///
    /// Called at stream terminal (done/error) and on consumer cancellation.
    func clearHandlers() {
        lock.lock()
        onToken = nil
        onReasoningToken = nil
        onDone = nil
        onError = nil
        lock.unlock()
    }

    // MARK: - LLMEventReporting (called by the service over XPC)

    public func reportToken(_ piece: String) {
        lock.lock()
        let handler = onToken
        lock.unlock()
        if let handler {
            handler(piece)
        } else {
            Self.log.debug("Dropped late token callback (handlers cleared)")
        }
    }

    public func reportReasoningToken(_ piece: String) {
        lock.lock()
        let handler = onReasoningToken
        lock.unlock()
        if let handler {
            handler(piece)
        } else {
            Self.log.debug("Dropped late reasoning token callback (handlers cleared)")
        }
    }

    public func reportDone(resultData: Data) {
        lock.lock()
        let handler = onDone
        lock.unlock()
        if let handler {
            handler(resultData)
        } else {
            Self.log.debug("Dropped late done callback (handlers cleared)")
        }
    }

    public func reportError(errorData: Data) {
        lock.lock()
        let handler = onError
        lock.unlock()
        if let handler {
            handler(errorData)
        } else {
            Self.log.debug("Dropped late error callback (handlers cleared)")
        }
    }
}
