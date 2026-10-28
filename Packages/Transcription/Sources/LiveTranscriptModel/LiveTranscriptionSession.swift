import Foundation

/// The one engine interface for live transcription.
///
/// The in-process Whisper session implements it, and so does the app's XPC
/// proxy, so the app and the tests drive every engine the same way.
public protocol LiveTranscriptionSession: Sendable {
    /// Updates for every track, in the order they were produced. The stream
    /// ends when the session finishes, is cancelled or fails; an end without
    /// `finish` or `cancel` means the engine failed.
    var updates: AsyncStream<LiveTrackUpdate> { get }

    func start(_ config: LiveSessionConfig) async throws
    func append(_ chunk: LiveAudioChunk) async
    func setUpdateInterval(_ seconds: TimeInterval) async
    func setPaused(_ paused: Bool) async
    /// Stops accepting audio and returns the final rows, at most one merged
    /// update per track. Updates made while finishing come only from here,
    /// never from `updates`. On timeout, the tail that could not settle is
    /// returned marked incomplete.
    func finish(timeout: Duration) async -> [LiveTrackUpdate]
    func cancel() async
}
