import Foundation
import SwiftData

// MARK: - Meeting

/// A recorded (or upcoming) meeting — the central aggregate in the data model.
@Model public final class Meeting: @unchecked Sendable {
    public var id = UUID()
    public var title: String = ""
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt = Date()
    /// The user's own notes (distinct from calendar event notes).
    public var notes: String = ""
    /// Which transcript version is "current" (set via `setPreferredTranscript`).
    public var preferredTranscriptID: UUID?

    @Relationship(deleteRule: .cascade)
    public var audioFiles: [AudioFileRef] = []

    @Relationship(deleteRule: .cascade)
    public var transcripts: [TranscriptRecord] = []

    @Relationship(deleteRule: .cascade)
    public var calendarSnapshot: CalendarSnapshot?

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
