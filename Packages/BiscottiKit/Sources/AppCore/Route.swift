import Foundation

/// The current navigation destination in the app.
public enum Route: Sendable, Equatable {
    /// No meeting selected; show a placeholder.
    case empty

    /// A recording is in progress; show the recording screen.
    case recording

    /// A specific meeting is selected; show its detail screen.
    case meeting(UUID)
}
