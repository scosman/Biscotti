import CryptoKit
import DataStore
import Foundation

/// The fully assembled content for one send operation: the markdown text,
/// the sanitized tags, and the content hash (functional spec §6).
public struct SendPayload: Sendable, Equatable {
    public let destination: ExportDestination
    /// The exact markdown text that is sent (and that the clipboard fallback copies).
    public let markdown: String
    /// Sanitized tags for this destination.
    public let tags: [String]
    /// SHA-256 hex of `markdown + "\n" + tags.joined(",")` (functional spec §6).
    public let contentHash: String

    /// Build a payload for the given source and destination.
    public static func build(
        _ source: ExportSource,
        for destination: ExportDestination,
        timeZone: TimeZone = .current
    ) -> SendPayload {
        let tags = SendTags.tags(source.tags, for: destination)
        let body = SendMarkdown.body(source, timeZone: timeZone)

        let markdown: String = switch destination {
        case .obsidian:
            SendMarkdown.obsidianFrontmatter(source, tags: tags, timeZone: timeZone) + body
        case .bear:
            body
        case .appleNotes:
            body + "\n" + SendMarkdown.notesTagFooter(tags) + "\n"
        }

        let hashInput = markdown + "\n" + tags.joined(separator: ",")
        let digest = SHA256.hash(data: Data(hashInput.utf8))
        let contentHash = digest.map { String(format: "%02x", $0) }.joined()

        return SendPayload(
            destination: destination,
            markdown: markdown,
            tags: tags,
            contentHash: contentHash
        )
    }

    /// Internal memberwise init.
    private init(
        destination: ExportDestination,
        markdown: String,
        tags: [String],
        contentHash: String
    ) {
        self.destination = destination
        self.markdown = markdown
        self.tags = tags
        self.contentHash = contentHash
    }
}
