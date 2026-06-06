import Foundation

/// The `@objc` XPC protocol for the transcription worker service.
///
/// All parameters and return values are `@objc`-compatible Foundation types.
/// `TranscriptResult` crosses the boundary as JSON-encoded `Data` (per research section 7).
/// `ProcessorConfig` is likewise JSON-encoded into `Data` for transport.
///
/// The **real** XPC service bundle that conforms to this protocol is built in Stage 4
/// (Phase 4.3). This phase defines the protocol and the client-side adapter.
@objc public protocol TranscriberServiceProtocol {
    /// Process audio files and return a diarized transcript.
    ///
    /// Audio paths, config, and vocabulary are bundled into a single
    /// JSON-encoded `Data` parameter (`requestData`) to keep the `@objc`
    /// parameter count manageable. The request shape is defined by
    /// `XPCProcessRequest` (internal to the Transcription package).
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `XPCProcessRequest` containing audio
    ///     paths, config, and custom vocabulary.
    ///   - reply: Callback with JSON-encoded `TranscriptResult` data or an error.
    func processAudio(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    )

    /// Download models if not already cached.
    ///
    /// - Parameters:
    ///   - configData: JSON-encoded `ProcessorConfig` (for model variant selection).
    ///   - reply: Callback with nil on success, or an error on failure.
    func ensureModelsDownloaded(
        configData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    )

    /// Explicitly unload all models from memory.
    func unloadModels(
        reply: @escaping @Sendable () -> Void
    )

    /// Check if the worker is responsive.
    func healthCheck(
        reply: @escaping @Sendable (Bool) -> Void
    )
}
