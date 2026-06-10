import CoreAudio
import Foundation
import Synchronization
@testable import AudioCapture

/// A fake `ProcessActivitySource` that lets tests control the process list
/// and push synthetic change notifications.
final class FakeProcessActivitySource: ProcessActivitySource, @unchecked Sendable {
    private struct State {
        var processes: [AudioProcess] = []
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let state = Mutex<State>(State())

    /// Signals when the continuation is ready (stream has been consumed).
    private let readySignal = Atomic<Bool>(false)

    /// Sets the process list that `currentProcesses()` will return.
    func setProcesses(_ processes: [AudioProcess]) {
        state.withLock { $0.processes = processes }
    }

    /// Pushes a change notification into the stream.
    /// Typically called after `setProcesses` to simulate a Core Audio event.
    func sendChange() {
        let cont = state.withLock { $0.continuation }
        cont?.yield()
    }

    /// Finishes the change stream (e.g. in teardown).
    func finish() {
        let cont = state.withLock { state -> AsyncStream<Void>.Continuation? in
            let result = state.continuation
            state.continuation = nil
            return result
        }
        cont?.finish()
    }

    /// Waits until the stream has been consumed and the continuation is ready.
    func waitUntilReady(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !readySignal.load(ordering: .acquiring) {
            guard ContinuousClock.now < deadline else {
                throw FakeProviderError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - ProcessActivitySource

    func currentProcesses() -> [AudioProcess] {
        state.withLock { $0.processes }
    }

    func processChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.state.withLock { $0.continuation = continuation }
            self.readySignal.store(true, ordering: .releasing)
        }
    }

    enum FakeProviderError: Error {
        case timeout
    }
}
