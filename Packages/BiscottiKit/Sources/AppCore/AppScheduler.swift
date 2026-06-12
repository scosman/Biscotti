import Foundation

/// Abstraction over timed work (sleep, scheduled fire). The live
/// implementation uses `Task.sleep` with `ContinuousClock`; tests inject a
/// controllable clock for deterministic timer assertions.
public protocol AppScheduler: Sendable {
    /// Sleeps for the given duration. Throws `CancellationError` if the
    /// task is cancelled.
    func sleep(for duration: Duration) async throws

    /// Returns the current instant (for computing relative offsets).
    func now() -> ContinuousClock.Instant
}

/// Production scheduler that delegates to `ContinuousClock`.
public struct LiveAppScheduler: AppScheduler, Sendable {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }

    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }
}
