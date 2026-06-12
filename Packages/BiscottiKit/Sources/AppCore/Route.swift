import Foundation

/// The current navigation destination in the app.
public enum Route: Sendable, Equatable {
    /// The home / welcome screen (replaces Stage B `.empty`).
    case home

    /// A recording is in progress; show the recording screen.
    case recording

    /// A specific meeting is selected; show its detail screen.
    case meeting(UUID)

    /// An un-recorded upcoming calendar event (read-only preview), keyed by composite key.
    case event(String)

    /// Search is active; show the search results pane.
    case search

    /// In-window settings.
    case settings

    /// First-run onboarding (full-window takeover).
    case onboarding
}
