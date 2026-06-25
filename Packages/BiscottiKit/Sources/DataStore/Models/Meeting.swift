import Foundation
import SwiftData

// MARK: - Meeting

/// A recorded (or upcoming) meeting — the central aggregate in the data model.
@Model public final class Meeting {
    /// The default title assigned to new recordings. Used as the gate
    /// condition for AI title generation (only replace this exact string).
    public static let defaultTitle = "Untitled Meeting"
    public var id = UUID()
    public var title: String = ""
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt = Date()
    /// The user's own notes (distinct from calendar event notes).
    public var notes: String = ""
    /// Which transcript version is "current" (set via `setPreferredTranscript`).
    public var preferredTranscriptID: UUID?

    /// Whether the user has manually edited the title. When `true`, calendar
    /// association will NOT overwrite the title with the event name.
    public var editedTitle: Bool = false

    /// AI-generated or user-edited markdown meeting summary.
    public var summary: String = ""

    /// Whether the user has manually edited the summary. When `true`,
    /// the auto-run will not overwrite it (mirrors `editedTitle` semantics).
    public var editedSummary: Bool = false

    /// The recording's wall-clock duration in seconds, captured when the
    /// recording stops. `nil` for meetings that were never recorded (e.g.
    /// calendar-only entries) or recordings from before this field existed.
    /// Additive field -- defaults nil, no migration needed.
    public var recordingDuration: TimeInterval?

    @Relationship(deleteRule: .cascade)
    public var audioFiles: [AudioFileRef] = []

    @Relationship(deleteRule: .cascade)
    public var transcripts: [TranscriptRecord] = []

    @Relationship(deleteRule: .cascade)
    public var calendarSnapshot: CalendarSnapshot?

    @Relationship
    public var tags: [Tag] = []

    @Relationship
    public var participants: [Person] = []

    @Relationship
    public var organizer: Person?

    public init(
        id: UUID = UUID(),
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        createdAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.notes = notes
    }
}
