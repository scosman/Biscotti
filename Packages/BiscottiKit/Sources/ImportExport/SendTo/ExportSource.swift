import AppLinks
import DataStore
import Foundation

/// The meeting data needed to build an export. Assembled once and passed
/// through the pure pipeline; no AppKit dependency.
public struct ExportSource: Sendable, Equatable {
    public var meetingID: UUID
    public var title: String
    public var start: Date
    public var durationMinutes: Int?
    public var attendees: [String]
    public var summary: String
    public var notes: String
    public var tags: [String]

    public init(
        meetingID: UUID,
        title: String,
        start: Date,
        durationMinutes: Int? = nil,
        attendees: [String] = [],
        summary: String = "",
        notes: String = "",
        tags: [String] = []
    ) {
        self.meetingID = meetingID
        self.title = title
        self.start = start
        self.durationMinutes = durationMinutes
        self.attendees = attendees
        self.summary = summary
        self.notes = notes
        self.tags = tags
    }

    /// Convenience initialiser from a `MeetingDetailData` read model.
    public init(detail: MeetingDetailData) {
        meetingID = detail.id
        title = detail.title
        start = detail.date

        let seconds = detail.recordingDuration ?? detail.duration
        if let seconds, seconds > 0 {
            durationMinutes = Int((seconds / 60).rounded(.up))
        } else {
            durationMinutes = nil
        }

        // Calendar attendees in calendar order, empty names dropped.
        attendees = (detail.calendar?.attendees ?? [])
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        summary = detail.summary
        notes = detail.notes
        tags = detail.tags.map(\.name)
    }

    /// Whether there is anything to send (summary or notes non-empty after trimming).
    public var hasContent: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `biscotti://` deep link for this meeting's summary tab.
    public var biscottiURL: URL {
        AppLink.meeting(id: meetingID, target: .tab(.summary)).url
    }
}
