import Foundation

/// Spots Whisper drifting into another language, which it
/// does when audio breaks up (on a test call: "we haben ja schon über das",
/// "e não é"). Looks for everyday German, Portuguese, Spanish and French
/// function words; two or more, or a quarter of a short line, counts.
public enum LanguageDrift {
    static let foreignWords: Set<String> = [
        // German
        "das", "ist", "und", "nicht", "der", "dem", "auf", "sind", "alle", "haben", "schon",
        "über", "eine", "ein", "hat", "mehr", "mit", "wir", "ich", "auch", "noch", "aber", "diese", "wie",
        // Portuguese / Spanish
        "não", "é", "que", "com", "uma", "para", "isso", "está", "muito", "pero", "como", "esto", "también",
        // French
        "est", "les", "une", "pas", "avec", "pour", "dans", "très", "nous", "vous"
    ]

    public static func looksForeign(_ words: [String]) -> Bool {
        let tokens = words.map {
            $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).lowercased()
        }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        let hits = tokens.count { foreignWords.contains($0) }
        return hits >= 2 || (tokens.count <= 6 && hits >= 1 && Double(hits) / Double(tokens.count) >= 0.25)
    }
}
