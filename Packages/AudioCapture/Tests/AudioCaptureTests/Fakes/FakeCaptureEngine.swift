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
    }

    private let state = Mutex(State())

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

    func start(writingTo url: URL) async throws {
        let error = state.withLock { locked -> (any Error)? in
            locked.startCount += 1
            locked.lastURL = url
            return locked.startError
        }

        if let error {
            throw error
        }
    }

    func stop() async {
        state.withLock { $0.stopCount += 1 }
    }

    func reconnect() async throws {
        state.withLock { $0.reconnectCount += 1 }
    }
}
