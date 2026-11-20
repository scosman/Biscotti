import Foundation

// MARK: - Live captions as attribution

/// One live caption from the meeting app: who it named and what it said,
/// in recording seconds. `start` is when it first appeared, which is a
/// moment after the person started talking.
public struct CaptionLine: Sendable, Equatable {
    public var name: String
    public var text: String
    public var start: Double
    public var end: Double

    public init(name: String, text: String, start: Double, end: Double) {
        self.name = name
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Matches caption text to transcript words. The meeting app hears each
/// participant's audio separately, so its caption names are the most direct
/// evidence of who said a word.
public enum CaptionAligner {
    public struct Tuning: Sendable {
        /// How far before a caption's first appearance its words can start.
        public var lead = 4.0
        /// How far after its last update its words can end. Captures made
        /// before 2026-11-20 stored their start times rounded to the second,
        /// so this allows for up to a second of drift on top of the lag.
        public var tail = 2.5
        public var minimumMatches = 2
        public var minimumShare = 0.5
        public init() {}
    }

    /// Word index -> caption speaker for every word a caption accounts for.
    /// Words between a caption's first and last matched word are included:
    /// they belong to the same utterance even if spelled differently.
    public static func assign(_ words: [FusionWord], captions: [CaptionLine], tuning: Tuning = Tuning()) -> [Int: String] {
        // A longer match is stronger evidence than a short one that happens to
        // fit ("can't hear you" in two people's captions).
        var best: [Int: Claim] = [:]
        let units = units(words)
        for caption in captions {
            let captionTokens = collapseDigits(
                caption.text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
            )
            guard captionTokens.count >= tuning.minimumMatches else { continue }
            let window = units.indices.filter {
                units[$0].start >= caption.start - tuning.lead && units[$0].end <= caption.end + tuning.tail
            }
            let matched = longestCommon(captionTokens, window.map { units[$0].token })
            let share = Double(matched.count) / Double(captionTokens.count)
            guard matched.count >= tuning.minimumMatches, share >= tuning.minimumShare,
                  let first = matched.first, let last = matched.last else { continue }
            for position in first ... last {
                for index in units[window[position]].indices {
                    let claim = Claim(name: caption.name, matched: matched.count, share: share)
                    if let existing = best[index], !claim.beats(existing) { continue }
                    best[index] = claim
                }
            }
        }
        return best.mapValues(\.name)
    }

    /// One caption's claim on a word.
    struct Claim {
        var name: String
        var matched: Int
        var share: Double

        func beats(_ other: Claim) -> Bool {
            (matched, share) > (other.matched, other.share)
        }
    }

    /// One matchable token and the transcript words it stands for.
    struct Unit {
        var token: String
        var indices: [Int]
        var start: Double
        var end: Double
    }

    /// Transcript words as matchable tokens. A run of spoken digits ("One,
    /// two, one, two.") becomes one token ("1212"), the way captions write
    /// numbers.
    static func units(_ words: [FusionWord]) -> [Unit] {
        var result: [Unit] = []
        for (index, word) in words.enumerated() {
            let token = normalize(word.text)
            guard !token.isEmpty else { continue }
            if isDigits(token), var last = result.last, isDigits(last.token), last.indices.last == index - 1 {
                last.token += token
                last.indices.append(index)
                last.end = word.end
                result[result.count - 1] = last
            } else {
                result.append(Unit(token: token, indices: [index], start: word.start, end: word.end))
            }
        }
        return result
    }

    /// Joins neighbouring digit tokens: ["1", "2", "go"] -> ["12", "go"].
    static func collapseDigits(_ tokens: [String]) -> [String] {
        var result: [String] = []
        for token in tokens {
            if isDigits(token), let last = result.last, isDigits(last) {
                result[result.count - 1] = last + token
            } else {
                result.append(token)
            }
        }
        return result
    }

    static func isDigits(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Positions in `words` that take part in the longest common subsequence.
    static func longestCommon(_ caption: [String], _ words: [String]) -> [Int] {
        guard !caption.isEmpty, !words.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: words.count + 1), count: caption.count + 1)
        for row in 1 ... caption.count {
            for column in 1 ... words.count {
                table[row][column] = caption[row - 1] == words[column - 1]
                    ? table[row - 1][column - 1] + 1
                    : max(table[row - 1][column], table[row][column - 1])
            }
        }
        var positions: [Int] = []
        var row = caption.count
        var column = words.count
        while row > 0, column > 0 {
            if caption[row - 1] == words[column - 1] {
                positions.append(column - 1)
                row -= 1
                column -= 1
            } else if table[row - 1][column] >= table[row][column - 1] {
                row -= 1
            } else {
                column -= 1
            }
        }
        return positions.reversed()
    }

    /// "Chris." -> "chris", "You're" -> "youre", "Two," -> "2".
    static func normalize(_ text: String) -> String {
        let token = String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        return digitWords[token] ?? token
    }

    /// Spoken digits, written the way captions write them.
    static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"
    ]

    /// A voice most of whose caption-matched words carry one name, with at
    /// least `minimumWords` such words, takes that name.
    static func clusterNames(
        _ words: [FusionWord], assigned: [Int: String], minimumWords: Int = 5, minimumShare: Double = 0.6
    ) -> [Int: String] {
        var counts: [Int: [String: Int]] = [:]
        for (index, name) in assigned {
            guard let cluster = words[index].clusterID else { continue }
            counts[cluster, default: [:]][name, default: 0] += 1
        }
        var result: [Int: String] = [:]
        for (cluster, names) in counts {
            let total = names.values.reduce(0, +)
            guard let top = names.max(by: { $0.value < $1.value }), top.value >= minimumWords,
                  Double(top.value) / Double(total) >= minimumShare else { continue }
            result[cluster] = top.key
        }
        return result
    }
}

extension SpeakerFuser {
    /// A voice most of whose caption-matched words carry one person's name
    /// takes that name (the user excepted: the mic covers them).
    static func withCaptionNames(
        _ names: [Int: String], words: [FusionWord], captioned: [Int: String], userName: String
    ) -> [Int: String] {
        var result = names
        for (cluster, name) in CaptionAligner.clusterNames(words, assigned: captioned)
            where !PersonName.same(name, userName)
        {
            result[cluster] = name
        }
        return result
    }
}
