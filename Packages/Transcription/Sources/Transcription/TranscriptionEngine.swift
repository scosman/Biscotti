/// The testable seam for transcription workers.
///
/// Both the in-process engine and the future XPC-hosted worker implement this
/// protocol. All inputs are transport-friendly (paths/strings) and the output
/// is the Codable `TranscriptResult`, so it can cross a process boundary as JSON.
public protocol TranscriptionEngine: Sendable {
    /// Download models if not already cached.
    ///
    /// The `status` callback receives a human-readable message for each download
    /// stage (e.g. "Downloading speech-to-text model"). There is no numeric
    /// percentage: the underlying SDK only exposes file-count-weighted progress,
    /// which is misleading for a repo with one multi-GB file among small ones.
    ///
    /// - Parameters:
    ///   - components: Which model components to download. Defaults to all.
    ///   - status: Status callback for download stages.
    /// - Throws: `TranscriptionError.insufficientDisk` or `.downloadFailed`.
    func ensureModelsDownloaded(
        components: Set<ModelComponent>,
        status: @escaping @Sendable (String) -> Void
    ) async throws

    /// Process audio files and return a diarized transcript.
    ///
    /// Both `micPath` and `systemPath` are required — the engine merges them
    /// to mono 16 kHz in memory before running STT + diarization.
    ///
    /// - Parameters:
    ///   - micPath: Path to the mic audio file.
    ///   - systemPath: Path to the system audio file.
    ///   - customVocabulary: Custom vocabulary terms for biasing (Whisper only).
    ///   - config: Per-call engine and locale. The engine's default when nil.
    /// - Throws: `TranscriptionError.invalidInput` if audio files are
    ///   empty/unreadable.
    func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        config: TranscriptionConfig
    ) async throws -> TranscriptResult

    /// Explicitly unload all models from memory. The engine remains usable;
    /// models will be re-loaded on the next call.
    func unloadModels() async

    /// Returns `true` when the requested model components are present on disk
    /// and do NOT need to be downloaded.
    ///
    /// This is a **read-only** probe -- it must not download, load, or
    /// otherwise mutate model state.
    func modelsPresent(components: Set<ModelComponent>) async -> Bool

    /// Delete specific model components from disk.
    ///
    /// Unloads first so the worker releases files, then removes the component
    /// directories. Apple assets are system-managed and cannot be deleted here.
    func deleteModels(_ components: Set<ModelComponent>) async throws

    /// The current model lifecycle status.
    func status() async -> ModelStatus
}
