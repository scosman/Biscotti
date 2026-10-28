import Foundation
import Transcription

/// Seam over `Transcription.Transcriber` so `TranscriptionService` can be
/// tested with a fake engine (no real CoreML, no XPC, no hardware).
///
/// The protocol consumes `TranscriptResult` directly -- it is a lightweight
/// `Sendable` value type already designed for cross-module use.
///
/// The methods are `nonisolated(nonsending)`: they run on the caller's actor
/// until they reach the engine. `TranscriptionService` calls them from the
/// MainActor, so a pass it starts and a cancel it sends later reach the
/// `Transcriber` actor in that order, rather than through the generic executor
/// in either order.
public protocol Transcribing: Sendable {
    /// Download models if not already cached. The `status` callback receives
    /// human-readable messages (e.g. "Downloading speech-to-text model").
    nonisolated(nonsending) func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws

    /// Run STT + diarization on mic + system audio files.
    nonisolated(nonsending) func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String]
    ) async throws -> TranscriptResult

    /// Returns `true` when models are already present on disk (no download
    /// needed). This is a read-only probe -- it must not download, load,
    /// or mutate any engine state.
    nonisolated(nonsending) func modelsPresent() async -> Bool

    /// Stop the worker's running work and return once it reports it is idle.
    /// A `processAudio` call in flight then throws. Implementations may wait
    /// indefinitely for an unresponsive worker; the caller bounds the wait.
    nonisolated(nonsending) func cancelActiveWork() async

    /// Return once the worker is idle, without stopping anything: a pass the
    /// worker refused as busy runs again after this.
    nonisolated(nonsending) func waitUntilWorkerIdle() async

    /// Load each named Whisper model in the worker, so macOS compiles it
    /// before a meeting needs it, and unload it again, except `keepLoaded`,
    /// which stays loaded for live sessions while the worker runs. Models not
    /// on disk are skipped; nothing is downloaded. `cancelActiveWork` stops it
    /// after the model loading at the time.
    /// - Parameter reloadingKept: Load `keepLoaded` again even if it is
    ///   loaded, for its new files.
    /// - Returns: The models prepared, also after a cancel.
    nonisolated(nonsending) func prepareModels(_ models: [String], keepLoaded: String?, reloadingKept: Bool) async throws -> [String]

    /// Unloads the final pass's models (Whisper and SpeakerKit) while the
    /// worker stays up, with a model kept loaded. Does nothing while the
    /// worker runs other work.
    nonisolated(nonsending) func unloadFinalPassModels() async

    /// Calls `handler` when a final pass starts (true) or ends (false) a
    /// model load in the worker, so a slow load can be told apart from a
    /// long transcription.
    nonisolated(nonsending) func observeModelLoads(_ handler: @escaping @Sendable (Bool) -> Void) async

    /// Calls `handler` whenever the worker ends unexpectedly, even with no
    /// call in flight, so a model kept loaded is known to be gone.
    nonisolated(nonsending) func observeWorkerInterruptions(_ handler: @escaping @Sendable () -> Void) async

    /// Release the transcription worker and its resources. For XPC-backed
    /// implementations this tears down the connection so the heavyweight
    /// worker process can exit. The engine remains usable; subsequent calls
    /// will transparently reconnect.
    nonisolated(nonsending) func shutdown() async
}

public extension Transcribing {
    nonisolated(nonsending) func observeModelLoads(_: @escaping @Sendable (Bool) -> Void) async {}

    nonisolated(nonsending) func observeWorkerInterruptions(_: @escaping @Sendable () -> Void) async {}
}

// Re-export Transcription types so downstream modules (AppCore, UI) can use
// `TranscriptResult` without importing Transcription directly.
@_exported import struct Transcription.TranscriptResult
@_exported import struct Transcription.TranscriptSegment
@_exported import struct Transcription.TranscriptWord
