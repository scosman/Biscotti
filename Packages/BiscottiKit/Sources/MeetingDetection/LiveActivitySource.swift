import AudioCapture

/// Production `ActivitySource` wrapping `AudioActivityMonitor.live()`.
///
/// The monitor is an actor, so `activityStream()` requires `await`.
/// This adapter bridges the async actor call into a synchronous
/// `AsyncStream` return by spawning a relay task internally.
public struct LiveActivitySource: ActivitySource, Sendable {
    public init() {}

    public func activityStream() -> AsyncStream<[AudioProcess]> {
        AsyncStream { continuation in
            let task = Task {
                let monitor = AudioActivityMonitor.live()
                let stream = await monitor.activityStream()
                for await snapshot in stream {
                    guard !Task.isCancelled else { break }
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
