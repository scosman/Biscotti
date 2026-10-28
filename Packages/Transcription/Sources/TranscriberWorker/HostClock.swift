import Synchronization

/// A clock reduced to what the worker's timers use, so tests can pass a
/// manual clock without making every type generic over it.
struct HostClock {
    /// Time since the clock was wrapped.
    let elapsed: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: some Clock<Duration>) {
        let origin = clock.now
        elapsed = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }
}

extension HostClock {
    /// Runs `operation` and returns whether it finished within `limit`. An
    /// operation that runs late is left running; nothing waits for it.
    func finishes(within limit: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        let sleep = sleep
        return await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            let timer = Task {
                do { try await sleep(limit) } catch { return }
                first.resume(false)
            }
            Task {
                await operation()
                first.resume(true)
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation with whichever result comes first.
private final class FirstResult: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
