import Foundation

/// Limits the app and the transcription worker share for live sessions.
public enum LiveWorkerLimits {
    /// A live decode that has not returned this long after its session
    /// ended is stuck. The worker then ends its process, which interrupts
    /// every connection to it; the app waits at least this long before it
    /// gives up on a worker that never replies.
    public static let stuckDecode: Duration = .seconds(10)
}
