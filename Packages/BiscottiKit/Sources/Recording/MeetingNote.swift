import Foundation

/// A timestamped note captured during a recording session.
///
/// Notes are held in memory (in `RecordingController.notes`) while
/// recording and seeded into the meeting's markdown notes on stop.
/// Storage order is oldest-first (insertion order); the UI reverses
/// for newest-first display.
public struct MeetingNote: Identifiable, Sendable, Equatable {
    /// Stable identity for SwiftUI diffing and mutation targeting.
    public let id: UUID
    /// The user-entered note text.
    public var text: String
    /// Recording elapsed time (seconds) when the note was added.
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), text: String, timestamp: TimeInterval) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
