/// A type-erased clock that wraps any `Clock` whose `Duration` is
/// Swift's `Duration`.
///
/// Used to inject `ContinuousClock` in production and `ImmediateClock`
/// in tests without making `MeetingDetector` generic over a clock type.
public struct AnyClock: Sendable {
    private let _sleep: @Sendable (Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        _sleep = { duration in
            try await clock.sleep(for: duration)
        }
    }

    /// Suspends the current task for the given duration.
    public func sleep(for duration: Duration) async throws {
        try await _sleep(duration)
    }
}
