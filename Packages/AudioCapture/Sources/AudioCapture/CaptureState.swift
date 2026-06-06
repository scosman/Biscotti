import Foundation

/// Observable snapshot of an active capture session.
///
/// Emitted periodically via `AudioRecorder.stateStream()`.
/// `micLevel` and `systemLevel` are RMS values in 0...1, but are
/// **unwired** by default (always 0) per phase 9 validation findings.
public struct CaptureState: Sendable, Equatable {
    public let isRecording: Bool
    public let elapsed: TimeInterval
    /// RMS level 0...1 for the mic stream. Unwired; always 0.
    public let micLevel: Float
    /// RMS level 0...1 for the system audio stream. Unwired; always 0.
    public let systemLevel: Float
    /// Shared `CACurrentMediaTime()` reference captured at start.
    public let startTimestamp: Double

    public init(
        isRecording: Bool,
        elapsed: TimeInterval,
        micLevel: Float,
        systemLevel: Float,
        startTimestamp: Double
    ) {
        self.isRecording = isRecording
        self.elapsed = elapsed
        self.micLevel = micLevel
        self.systemLevel = systemLevel
        self.startTimestamp = startTimestamp
    }

    /// The resting state before any capture has started.
    public static let idle = CaptureState(
        isRecording: false,
        elapsed: 0,
        micLevel: 0,
        systemLevel: 0,
        startTimestamp: 0
    )
}
