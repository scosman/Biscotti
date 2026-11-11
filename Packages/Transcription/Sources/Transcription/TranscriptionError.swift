import Foundation

/// Errors from the Transcription processing pipeline.
/// Supersedes the experiment's `ArgMaxError` with a richer taxonomy.
///
/// `Codable` so the XPC worker can send the full error (including its detail
/// string) to the client; see ``TranscriptionNSErrorBridge``.
public enum TranscriptionError: Error, LocalizedError, Codable, Sendable, Equatable {
    /// Models are not downloaded yet; call `ensureModelsDownloaded` first.
    case needsDownload

    /// Insufficient disk space for model download/compilation.
    case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)

    /// Model download failed (network error, repo unavailable, etc.).
    case downloadFailed(String)

    /// WhisperKit or SpeakerKit model loading/initialization failed.
    case modelLoadFailed(String)

    /// The XPC worker process is not available (not installed, not responding).
    case workerUnavailable

    /// The XPC worker was interrupted (jetsam, crash). Retriable -- the next call
    /// auto-relaunches the worker via launchd.
    case workerInterrupted

    /// Invalid input (missing files, unreadable audio, zero-length, etc.).
    case invalidInput(String)

    /// WhisperKit transcription returned an error.
    case transcriptionFailed(String)

    /// SpeakerKit diarization returned an error.
    case diarizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .needsDownload:
            "Transcription models are not downloaded"
        case let .insufficientDisk(requiredBytes, availableBytes):
            "Insufficient disk space: need \(requiredBytes) bytes, have \(availableBytes) bytes"
        case let .downloadFailed(detail):
            "Model download failed: \(detail)"
        case let .modelLoadFailed(detail):
            "Model load failed: \(detail)"
        case .workerUnavailable:
            "Transcription worker is not available"
        case .workerInterrupted:
            "Transcription worker was interrupted (crashed or exited unexpectedly)"
        case let .invalidInput(detail):
            "Invalid input: \(detail)"
        case let .transcriptionFailed(detail):
            "Transcription failed: \(detail)"
        case let .diarizationFailed(detail):
            "Speaker diarization failed: \(detail)"
        }
    }
}
