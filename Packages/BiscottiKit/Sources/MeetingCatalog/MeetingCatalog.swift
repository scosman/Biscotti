import Foundation

/// Seam providing meeting-app metadata and conference-link detection.
///
/// Both `Calendar` and `MeetingDetection` consume this protocol so a future
/// RemoteConfig module can replace the backing store with no caller changes (C1).
public protocol MeetingCatalog: Sendable {
    /// Returns a human-readable name for the given bundle ID, or nil if unknown.
    func displayName(forBundleID id: String) -> String?

    /// Whether the given bundle ID belongs to a known meeting/conferencing app
    /// (including helper processes).
    func isMeetingApp(bundleID: String) -> Bool

    /// Maps a helper-process bundle ID to the user-facing parent app's bundle ID.
    /// Returns nil if the ID is already a user-facing app (no mapping needed).
    func parentBundleID(forHelperBundleID id: String) -> String?

    /// Detects a conference join link in the given fields (priority: url > location > notes).
    /// Returns the platform name and URL on match, or nil if no conference link is found.
    func conferenceMatch(
        inURL url: URL?,
        location: String?,
        notes: String?
    ) -> (platform: String, url: URL)?
}
