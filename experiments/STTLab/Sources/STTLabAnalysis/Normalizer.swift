import Foundation

/// A normalized token with a back-reference to its source word index.
public struct NormToken: Sendable, Equatable {
    public var text: String
    public var sourceIndex: Int

    public init(text: String, sourceIndex: Int) {
        self.text = text
        self.sourceIndex = sourceIndex
    }
}

/// Text normalizer for WER computation. Produces lowercase tokens with punctuation
/// removed, contractions expanded, numbers spelled out, and fillers dropped.
public enum Normalizer {

    /// The set of filler words to drop.
    public static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hm", "mm",
        "mhm", "mmhmm", "uhhuh"
    ]

    /// Contraction expansion table.
    static let contractions: [(String, String)] = [
        ("i'm", "i am"),
        ("you're", "you are"),
        ("we're", "we are"),
        ("they're", "they are"),
        ("it's", "it is"),
        ("that's", "that is"),
        ("there's", "there is"),
        ("what's", "what is"),
        ("let's", "let us"),
        ("don't", "do not"),
        ("doesn't", "does not"),
        ("didn't", "did not"),
        ("can't", "can not"),
        ("cannot", "can not"),
        ("won't", "will not"),
        ("isn't", "is not"),
        ("aren't", "are not"),
        ("wasn't", "was not"),
        ("weren't", "were not"),
        ("haven't", "have not"),
        ("hasn't", "has not"),
        ("wouldn't", "would not"),
        ("shouldn't", "should not"),
        ("couldn't", "could not"),
        ("i've", "i have"),
        ("we've", "we have"),
        ("you've", "you have"),
        ("they've", "they have"),
        ("i'll", "i will"),
        ("we'll", "we will"),
        ("you'll", "you will"),
        ("it'll", "it will"),
        ("i'd", "i would"),
        ("gonna", "going to"),
        ("wanna", "want to"),
        ("gotta", "got to"),
        ("okay", "ok"),
    ]

    /// Build the contraction lookup table once (keyed on the contracted form).
    static let contractionMap: [String: String] = {
        var map: [String: String] = [:]
        for (from, to) in contractions {
            map[from] = to
        }
        return map
    }()

    /// Normalize a list of engine words into tokens suitable for alignment and WER.
    public static func tokens(for words: [EngineWord]) -> [NormToken] {
        var result: [NormToken] = []
        for (idx, word) in words.enumerated() {
            let normalized = normalizeWord(word.text)
            let tokens = normalized.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                let t = String(token)
                if !fillers.contains(t) && !t.isEmpty {
                    result.append(NormToken(text: t, sourceIndex: idx))
                }
            }
        }
        return result
    }

    /// Normalize a single word string through all steps.
    static func normalizeWord(_ input: String) -> String {
        var s = input

        // Step 1: NFKC, lowercase, normalize apostrophes.
        s = s.precomposedStringWithCompatibilityMapping
        s = s.lowercased(with: Locale(identifier: "en_US_POSIX"))
        s = s.replacingOccurrences(of: "\u{2018}", with: "'") // left single quote
        s = s.replacingOccurrences(of: "\u{2019}", with: "'") // right single quote
        s = s.replacingOccurrences(of: "\u{02BC}", with: "'") // modifier letter apostrophe

        // Step 2 (early): Handle decimals before punctuation removal.
        // Regex: digits.digits -> "N point M" (each digit spelled out).
        s = expandDecimals(s)

        // Step 2: Symbol expansion.
        s = s.replacingOccurrences(of: "%", with: " percent ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = expandDollarAmounts(s)
        s = s.replacingOccurrences(of: "+", with: " plus ")

        // Step 3: Hyphens, en/em dashes, slashes -> space.
        s = s.replacingOccurrences(of: "\u{2013}", with: " ") // en dash
        s = s.replacingOccurrences(of: "\u{2014}", with: " ") // em dash
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "/", with: " ")

        // Step 4: Remove every character that is not a letter, digit, apostrophe, or whitespace.
        s = String(s.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "'"
                || CharacterSet.whitespaces.contains(scalar)
        })
        // Remove apostrophes at token edges (process per whitespace-separated token).
        s = s.split(separator: " ", omittingEmptySubsequences: true)
            .map { token in
                var t = String(token)
                while t.hasPrefix("'") { t.removeFirst() }
                while t.hasSuffix("'") { t.removeLast() }
                return t
            }
            .joined(separator: " ")

        // Step 5: Split on whitespace (implicit in the joined string).

        // Step 6: Contraction expansion and possessive removal.
        s = s.split(separator: " ", omittingEmptySubsequences: true)
            .flatMap { token -> [String] in
                let t = String(token)
                if let expansion = contractionMap[t] {
                    return expansion.split(separator: " ").map(String.init)
                }
                // Remove trailing 's (possessive).
                var cleaned = t
                if cleaned.hasSuffix("'s") {
                    cleaned = String(cleaned.dropLast(2))
                }
                // Remove any remaining apostrophes.
                cleaned = cleaned.replacingOccurrences(of: "'", with: "")
                return cleaned.isEmpty ? [] : [cleaned]
            }
            .joined(separator: " ")

        // Step 7: Number spell-out.
        s = s.split(separator: " ", omittingEmptySubsequences: true)
            .flatMap { token -> [String] in
                let t = String(token)
                if let spelled = spellOutNumber(t) {
                    return spelled.split(separator: " ").map(String.init)
                }
                return [t]
            }
            .joined(separator: " ")

        return s
    }

    // MARK: - Number handling

    /// Spell out pure digit tokens.
    static func spellOutNumber(_ token: String) -> String? {
        // Ordinals: 1st, 2nd, 3rd, Nth.
        if let ordinal = spellOutOrdinal(token) {
            return ordinal
        }
        // Pure digits.
        guard token.allSatisfy({ $0.isNumber }) else { return nil }
        guard let number = Int(token) else { return nil }
        return spellOutInteger(number)
    }

    /// Spell out an integer using NumberFormatter .spellOut with en_US.
    static func spellOutInteger(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        let spelled = formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        // The formatter uses hyphens (e.g. "twenty-one"), convert to spaces.
        return spelled.replacingOccurrences(of: "-", with: " ")
    }

    /// Spell out ordinals: 1st -> first, 2nd -> second, etc.
    static func spellOutOrdinal(_ token: String) -> String? {
        let suffixes = ["st", "nd", "rd", "th"]
        for suffix in suffixes {
            if token.hasSuffix(suffix) {
                let digits = String(token.dropLast(suffix.count))
                if digits.allSatisfy({ $0.isNumber }), let n = Int(digits) {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .ordinal
                    formatter.locale = Locale(identifier: "en_US")
                    // NumberFormatter.ordinal gives "1st", "2nd" etc, not spelled out.
                    // Use the spellOut style and manually derive ordinal.
                    return spellOutOrdinalWord(n)
                }
            }
        }
        return nil
    }

    /// Spell out an ordinal number as a word.
    static func spellOutOrdinalWord(_ n: Int) -> String {
        // Common ordinals.
        let specialOrdinals: [Int: String] = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
            11: "eleventh", 12: "twelfth", 13: "thirteenth", 14: "fourteenth",
            15: "fifteenth", 16: "sixteenth", 17: "seventeenth", 18: "eighteenth",
            19: "nineteenth", 20: "twentieth", 30: "thirtieth", 40: "fortieth",
            50: "fiftieth", 60: "sixtieth", 70: "seventieth", 80: "eightieth",
            90: "ninetieth",
        ]
        if let special = specialOrdinals[n] { return special }

        // For compound numbers (e.g., 21 -> twenty first), spell out the cardinal
        // and change the last word to ordinal.
        let cardinal = spellOutInteger(n)
        let parts = cardinal.split(separator: " ").map(String.init)
        guard let last = parts.last else { return cardinal }

        // Try the last word as a small number.
        if let lastNum = cardinalToOrdinalWord(last) {
            return (parts.dropLast() + [lastNum]).joined(separator: " ")
        }

        // Fallback: append "th".
        if last.hasSuffix("y") {
            return (parts.dropLast() + [String(last.dropLast()) + "ieth"]).joined(separator: " ")
        }
        return cardinal + "th"
    }

    /// Convert a single cardinal word to its ordinal form.
    static func cardinalToOrdinalWord(_ word: String) -> String? {
        let map: [String: String] = [
            "one": "first", "two": "second", "three": "third", "four": "fourth",
            "five": "fifth", "six": "sixth", "seven": "seventh", "eight": "eighth",
            "nine": "ninth", "ten": "tenth", "eleven": "eleventh", "twelve": "twelfth",
            "thirteen": "thirteenth", "fourteen": "fourteenth", "fifteen": "fifteenth",
            "sixteen": "sixteenth", "seventeen": "seventeenth", "eighteen": "eighteenth",
            "nineteen": "nineteenth",
        ]
        return map[word]
    }

    /// Expand decimal numbers: "3.5" -> "three point five".
    static func expandDecimals(_ s: String) -> String {
        // Match digit+.digit+ patterns.
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)"#) else { return s }
        var result = s
        // Process matches from back to front so offsets stay valid.
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let intRange = Range(match.range(at: 1), in: result),
                  let fracRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let intPart = String(result[intRange])
            let fracPart = String(result[fracRange])

            guard let intNum = Int(intPart) else { continue }
            let intSpelled = spellOutInteger(intNum)
            let fracSpelled = fracPart.compactMap { ch -> String? in
                guard let d = Int(String(ch)) else { return nil }
                return spellOutInteger(d)
            }.joined(separator: " ")

            let replacement = "\(intSpelled) point \(fracSpelled)"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    /// Expand $NNN -> "NNN dollars".
    static func expandDollarAmounts(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$(\d+)"#) else { return s }
        var result = s
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let numRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let numStr = String(result[numRange])
            result.replaceSubrange(fullRange, with: "\(numStr) dollars")
        }
        return result
    }
}
