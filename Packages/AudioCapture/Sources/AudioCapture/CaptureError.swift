import Foundation

/// Errors that can occur during audio capture operations.
public enum CaptureError: Error, Sendable, Equatable {
    /// Core Audio process tap could not be created.
    case tapCreationFailed(OSStatus)

    /// Aggregate device creation failed (needed for system audio capture).
    case aggregateDeviceFailed(OSStatus)

    /// AVAudioEngine mic capture setup or runtime failure.
    case micEngineFailed(String)

    /// System audio buffers were all-zero in the first ~2 seconds,
    /// indicating a probable missing screen-recording permission grant.
    case probablePermissionDenied

    /// The tone-probe infrastructure failed (output engine or format).
    case probeFailed(String)

    /// Mic permission was denied or restricted.
    case micPermissionDenied

    /// `start()` was called on a recorder that has already completed a
    /// recording. `AudioRecorder` is single-use: construct a fresh one for
    /// each recording. Reusing an instance across recordings is unsupported —
    /// the capture engines hoist per-session state and were validated
    /// single-use, so reuse is rejected rather than left as a latent
    /// real-time-thread teardown hazard.
    case recorderConsumed
}

extension CaptureError: LocalizedError {
    /// Human-readable reason. Without this, the bridged `NSError` only exposes
    /// the case index (e.g. "CaptureError error 2"), hiding the OSStatus /
    /// converter / format details carried in the associated values.
    public var errorDescription: String? {
        switch self {
        case let .tapCreationFailed(status):
            "System audio tap creation failed (OSStatus \(status))"
        case let .aggregateDeviceFailed(status):
            "Aggregate device creation failed (OSStatus \(status))"
        case let .micEngineFailed(message):
            "Mic engine failed: \(message)"
        case let .probeFailed(message):
            "Probe tone failed: \(message)"
        case .probablePermissionDenied:
            "System audio appears blocked (all-zero buffers) — grant Screen & System Audio Recording in Settings."
        case .micPermissionDenied:
            "Microphone permission denied or restricted."
        case .recorderConsumed:
            "This recorder has already been used — create a new AudioRecorder for each recording."
        }
    }
}
