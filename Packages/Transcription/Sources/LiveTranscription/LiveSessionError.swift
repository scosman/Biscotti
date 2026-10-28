import LiveTranscriptModel

/// Why a live session could not start.
public enum LiveSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    /// The tracks must be `[.mic, .system]`, in either order, or `[.mixed]`.
    case unsupportedTracks([LiveTrack])
    /// The update interval must be more than 0 and at most 60 seconds.
    case invalidUpdateInterval
    /// The engine cannot transcribe this language or locale identifier.
    case languageUnsupported(String)
}
