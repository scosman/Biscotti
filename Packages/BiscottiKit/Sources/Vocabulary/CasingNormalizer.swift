/// Normalizes casing for terms extracted from calendar data.
///
/// Whisper mirrors prompt casing into its output, so the casing we choose
/// directly affects transcription quality. The rules handle three cases:
/// all-uppercase sources (no casing information), inconsistent casing across
/// occurrences, and consistent casing (preserved verbatim).
enum CasingNormalizer {
    /// True when the string has at least one cased letter and no lowercase letter.
    static func isAllUppercase(_ text: String) -> Bool {
        var hasCased = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isUppercase {
                hasCased = true
            } else if scalar.properties.isLowercase {
                return false
            }
        }
        return hasCased
    }

    /// Returns the normalized form for a term given all observed surface forms.
    ///
    /// - Parameters:
    ///   - forms: Every surface form observed for one term, in encounter order.
    ///   - sourceIsAllUppercase: Whether the source string was all-uppercase
    ///     (evaluated per source, not globally).
    /// - Returns: The normalized string.
    static func normalize(forms: [String], sourceIsAllUppercase: Bool) -> String {
        guard let first = forms.first else { return "" }

        // Rule 1: all-uppercase source carries no casing information.
        if sourceIsAllUppercase {
            return first.lowercased()
        }

        // Rule 2: multiple distinct casings = ambiguous → lowercase.
        if Set(forms).count > 1 {
            return first.lowercased()
        }

        // Rule 3: consistent casing → preserve verbatim.
        return first
    }
}
