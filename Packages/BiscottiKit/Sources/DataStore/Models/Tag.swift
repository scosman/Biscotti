import Foundation
import SwiftData

// MARK: - Tag

/// A named, colour-coded label that lives in a global catalogue.
/// Tags exist independently of meetings; the same tag can be applied to
/// many meetings (many-to-many via `Meeting.tags`).
@Model public final class Tag {
    public var id = UUID()
    /// Trimmed display name (case-insensitively unique in the catalogue).
    public var name: String = ""
    /// Stable palette index (0-7), assigned round-robin at creation time.
    public var colorSlot: Int = 0
    /// Creation timestamp, used for round-robin ordering.
    public var createdAt = Date()

    @Relationship(inverse: \Meeting.tags)
    public var meetings: [Meeting] = []

    public init(
        id: UUID = UUID(),
        name: String,
        colorSlot: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorSlot = colorSlot
        self.createdAt = createdAt
    }
}
