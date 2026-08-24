import Foundation

/// Extracts uncommon words from calendar event titles and descriptions.
///
/// Text is scrubbed of URLs, email addresses, and digit-bearing tokens before
/// tokenizing. Candidates are checked against the common-word list via an
/// injected closure. Three guards prevent garbage from reaching the vocabulary:
/// an absolute cap on uncommon words, and two hit-rate ceilings that catch
/// non-English text.
enum UncommonWordExtractor {
    // Pre-compiled patterns for scrubbing conferencing boilerplate.
    // Force-unwrap is safe for known-valid literal patterns.

    // swiftlint:disable force_try
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://\S+"#,
        options: .caseInsensitive
    )
    private static let wwwPattern = try! NSRegularExpression(
        pattern: #"www\.\S+"#,
        options: .caseInsensitive
    )
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
        options: []
    )
    // swiftlint:enable force_try

    /// Returns uncommon words suitable for vocabulary biasing.
    ///
    /// - Parameters:
    ///   - title: The calendar event title, or nil.
    ///   - notes: The calendar event description/notes, or nil.
    ///   - uncommon: Given a set of lowercased candidate words, returns the subset
    ///     that is NOT in the common-word list. Injected for testability.
    /// - Returns: Uncommon words in first-encounter order, casing-normalized.
    static func terms(
        title: String?,
        notes: String?,
        uncommon: (Set<String>) -> Set<String>
    ) -> [String] {
        let source = [title, notes].compactMap(\.self).joined(separator: "\n")
        guard !source.isEmpty else { return [] }

        let scrubbed = scrub(source)
        let groups = groupTokens(scrubbed)
        guard !groups.isEmpty else { return [] }

        let checked = Set(groups.map(\.key))
        let miss = uncommon(checked)
        guard !miss.isEmpty, passesGuards(missCount: miss.count, checkedCount: checked.count)
        else { return [] }

        // Emit in first-encounter order, casing-normalized.
        let sourceIsAllCaps = CasingNormalizer.isAllUppercase(scrubbed)
        return groups
            .filter { miss.contains($0.key) }
            .map { CasingNormalizer.normalize(forms: $0.forms, sourceIsAllUppercase: sourceIsAllCaps) }
    }

    /// Groups tokens by lowercased key, preserving all observed surface forms.
    private static func groupTokens(_ scrubbed: String) -> [(key: String, forms: [String])] {
        let tokens = tokenize(scrubbed)
        var groups: [(key: String, forms: [String])] = []
        var index: [String: Int] = [:]
        for token in tokens {
            let key = token.lowercased()
            if let idx = index[key] {
                groups[idx].forms.append(token)
            } else {
                index[key] = groups.count
                groups.append((key: key, forms: [token]))
            }
        }
        return groups
    }

    /// Returns whether the uncommon-word count and hit rate pass all three guards.
    private static func passesGuards(missCount: Int, checkedCount: Int) -> Bool {
        if missCount > VocabularyLimits.maxUncommonWords { return false }
        let ratio = Double(missCount) / Double(checkedCount)
        if checkedCount <= VocabularyLimits.shortTextWordCount {
            return ratio <= VocabularyLimits.shortTextHitRateCeiling
        }
        return ratio <= VocabularyLimits.longTextHitRateCeiling
    }

    /// Removes URLs, email addresses, and digit-bearing tokens from the source text.
    private static func scrub(_ text: String) -> String {
        var result = text
        let fullRange = NSRange(result.startIndex..., in: result)

        // Remove URLs first (they may contain email-like substrings).
        result = urlPattern.stringByReplacingMatches(
            in: result, range: fullRange, withTemplate: " "
        )
        let range2 = NSRange(result.startIndex..., in: result)
        result = wwwPattern.stringByReplacingMatches(
            in: result, range: range2, withTemplate: " "
        )

        // Remove email addresses.
        let range3 = NSRange(result.startIndex..., in: result)
        result = emailPattern.stringByReplacingMatches(
            in: result, range: range3, withTemplate: " "
        )

        // Remove any whitespace-delimited token that contains a digit.
        let words = result.split(whereSeparator: \.isWhitespace)
        let filtered = words.filter { token in
            !token.unicodeScalars.contains(where: \.properties.numericType.isDigit)
        }
        return filtered.joined(separator: " ")
    }

    /// Splits on non-letter characters and keeps tokens of at least `minTokenLength`.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter {
                current.append(char)
            } else {
                if current.count >= VocabularyLimits.minTokenLength {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if current.count >= VocabularyLimits.minTokenLength {
            tokens.append(current)
        }
        return tokens
    }
}

// MARK: - NumericType helper

private extension Unicode.NumericType? {
    var isDigit: Bool {
        self != nil
    }
}
