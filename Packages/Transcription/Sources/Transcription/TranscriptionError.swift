import Foundation

/// Errors from the Transcription processing pipeline.
/// Supersedes the experiment's `ArgMaxError` with a richer taxonomy.
public enum TranscriptionError: Error, Sendable, Equatable {
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
}
