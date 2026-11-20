import Foundation

/// One spelling fix made after transcription.
public struct NameCorrection: Sendable, Equatable {
    public let time: Double
    public let original: String
    public let replacement: String

    public init(time: Double, original: String, replacement: String) {
        self.time = time
        self.original = original
        self.replacement = replacement
    }
}

/// Fixes the spelling of names and terms from the meeting's
/// calendar invite and vocabulary after Whisper has finished, instead of
/// prompting Whisper with them (which loses words and timings). Only the
/// text of a word changes; its timing, speaker and confidence stay.
///
/// Deliberately cautious: a word is replaced only when it is a near miss of
/// exactly one hint by spelling and by sound, and short or everyday words
/// are left alone unless the hint is an acronym ("RIM" -> "RYM").
public enum HintCorrector {
    public static func correct(_ words: [FusionWord], hints: [String]) -> (words: [FusionWord], changes: [NameCorrection]) {
        let targets = usableHints(hints)
        guard !targets.isEmpty else { return (words, []) }
        var changes: [NameCorrection] = []
        let corrected = words.map { word -> FusionWord in
            let parts = split(word.text)
            guard let target = match(parts.core, targets: targets) else { return word }
            var fixed = word
            fixed.text = parts.leading + target + parts.trailing
            changes.append(NameCorrection(time: word.start, original: parts.core, replacement: target))
            return fixed
        }
        return (corrected, changes)
    }

    // MARK: - Hints

    /// Names and terms worth matching: letters only, at least 3 long.
    /// Emails, URLs and numbers are skipped.
    static func usableHints(_ hints: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for hint in hints {
            for piece in hint.split(separator: " ").map(String.init) {
                guard piece.count >= 3, piece.allSatisfy(\.isLetter) else { continue }
                if seen.insert(piece.lowercased()).inserted {
                    result.append(piece)
                }
            }
        }
        return result
    }

    // MARK: - Matching

    static func match(_ core: String, targets: [String]) -> String? {
        guard core.count >= 3, core.allSatisfy(\.isLetter) else { return nil }
        let lower = core.lowercased()
        if targets.contains(core) { return nil }
        var best: (target: String, distance: Int)?
        var tie = false
        for target in targets {
            let targetLower = target.lowercased()
            if lower == targetLower {
                // Same word, different capitals: fix acronyms and names
                // Whisper wrote in lowercase.
                return isAcronym(target) || (core.first?.isLowercase == true && !commonWords.contains(lower))
                    ? target : nil
            }
            guard acceptable(core, lower: lower, target: target, targetLower: targetLower) else { continue }
            let distance = editDistance(lower, targetLower)
            if let current = best {
                if distance < current.distance {
                    best = (target, distance)
                    tie = false
                } else if distance == current.distance {
                    tie = true
                }
            } else {
                best = (target, distance)
            }
        }
        guard let best, !tie else { return nil }
        return best.target
    }

    /// Spelling and sound both close, with guards for short and everyday words.
    static func acceptable(_ core: String, lower: String, target: String, targetLower: String) -> Bool {
        guard lower.first == targetLower.first, abs(lower.count - targetLower.count) <= 2 else { return false }
        let allowed = targetLower.count <= 6 ? 1 : 2
        guard editDistance(lower, targetLower) <= allowed else { return false }
        guard soundKey(lower) == soundKey(targetLower) else { return false }
        let looksProper = core.first?.isUppercase == true
        if lower.count <= 4 || commonWords.contains(lower) {
            // "Dan" stays "Dan" even with a "Sam" on the invite; "RIM" for
            // the acronym "RYM" is corrected when Whisper capitalized it.
            return isAcronym(target) && looksProper
        }
        return true
    }

    static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy(\.isUppercase)
    }

    /// A rough sound-alike key: first letter, then consonant sounds with
    /// similar ones merged and repeats collapsed. "Kelbow"/"Kelbo" -> "KLB",
    /// "RIM"/"RYM" -> "RM".
    static func soundKey(_ word: String) -> String {
        let letters = Array(word.lowercased())
        guard let first = letters.first else { return "" }
        var key = String(first).uppercased()
        var previous: Character = first
        for letter in letters.dropFirst() {
            guard !silent.contains(letter) else {
                previous = letter
                continue
            }
            let mapped = soundGroups[letter] ?? letter
            if mapped != previous {
                key.append(mapped.uppercased())
            }
            previous = mapped
        }
        return key
    }

    private static let silent: Set<Character> = ["a", "e", "i", "o", "u", "y", "h", "w"]
    private static let soundGroups: [Character: Character] = [
        "c": "k", "q": "k", "z": "s", "x": "s", "v": "f", "p": "f", "d": "t", "g": "j", "m": "n"
    ]

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var row = Array(0 ... right.count)
        for (leftIndex, leftChar) in left.enumerated() {
            var previous = row[0]
            row[0] = leftIndex + 1
            for (rightIndex, rightChar) in right.enumerated() {
                let substitution = previous + (leftChar == rightChar ? 0 : 1)
                previous = row[rightIndex + 1]
                row[rightIndex + 1] = min(substitution, row[rightIndex] + 1, previous + 1)
            }
        }
        return row[right.count]
    }

    // MARK: - Words

    struct WordParts {
        var leading: String
        var core: String
        var trailing: String
    }

    /// " Kelbow's," -> " ", "Kelbow", "'s,"
    static func split(_ text: String) -> WordParts {
        let leading = String(text.prefix { $0.isWhitespace })
        let rest = text.dropFirst(leading.count)
        let core = String(rest.prefix { $0.isLetter })
        let trailing = String(rest.dropFirst(core.count))
        return WordParts(leading: leading, core: core, trailing: trailing)
    }

    /// Everyday words a name correction must not touch unless Whisper
    /// capitalized them as a name and the hint is an acronym.
    static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one",
        "our", "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two",
        "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use", "rim", "dan", "ben",
        "that", "with", "have", "this", "will", "your", "from", "they", "know", "want", "been", "good",
        "much", "some", "time", "very", "when", "come", "here", "just", "like", "long", "make", "many",
        "more", "only", "over", "such", "take", "than", "them", "well", "were", "what", "dean", "amy",
        "clear", "pass", "code", "carry", "carey", "dale", "evan", "even", "alex", "nora"
    ]
}
