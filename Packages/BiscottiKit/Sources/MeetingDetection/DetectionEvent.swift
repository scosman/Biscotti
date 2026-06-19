/// Events emitted by `MeetingDetector` when a meeting app transitions
/// between in-call and idle states, or when the set of non-self mic
/// users transitions from non-empty to empty.
public enum DetectionEvent: Sendable, Equatable {
    /// A meeting app started an audio call (input + output active, debounce elapsed).
    case started(app: DetectedApp)
    /// A meeting app stopped its audio call (IO ceased, debounce elapsed; or detector stopped).
    case stopped(app: DetectedApp)
    /// All non-Biscotti processes using the mic have stopped (>=1 -> 0 transition).
    /// Fires regardless of whether the mic users were meeting apps.
    case allMicUsersStopped
}

/// Identifies the user-facing meeting app associated with a detection event.
///
/// `bundleID` is always the resolved parent app (helper bundle IDs like
/// `com.apple.WebKit.GPU` are mapped to their parent via `MeetingCatalog`
/// before emission).
public struct DetectedApp: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}
