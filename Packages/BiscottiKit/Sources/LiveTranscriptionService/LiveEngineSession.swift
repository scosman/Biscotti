import Foundation
import LiveTranscriptModel

/// A live engine session as `LiveTranscriptionService` drives it.
public protocol LiveEngineSession: LiveTranscriptionSession {
    /// Sends one chunk. Returns false when the engine did not take it: its
    /// track has 8 chunks unacknowledged, or no session runs. The caller
    /// offers the same chunk again, to this engine or the next one.
    func offer(_ chunk: LiveAudioChunk) async -> Bool
}

/// Makes the engine session for one generation of a recording's live transcript.
public typealias LiveEngineFactory = @Sendable () -> any LiveEngineSession

/// The live engine's model on disk.
public protocol LiveModelProviding: Sendable {
    /// Reads the disk only.
    func isPresent() -> Bool

    /// Downloads the model. `status` receives a message for each stage.
    func download(status: @escaping @Sendable (String) -> Void) async throws
}
