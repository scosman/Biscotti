import Foundation

/// Shared timing constants for meeting-related features.
public enum MeetingTiming {
    /// The +/- window (in seconds) around an event's start time where
    /// "Join & Record" is offered and the hero row is shown.
    /// 15 minutes = 900 seconds.
    public static let joinWindowSeconds: TimeInterval = 15 * 60
}
