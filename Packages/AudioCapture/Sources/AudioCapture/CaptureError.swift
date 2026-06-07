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

    /// Mic permission was denied or restricted.
    case micPermissionDenied
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
        case .probablePermissionDenied:
            "System audio appears blocked (all-zero buffers) — grant Screen & System Audio Recording in Settings."
        case .micPermissionDenied:
            "Microphone permission denied or restricted."
        }
    }
}
