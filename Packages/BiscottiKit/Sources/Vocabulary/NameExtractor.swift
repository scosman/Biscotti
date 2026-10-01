/// Extracts attendee first names for vocabulary biasing.
///
/// Large meetings (> 20 invitees) contribute no names — the names are
/// not personal enough to be worth the prompt budget. Each name is the
/// first whitespace-separated token, with trailing punctuation stripped,
/// and casing normalized per person (so one all-caps entry does not
/// affect the others).
enum NameExtractor {
    /// Returns first names suitable for vocabulary biasing.
    ///
    /// - Parameters:
    ///   - names: Raw `Person.name` values (organizer first, then participants).
    ///   - rawInviteeCount: Organizer + participants counted before de-duplication.
    static func firstNames(from names: [String], rawInviteeCount: Int) -> [String] {
        guard rawInviteeCount <= VocabularyLimits.maxInvitees else { return [] }

        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Take the first whitespace-separated token.
            guard let firstToken = trimmed.split(
                separator: " ", maxSplits: 1, omittingEmptySubsequences: true
            ).first else { continue }

            // Strip trailing punctuation that some calendars leave on names.
            var token = String(firstToken)
            while token.last == "." || token.last == "," {
                token.removeLast()
            }

            guard token.count >= VocabularyLimits.minNameLength else { continue }

            let personIsAllCaps = CasingNormalizer.isAllUppercase(name)
            let normalized = CasingNormalizer.normalize(
                forms: [token],
                sourceIsAllUppercase: personIsAllCaps
            )
            result.append(normalized)
        }

        return result
    }
}
