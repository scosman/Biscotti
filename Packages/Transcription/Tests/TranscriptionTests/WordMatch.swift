import Foundation

/// Word-level exact-match evaluator for custom-vocabulary tests.
///
/// Splits the transcript into normalized words, then checks each expected
/// term for exact membership in that word set. Distinct from the chunked
/// Levenshtein evaluator -- Levenshtein is too lenient for single-word
/// correctness.
enum WordMatch {
    /// Evaluate which expected terms appear as exact words in the transcript.
    ///
    /// - Parameters:
    ///   - transcript: The full transcript text to search.
    ///   - expected: The terms that should appear.
    /// - Returns: A tuple of matched and missed terms.
    static func evaluate(
        transcript: String,
        expected: [String]
    ) -> (matched: [String], missed: [String]) {
        let transcriptWords = Set(TextNormalize.words(transcript))
        var matched: [String] = []
        var missed: [String] = []

        for term in expected {
            let normalizedTerm = TextNormalize.normalize(term)
            if transcriptWords.contains(normalizedTerm) {
                matched.append(term)
            } else {
                missed.append(term)
            }
        }

        return (matched: matched, missed: missed)
    }
}
