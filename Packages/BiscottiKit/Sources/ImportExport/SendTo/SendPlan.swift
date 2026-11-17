import DataStore
import Foundation

/// The concrete action to perform for a send: open a URL, copy to clipboard
/// (too large), or hand off a file to Notes.
public enum SendPlan: Equatable, Sendable {
    /// Open a URL scheme (`obsidian://new?…` or `bear://x-callback-url/create?…`).
    case openURL(URL)
    /// The URL would exceed the size limit. The caller should copy the
    /// markdown to the clipboard and show the fallback alert.
    case tooLarge(markdown: String)
    /// Write a temp file and open it with Apple Notes.
    /// `fileName` includes the `.md` extension.
    case handOffFile(fileName: String, contents: String)

    /// 500 * 1024 = 512,000 UTF-8 bytes.
    public static let maxURLBytes = 500 * 1024

    /// Build the plan for a given payload.
    public static func make(
        _ payload: SendPayload,
        source: ExportSource,
        timeZone: TimeZone = .current
    ) -> SendPlan {
        switch payload.destination {
        case .obsidian:
            let name = SendFilename.obsidianName(source, timeZone: timeZone)
            let queryString = StrictPercentEncoder.query([
                ("name", name),
                ("content", payload.markdown)
            ])
            let urlString = "obsidian://new?\(queryString)"
            if urlString.utf8.count > maxURLBytes {
                return .tooLarge(markdown: payload.markdown)
            }
            guard let url = URL(string: urlString) else {
                return .tooLarge(markdown: payload.markdown)
            }
            return .openURL(url)

        case .bear:
            let queryString = StrictPercentEncoder.query([
                ("text", payload.markdown),
                ("tags", payload.tags.joined(separator: ",")),
                ("open_note", "yes")
            ])
            let urlString = "bear://x-callback-url/create?\(queryString)"
            if urlString.utf8.count > maxURLBytes {
                return .tooLarge(markdown: payload.markdown)
            }
            guard let url = URL(string: urlString) else {
                return .tooLarge(markdown: payload.markdown)
            }
            return .openURL(url)

        case .appleNotes:
            let fileName = SendFilename.sanitize(source.title) + ".md"
            return .handOffFile(fileName: fileName, contents: payload.markdown)
        }
    }
}
