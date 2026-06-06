import Foundation

/// Errors that can occur during audio capture operations.
public enum CaptureError: Error, Sendable {
    /// Core Audio process tap could not be created.
    case tapCreationFailed(OSStatus)

    /// Aggregate device creation failed (needed for system audio capture).
    case aggregateDeviceFailed(OSStatus)

    /// AVAudioEngine mic capture setup or runtime failure.
    case micEngineFailed(String)

    /// CAF-to-M4A conversion failed after recording stopped.
    /// The original CAF file is retained so audio is never lost.
    case conversionFailed(String)

    /// One or both CAF-to-M4A encodes failed after recording stopped.
    /// The `result` contains whichever URLs succeeded (if any), so
    /// callers can recover the successful output. The original CAF
    /// files are always retained.
    case partialEncodeFailed(result: EncodeResult, underlying: any Error)

    /// System audio buffers were all-zero in the first ~2 seconds,
    /// indicating a probable missing screen-recording permission grant.
    case probablePermissionDenied
}

/// The outcome of encoding both CAF streams to M4A after a recording stops.
///
/// On full success, both `mic` and `system` are non-nil.
/// On partial failure, whichever succeeded is non-nil and the
/// corresponding error is nil; the failed stream's error is set.
/// The original CAF files are always retained regardless.
public struct EncodeResult: Sendable {
    /// URL of the encoded mic M4A, or `nil` if encoding failed.
    public let mic: URL?
    /// URL of the encoded system M4A, or `nil` if encoding failed.
    public let system: URL?
    /// The mic encode error, if any.
    public let micError: (any Error)?
    /// The system encode error, if any.
    public let systemError: (any Error)?

    public init(
        mic: URL?,
        system: URL?,
        micError: (any Error)?,
        systemError: (any Error)?
    ) {
        self.mic = mic
        self.system = system
        self.micError = micError
        self.systemError = systemError
    }

    /// `true` if both streams encoded successfully.
    public var isFullSuccess: Bool {
        mic != nil && system != nil
    }
}
