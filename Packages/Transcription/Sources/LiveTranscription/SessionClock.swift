/// A clock reduced to what the session uses, so the session need not be
/// generic over its clock: tests pass a manual clock, the app a continuous one.
struct SessionClock {
    /// Time since the clock was wrapped.
    let elapsed: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: some Clock<Duration>) {
        let origin = clock.now
        elapsed = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
