import Foundation

/// A counting semaphore for async/await with FIFO waiter ordering.
///
/// Used by `LLMConnection` as a serial gate (`value: 1`) so concurrent
/// `generate`/`generateStreaming` calls execute one at a time in submission order.
///
/// Implementation: an `NSLock`-guarded counter + FIFO queue of
/// `CheckedContinuation`s. `@unchecked Sendable` because the lock protects all
/// mutable state (same pattern as the existing `InterruptedFlag`).
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Create a semaphore with the given initial count.
    init(value: Int) {
        precondition(value >= 0, "Semaphore value must be non-negative")
        self.value = value
    }

    /// Wait (decrement). Suspends if the count is zero; resumes in FIFO order
    /// when another caller signals.
    func wait() async {
        let shouldSuspend: Bool = lock.withLock {
            if value > 0 {
                value -= 1
                return false
            }
            return true
        }

        if shouldSuspend {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    // Double-check: a signal may have arrived between the
                    // outer check and reaching this continuation.
                    if value > 0 {
                        value -= 1
                        cont.resume()
                    } else {
                        waiters.append(cont)
                    }
                }
            }
        }
    }

    /// Signal (increment). Resumes the oldest waiter if any are queued.
    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                value += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
}
