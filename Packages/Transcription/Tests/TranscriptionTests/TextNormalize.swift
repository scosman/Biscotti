import Foundation

/// Text normalization for ground-truth comparison.
///
/// Lowercase, trim, collapse internal whitespace, strip punctuation characters
/// (`. , ! ? ' " : ;`). Used by the chunked Levenshtein evaluator and
/// the word-match evaluator.
enum TextNormalize {
    /// Characters stripped during normalization.
    private static let strippedCharacters = CharacterSet(charactersIn: ".,!?'\":;")

    /// Normalize text for comparison: lowercase, trim outer whitespace,
    /// strip punctuation, collapse internal whitespace to single spaces.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        // Strip punctuation characters
        let stripped = lowered.unicodeScalars
            .filter { !strippedCharacters.contains($0) }
            .map { Character(String($0)) }
        let joined = String(stripped)
        // Trim outer whitespace, then collapse internal runs to single space
        let trimmed = joined.trimmingCharacters(in: .whitespaces)
        return trimmed.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Split normalized text into words on whitespace boundaries.
    static func words(_ text: String) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: " ")
    }
}
