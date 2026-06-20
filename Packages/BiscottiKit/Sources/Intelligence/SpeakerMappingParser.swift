/// Parses LLM output into a speaker-ID-to-person mapping.
///
/// The expected format is one line per identified speaker:
/// ```
/// 0 | Daniel Lee | daniel@acme.com
/// 1 | Priya |
/// ```
///
/// Parsing is defensive and line-oriented: malformed lines are skipped,
/// code fences are stripped, and a fully unparseable response yields an
/// empty map rather than an error.
public enum SpeakerMappingParser {
    /// Parsed result for a single speaker mapping line.
    public struct SpeakerMapping: Sendable, Equatable {
        public let name: String
        public let email: String?
    }

    /// Parse raw LLM output into a speaker-index-to-mapping dictionary.
    ///
    /// - Parameter raw: The raw LLM response text.
    /// - Returns: A dictionary mapping speaker index to name+email.
    ///   Duplicate indices are resolved by last-wins. Never throws.
    public static func parse(_ raw: String) -> [Int: SpeakerMapping] {
        let cleaned = stripCodeFences(raw)
        let lines = cleaned.components(separatedBy: .newlines)

        var result: [Int: SpeakerMapping] = [:]

        for line in lines {
            guard let mapping = parseLine(line) else { continue }
            result[mapping.index] = SpeakerMapping(
                name: mapping.name, email: mapping.email
            )
        }

        return result
    }

    // MARK: - Private

    private struct ParsedLine {
        let index: Int
        let name: String
        let email: String?
    }

    private static func parseLine(_ line: String) -> ParsedLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let fields = trimmed.components(separatedBy: "|")
        guard fields.count >= 2 else { return nil }

        // Field 0: speaker index (must be a non-negative integer)
        let indexStr = fields[0].trimmingCharacters(in: .whitespaces)
        guard let index = Int(indexStr), index >= 0 else { return nil }

        // Field 1: name (must be non-empty after trimming)
        let name = fields[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Field 2 (optional): email if it contains @
        let email: String? = if fields.count >= 3 {
            parseEmail(fields[2])
        } else {
            nil
        }

        return ParsedLine(index: index, name: name, email: email)
    }

    private static func parseEmail(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func stripCodeFences(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)

        // Remove leading code fence (```anything)
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
            lines.removeFirst()
        }

        // Remove trailing code fence
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces) == "```"
        {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
}
