import Foundation

/// The `@objc` XPC protocol for the transcription worker service.
///
/// All parameters and return values are `@objc`-compatible Foundation types.
/// `TranscriptResult` crosses the boundary as JSON-encoded `Data` (per research section 7).
///
/// `BiscottiTranscriber.xpc` conforms to it through `TranscriberWorker`'s
/// `TranscriberService`, which hands every call to the process's `EngineHost`.
@objc public protocol TranscriberServiceProtocol {
    /// Process audio files and return a diarized transcript.
    ///
    /// Audio paths and vocabulary are bundled into a single
    /// JSON-encoded `Data` parameter (`requestData`) to keep the `@objc`
    /// parameter count manageable. The request shape is defined by
    /// `XPCProcessRequest` (internal to the Transcription package).
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `XPCProcessRequest` containing audio
    ///     paths and custom vocabulary.
    ///   - reply: Callback with JSON-encoded `TranscriptResult` data or an error.
    func processAudio(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    )

    /// Download models if not already cached.
    ///
    /// The worker resolves the appropriate model variant internally
    /// using `TranscriptionMethod.current`.
    ///
    /// - Parameter reply: Callback with nil on success, or an error on failure.
    func ensureModelsDownloaded(
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

    /// Load each Whisper model named in `requestData` (a JSON
    /// `ModelPreparationRequest`) from the model cache, so macOS compiles it
    /// before a meeting needs it, and unload it again, except the one to keep
    /// loaded for live sessions. A model that is not on disk is skipped:
    /// nothing is downloaded.
    ///
    /// Runs only while the worker is otherwise idle; `cancelActiveWork` stops
    /// it after the model loading at the time. The reply is JSON `[String]`:
    /// the models prepared, also after a cancel.
    func prepareModels(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    )

    // MARK: Live sessions

    //
    // One connection's messages keep their order, so chunks arrive in order.
    // The worker hosts one live session at a time, and never alongside a
    // final pass: overlapping requests fail with `TranscriptionError.workerBusy`.

    /// Start a live Whisper session. `configData` is a JSON `LiveSessionConfig`.
    /// Updates arrive through `TranscriberStatusReporting.liveSessionDidUpdate`.
    func startLiveSession(
        configData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    )

    /// Append one chunk (`LiveAudioChunk.encodedForXPC()`). The reply means the
    /// session has taken the chunk; a chunk for another session or generation
    /// is dropped and still acknowledged.
    func appendLiveAudio(
        sessionID: String,
        generation: Int,
        chunkData: Data,
        reply: @escaping @Sendable () -> Void
    )

    /// Stop a running final pass (it fails with `TranscriptionError.cancelled`)
    /// or end the live session. The reply comes once the worker is idle.
    func cancelActiveWork(
        reply: @escaping @Sendable () -> Void
    )

    /// Reply once the worker is idle, without stopping anything.
    func waitUntilIdle(
        reply: @escaping @Sendable () -> Void
    )

    func setLiveUpdateInterval(sessionID: String, seconds: Double)

    func setLivePaused(sessionID: String, paused: Bool)

    /// Finish the session and return its final updates as JSON `[LiveTrackUpdate]`.
    /// The reply comes once the worker is idle.
    func finishLiveSession(
        sessionID: String,
        timeoutSeconds: Double,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    )

    /// End the session without finishing it. The reply comes once the worker is idle.
    func cancelLiveSession(
        sessionID: String,
        reply: @escaping @Sendable () -> Void
    )
}

/// The reverse `@objc` XPC protocol: the **client** exports an object conforming
/// to this so the worker can stream download status messages back during
/// `ensureModelsDownloaded`. Without it the worker's status would have nowhere
/// to go (a one-shot reply handler cannot carry intermediate updates).
///
/// The calls are fire-and-forget (no reply). A dropped download status during
/// teardown is harmless; live updates are merged by the worker, never dropped.
@objc public protocol TranscriberStatusReporting {
    /// Report a human-readable download status message for the current stage.
    func reportDownloadStatus(_ status: String)

    /// One live update, JSON `LiveTrackUpdate`. Pending updates of a track are
    /// merged and sent at most 4 times per second.
    func liveSessionDidUpdate(_ updateData: Data)

    /// The worker ended this session without the client's finish or cancel:
    /// a decode failed, or `cancelActiveWork` ended it.
    func liveSessionDidEnd(sessionID: String, generation: Int)

    /// A final pass started (true) or finished (false) loading a model, so
    /// the app can tell a slow load, which compiles for the Neural Engine,
    /// from a long transcription.
    func reportModelLoading(_ isLoading: Bool)
}
