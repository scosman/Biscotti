/// Character-level Levenshtein (edit) distance and normalized ratio.
///
/// Used by the diarization ground-truth evaluator to compare transcribed
/// chunks against reference scripts.
enum Levenshtein {
    /// Compute the character-level edit distance between two strings.
    ///
    /// Uses the classic dynamic-programming algorithm with O(min(m,n)) space.
    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let lhsLen = lhsChars.count
        let rhsLen = rhsChars.count

        if lhsLen == 0 { return rhsLen }
        if rhsLen == 0 { return lhsLen }

        // Use the shorter string for the column to save memory
        let (short, long) = lhsLen <= rhsLen ? (lhsChars, rhsChars) : (rhsChars, lhsChars)
        let shortLen = short.count
        let longLen = long.count

        var previous = Array(0 ... shortLen)
        var current = [Int](repeating: 0, count: shortLen + 1)

        for row in 1 ... longLen {
            current[0] = row
            for col in 1 ... shortLen {
                if long[row - 1] == short[col - 1] {
                    current[col] = previous[col - 1]
                } else {
                    current[col] = 1 + min(previous[col], current[col - 1], previous[col - 1])
                }
            }
            swap(&previous, &current)
        }

        return previous[shortLen]
    }

    /// Normalized Levenshtein ratio: `distance / max(len(a), len(b))`.
    ///
    /// Returns 0.0 when both strings are empty (perfect match by convention).
    static func ratio(_ lhs: String, _ rhs: String) -> Double {
        let maxLen = max(lhs.count, rhs.count)
        guard maxLen > 0 else { return 0.0 }
        return Double(distance(lhs, rhs)) / Double(maxLen)
    }
}
