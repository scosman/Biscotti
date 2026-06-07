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
