import Foundation
import SwiftData

// MARK: - Person

/// A person who participates in or organizes meetings.
/// Recurs across meetings so identity (and future voiceprints) accumulate.
@Model public final class Person: @unchecked Sendable {
    #Unique<Person>([\.id])

    public var id: UUID
    public var name: String
    /// Key field for dedup (may be nil for people without a known email).
    public var email: String?

    // Reserved for P2: voiceprint/centroid embeddings, an "isMe" flag.

    @Relationship(inverse: \Meeting.participants)
    public var meetings: [Meeting] = []

    @Relationship(inverse: \Meeting.organizer)
    public var organizedMeetings: [Meeting] = []

    public init(id: UUID = UUID(), name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}
