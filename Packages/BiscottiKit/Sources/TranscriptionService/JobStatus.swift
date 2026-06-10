import Foundation

/// Per-meeting transcription job status for the UI.
///
/// The service updates this as the job progresses through model download,
/// transcription, and completion (or failure).
public enum JobStatus: Sendable, Equatable {
    /// No job running for this meeting.
    case idle

    /// The engine is downloading or preparing models. The `message` comes
    /// from the engine's status callback (e.g. "Downloading speech-to-text model").
    case downloadingModel(message: String)

    /// STT + diarization is in progress.
    case transcribing

    /// The transcript was produced, persisted, and promoted.
    case completed

    /// The job failed. If `retriable` is true, the user can tap Retry
    /// (e.g. worker crash, download failure). Non-retriable failures are
    /// permanent for the current audio (e.g. invalid input, diarization error).
    case failed(message: String, retriable: Bool)
}
