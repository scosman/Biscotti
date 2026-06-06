import Foundation
import Synchronization
@testable import AudioCapture

/// A fake `DeviceChangeProvider` that lets tests push synthetic events
/// via a continuation.
final class FakeDeviceChangeProvider: DeviceChangeProvider, @unchecked Sendable {
    private let state = Mutex<AsyncStream<DeviceChangeEvent>.Continuation?>(nil)

    /// Signals when the continuation is ready (stream has been consumed).
    private let readySignal = Atomic<Bool>(false)

    /// Call this to inject a device-change event into the stream.
    func send(_ event: DeviceChangeEvent) {
        let cont = state.withLock { $0 }
        cont?.yield(event)
    }

    /// Finish the stream (e.g. in teardown).
    func finish() {
        let cont = state.withLock { current -> AsyncStream<DeviceChangeEvent>.Continuation? in
            let result = current
            current = nil
            return result
        }
        cont?.finish()
    }

    /// Wait until the stream has been consumed and the continuation is ready.
    func waitUntilReady(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !readySignal.load(ordering: .acquiring) {
            guard ContinuousClock.now < deadline else {
                throw FakeProviderError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func deviceChanges() -> AsyncStream<DeviceChangeEvent> {
        AsyncStream { continuation in
            self.state.withLock { $0 = continuation }
            self.readySignal.store(true, ordering: .releasing)
        }
    }

    enum FakeProviderError: Error {
        case timeout
    }
}
