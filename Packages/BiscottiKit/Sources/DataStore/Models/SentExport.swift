import Foundation

// MARK: - ExportDestination

/// A third-party app to which a meeting's notes can be sent.
/// `CaseIterable` order = UI display order (Obsidian, Bear, Apple Notes).
public enum ExportDestination: String, Codable, Sendable, CaseIterable {
    case obsidian
    case bear
    case appleNotes = "apple-notes"
}

// MARK: - SentExport

/// Records one "send" of a meeting's notes to a destination. At most one record
/// per destination per meeting; a resend replaces it.
public struct SentExport: Codable, Sendable, Equatable {
    public var destination: ExportDestination
    /// Lowercase SHA-256 hex of the content that was sent (functional spec §6).
    public var contentHash: String
    public var sentAt: Date

    public init(destination: ExportDestination, contentHash: String, sentAt: Date) {
        self.destination = destination
        self.contentHash = contentHash
        self.sentAt = sentAt
    }
}
