import Foundation

/// A parsed `biscotti://` URL, independent of any app state.
///
/// Parsing is a pure function: it validates shape only (scheme, route,
/// parameters) and never checks whether a target actually exists. Existence
/// is the caller's job and fails at a different tier — a link that parses
/// but points at a missing meeting/event is surfaced to the user, while a
/// link that fails to parse is a silent no-op.
public enum AppLink: Sendable, Equatable {
    case home
    case meetings
    case settings
    case meeting(id: UUID, target: MeetingTarget)
    case search(query: String)
    case upcoming(key: String)
    case record(title: String?)
}

/// Where inside a meeting a link points.
///
/// Encodes the documented `?tab`/`?time` resolution as data rather than as
/// two optional fields the consumer must re-prioritize: parsing decides
/// once (an unparseable `time` rejects the URL; a parseable `time` wins
/// over `tab`), so every consumer just switches.
public enum MeetingTarget: Sendable, Equatable {
    /// A `?tab` value, or the default `.summary` when no tab is given.
    case tab(MeetingTab)
    /// A `?time` value in seconds. Implies the transcript tab.
    case transcriptTime(TimeInterval)
}

/// The tabs of the meeting detail view that a link can target.
public enum MeetingTab: String, Sendable, Equatable, CaseIterable {
    case summary
    case transcript
    case notes
}
