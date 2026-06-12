import AudioCapture

/// Seam over `AudioCapture.AudioActivityMonitor` that provides a stream
/// of audio-process snapshots.
///
/// Production code uses `LiveActivitySource`; tests inject a fake that
/// yields scripted snapshots on demand.
public protocol ActivitySource: Sendable {
    /// Returns an async stream of audio-process snapshots. Each element is
    /// the complete set of currently-active audio processes.
    func activityStream() -> AsyncStream<[AudioProcess]>
}
