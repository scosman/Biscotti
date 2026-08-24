import Foundation

/// Word-level evaluator for custom-vocabulary tests.
///
/// Splits the transcript into normalized words, then checks each expected
/// term for exact membership in that word set (after `TextNormalize`
/// lowercasing + punctuation stripping). Distinct from the chunked
/// Levenshtein evaluator, which is too lenient for single-word correctness.
enum WordMatch {
    /// Evaluate which expected terms appear in the transcript.
    ///
    /// Each expected term is checked for an exact normalized match against
    /// the transcript's word set. A term like "Llami" when the expected
    /// term is "Llama" counts as a miss — the test exists to detect exactly
    /// that kind of vocabulary-biasing failure.
    ///
    /// - Parameters:
    ///   - transcript: The full transcript text to search.
    ///   - expected: The terms that should appear.
    /// - Returns: A tuple of matched and missed terms.
    static func evaluate(
        transcript: String,
        expected: [String]
    ) -> (matched: [String], missed: [String]) {
        let transcriptWordSet = Set(TextNormalize.words(transcript))
        var matched: [String] = []
        var missed: [String] = []

        for term in expected {
            let normalizedTerm = TextNormalize.normalize(term)
            if transcriptWordSet.contains(normalizedTerm) {
                matched.append(term)
            } else {
                missed.append(term)
            }
        }

        return (matched: matched, missed: missed)
    }
}
