import Foundation

/// Lightweight summary of a meeting for display in the per-meeting prompt sheet.
///
/// Built by the host view-model from `MeetingDetailData`; the sheet never
/// imports DataStore or AppCore.
public struct MeetingReference: Sendable {
    public let title: String
    public let date: Date
    public let duration: TimeInterval?

    public init(title: String, date: Date, duration: TimeInterval? = nil) {
        self.title = title
        self.date = date
        self.duration = duration
    }
}
