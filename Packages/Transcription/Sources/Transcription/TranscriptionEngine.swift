/// The testable seam for transcription workers.
///
/// Both the in-process engine and the future XPC-hosted worker implement this
/// protocol. All inputs are transport-friendly (paths/strings) and the output
/// is the Codable `TranscriptResult`, so it can cross a process boundary as JSON.
public protocol TranscriptionEngine: Sendable {
    /// Download models if not already cached. Reports progress via the callback.
    ///
    /// Throws `TranscriptionError.insufficientDisk` if there is not enough space,
    /// or `TranscriptionError.downloadFailed` on network/IO errors.
    func ensureModelsDownloaded(
        progress: @Sendable (Double) -> Void
    ) async throws

    /// Process audio files and return a diarized transcript.
    ///
    /// At least one of `micPath`, `systemPath`, or `mergedPath` must be provided.
    /// When both mic and system paths are given, the engine merges them to mono
    /// 16 kHz before running STT + diarization. `mergedPath` is for re-transcription
    /// of a pre-merged file.
    ///
    /// The `config` parameter controls all behavior for this call, including model
    /// variant selection, decoding options, and diarization strategy. Implementations
    /// must use this config consistently (including for model loading/downloading)
    /// rather than mixing it with any stored default.
    ///
    /// - Throws: `TranscriptionError.invalidInput` if no paths are given or audio
    ///   files are empty/unreadable.
    func processAudio(
        micPath: String?,
        systemPath: String?,
        mergedPath: String?,
        config: ProcessorConfig,
        customVocabulary: [String]
    ) async throws -> TranscriptResult

    /// Explicitly unload all models from memory. The engine remains usable;
    /// models will be re-loaded on the next call.
    func unloadModels() async

    /// The current model lifecycle status.
    func status() async -> ModelStatus
}
