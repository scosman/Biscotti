/// Rich status for model lifecycle, suitable for driving UI state.
public enum ModelStatus: Sendable, Equatable {
    /// Models are not downloaded yet.
    case needsDownload

    /// Models are being downloaded. Progress is 0.0...1.0.
    case downloading(progress: Double)

    /// CoreML first-compile is in progress (typically 15-90 seconds).
    case compiling

    /// Models are being loaded into memory.
    case loading

    /// Models are loaded and idle, ready for a transcription job.
    case ready

    /// A transcription job is currently in flight.
    case running

    /// An error occurred during the model lifecycle.
    case error(TranscriptionError)
}
