import Foundation
import Synchronization
@testable import AudioCapture

/// A fake `CaptureEngine` that records start/stop/reconnect calls for assertions.
///
/// Uses `Mutex` for state so it's safe from both sync and async contexts.
final class FakeCaptureEngine: CaptureEngine, @unchecked Sendable {
    struct State {
        var startCount = 0
        var stopCount = 0
        var reconnectCount = 0
        var lastURL: URL?
        var startError: (any Error)?
        var micAnchor: Double = 0
        /// Anchor value the fake fires via `onFirstBuffer` on start. Set
        /// via `setFirstBufferAnchor(_:)` before calling start. Default 0.
        var firstBufferAnchor: Double = 0
    }

    private let state = Mutex(State())

    /// Callback fired once when the engine delivers its first buffer.
    /// For fakes used as the mic engine in tests, setting this and then
    /// calling `simulateFirstBuffer(anchor:)` exercises the alignment path.
    private var onFirstBuffer: (@Sendable (Double) -> Void)?

    func setOnFirstBuffer(_ callback: (@Sendable (Double) -> Void)?) {
        onFirstBuffer = callback
    }

    /// The mic anchor passed via `setMicAnchor(_:)`.
    var micAnchor: Double {
        state.withLock { $0.micAnchor }
    }

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    var reconnectCount: Int {
        state.withLock { $0.reconnectCount }
    }

    var lastURL: URL? {
        state.withLock { $0.lastURL }
    }

    /// Set to make the next `start()` throw.
    func setStartError(_ error: (any Error)?) {
        state.withLock { $0.startError = error }
    }

    /// Set the anchor value fired via `onFirstBuffer` when start is called.
    func setFirstBufferAnchor(_ anchor: Double) {
        state.withLock { $0.firstBufferAnchor = anchor }
    }

    /// Simulate the mic engine delivering its first buffer. Fires
    /// `onFirstBuffer` with the given anchor, just like the real mic engine.
    func simulateFirstBuffer(anchor: Double) {
        onFirstBuffer?(anchor)
    }

    func setMicAnchor(_ seconds: Double) {
        state.withLock { $0.micAnchor = seconds }
    }

    func start(writingTo url: URL) async throws {
        let (error, anchor) = state.withLock { locked -> ((any Error)?, Double) in
            locked.startCount += 1
            locked.lastURL = url
            return (locked.startError, locked.firstBufferAnchor)
        }

        if let error {
            throw error
        }

        // For a fake mic engine: auto-fire the first-buffer callback so
        // AudioRecorder's startMicAndWaitForAnchor completes without a
        // timeout. Real engines fire this from the actual audio tap.
        let callback = onFirstBuffer
        callback?(anchor)
    }

    func stop() async {
        state.withLock { $0.stopCount += 1 }
    }

    func reconnect() async throws {
        state.withLock { $0.reconnectCount += 1 }
    }
}
