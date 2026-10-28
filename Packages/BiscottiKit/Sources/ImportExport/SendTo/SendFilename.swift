import DataStore
import Foundation

/// Filename sanitization for Obsidian and Apple Notes (functional spec §7.4).
public enum SendFilename {
    /// Characters removed from filenames (functional spec §7.4).
    private static let disallowed: CharacterSet = {
        var set = CharacterSet()
        for scalar in #"*"\/<>:|?#^[]"#.unicodeScalars {
            set.insert(scalar)
        }
        set.formUnion(.controlCharacters)
        return set
    }()

    /// Sanitize a title for use as a filename (no extension).
    /// Removes disallowed characters, collapses whitespace, trims, strips
    /// a leading `.`, and cuts to <= 120 characters on a character boundary.
    public static func sanitize(_ title: String) -> String {
        var result = String(title.unicodeScalars.filter { !disallowed.contains($0) })

        // Collapse whitespace runs into a single space
        result = result.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading dot
        while result.hasPrefix(".") {
            result = String(result.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Truncate to 120 characters on a Character boundary
        if result.count > 120 {
            result = String(result.prefix(120))
        }

        // Re-trim after truncation (could split mid-space-run)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? "Untitled Meeting" : result
    }

    /// Obsidian filename: `<sanitized title> <yyyy-MM-dd>`.
    public static func obsidianName(
        _ source: ExportSource,
        timeZone: TimeZone = .current
    ) -> String {
        let title = sanitize(source.title)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(title) \(formatter.string(from: source.start))"
    }
}
