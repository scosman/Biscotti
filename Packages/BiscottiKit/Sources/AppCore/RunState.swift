import Foundation

/// The app-wide operational state observable by UI and the menu bar.
public enum RunState: Sendable, Equatable {
    /// No recording active and no pending detection.
    case idle

    /// A recording is in progress for the given meeting.
    case recording(UUID)

    /// A detection notification is outstanding; user hasn't acted yet.
    case detectedPending
}
