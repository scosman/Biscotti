import Foundation

/// Per-meeting transcription job status for the UI.
///
/// The service updates this as the job progresses through model download,
/// transcription, and completion (or failure).
public enum JobStatus: Sendable, Equatable {
    /// No job running for this meeting.
    case idle

    /// Waiting for another transcription to finish. Set by `AppCore`'s
    /// transcription queue (the service itself runs one job at a time and
    /// never sets this); replaced by `.transcribing` when the turn comes, or
    /// by `.cancelled` if the user dequeues it.
    case queued

    /// The engine is downloading or preparing models. The `message` comes
    /// from the engine's status callback (e.g. "Downloading speech-to-text model").
    case downloadingModel(message: String)

    /// STT + diarization is in progress.
    case transcribing

    /// The transcript was produced, persisted, and promoted.
    case completed

    /// The user cancelled the job. Terminal, like `.failed`: no transcript
    /// was saved, and the meeting can be transcribed again.
    case cancelled

    /// The job failed. If `retriable` is true, the user can tap Retry
    /// (e.g. worker crash, download failure). Non-retriable failures are
    /// permanent for the current audio (e.g. invalid input, diarization error).
    case failed(message: String, retriable: Bool)
}
