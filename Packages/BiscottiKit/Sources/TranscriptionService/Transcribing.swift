import Foundation
import Transcription

/// Seam over `Transcription.Transcriber` so `TranscriptionService` can be
/// tested with a fake engine (no real CoreML, no XPC, no hardware).
///
/// The protocol consumes `TranscriptResult` directly -- it is a lightweight
/// `Sendable` value type already designed for cross-module use.
public protocol Transcribing: Sendable {
    /// Download models if not already cached. The `status` callback receives
    /// human-readable messages (e.g. "Downloading speech-to-text model").
    func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws

    /// Run STT + diarization on mic + system audio files.
    func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String]
    ) async throws -> TranscriptResult

    /// Release the transcription worker and its resources. For XPC-backed
    /// implementations this tears down the connection so the heavyweight
    /// worker process can exit. The engine remains usable; subsequent calls
    /// will transparently reconnect.
    func shutdown() async
}

// Re-export Transcription types so downstream modules (AppCore, UI) can use
// `TranscriptResult` without importing Transcription directly.
@_exported import struct Transcription.TranscriptResult
@_exported import struct Transcription.TranscriptSegment
@_exported import struct Transcription.TranscriptWord
