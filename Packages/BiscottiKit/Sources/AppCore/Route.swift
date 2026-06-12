import Foundation

/// The current navigation destination in the app.
public enum Route: Sendable, Equatable {
    /// The home / welcome screen (replaces Stage B `.empty`).
    case home

    /// A recording is in progress; show the recording screen.
    case recording

    /// The two-pane Meetings screen (list + detail). Selection state
    /// lives in `AppCore.meetingsSelection`, not in the route.
    case meetings

    /// An un-recorded upcoming calendar event (read-only preview), keyed by composite key.
    case event(String)

    /// First-run onboarding (full-window takeover).
    case onboarding
}
