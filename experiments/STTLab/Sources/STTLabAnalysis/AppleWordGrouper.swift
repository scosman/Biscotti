import Foundation
import STTLabCore

/// Granularity classification for a single Apple attributed run.
public enum RunClass: String, Codable, Sendable, CaseIterable {
    /// The run text contains only punctuation (no letter or digit).
    case punctuationOnly
    /// The run covers exactly one whitespace-separated token (or that token minus edge punctuation).
    case wholeWord
    /// The run is inside one token but smaller than it.
    case subWord
    /// The run overlaps two or more tokens.
    case multiWord
    /// The run contains only whitespace.
    case whitespace
}

/// A timing anomaly detected in an Apple result's runs.
public enum RunAnomaly: String, Codable, Sendable, CaseIterable {
    /// Duration is zero or negative.
    case zeroLength
    /// Start is before the previous run's start (by more than 1 ms).
    case outOfOrder
    /// Start is before the previous run's end (by more than 1 ms) but not out of order.
    case overlapping
    /// Start < 0 or end > audioDuration + 0.5.
    case outsideAudio
    /// A run with letters or digits but no time.
    case untimedRun
}

/// Aggregate statistics from AppleWordGrouper for one result.
public struct RunStats: Codable, Sendable, Equatable {
    public var totalRuns: Int
    public var classCounts: [String: Int]
    public var anomalyCounts: [String: Int]

    public init(totalRuns: Int = 0, classCounts: [String: Int] = [:],
                anomalyCounts: [String: Int] = [:]) {
        self.totalRuns = totalRuns
        self.classCounts = classCounts
        self.anomalyCounts = anomalyCounts
    }
}

/// Converts Apple SpeechTranscriber results into `[EngineWord]` with timing derived
/// from attributed runs. Also classifies run granularity and detects timing anomalies.
public enum AppleWordGrouper {

    /// Result of grouping one `AppleResult`.
    public struct GroupResult: Sendable {
        public var words: [EngineWord]
        public var runStats: RunStats
    }

    /// Group runs into words for all results in a meeting.
    public static func group(results: [AppleResult],
                             audioDuration: Double) -> (words: [EngineWord], stats: RunStats) {
        var allWords: [EngineWord] = []
        var totalRuns = 0
        var classCounts: [String: Int] = [:]
        var anomalyCounts: [String: Int] = [:]

        for result in results {
            let gr = groupOneResult(result, audioDuration: audioDuration)
            allWords.append(contentsOf: gr.words)
            totalRuns += gr.runStats.totalRuns
            for (k, v) in gr.runStats.classCounts { classCounts[k, default: 0] += v }
            for (k, v) in gr.runStats.anomalyCounts { anomalyCounts[k, default: 0] += v }
        }

        let stats = RunStats(totalRuns: totalRuns, classCounts: classCounts,
                              anomalyCounts: anomalyCounts)
        return (allWords, stats)
    }

    /// Process a single AppleResult into words + stats.
    static func groupOneResult(_ result: AppleResult,
                               audioDuration: Double) -> GroupResult {
        let text = result.text
        let tokens = tokenize(text)

        // Build words from tokens, assigning times from overlapping runs.
        var words: [EngineWord] = []
        for token in tokens {
            let overlapping = result.runs.filter { run in
                let runStart = run.charOffset
                let runEnd = run.charOffset + run.charLength
                return runStart < token.endOffset && runEnd > token.startOffset
                    && run.timeStart != nil
            }

            let start: Double?
            let end: Double?
            let confidence: Double?

            if overlapping.isEmpty {
                start = nil
                end = nil
                confidence = nil
            } else {
                start = overlapping.compactMap { runStartSeconds($0) }.min()
                end = overlapping.compactMap { runEndSeconds($0) }.max()
                let confValues = overlapping.compactMap(\.confidence)
                confidence = confValues.isEmpty ? nil : confValues.reduce(0, +) / Double(confValues.count)
            }

            words.append(EngineWord(
                text: token.text,
                start: start,
                end: end,
                confidence: confidence,
                segmentIndex: result.index
            ))
        }

        // Classify runs and detect anomalies.
        var classCounts: [String: Int] = [:]
        var anomalyCounts: [String: Int] = [:]
        var prevStart: Double?
        var prevEnd: Double?

        for run in result.runs {
            let cls = classifyRun(run, tokens: tokens)
            classCounts[cls.rawValue, default: 0] += 1

            let anomalies = detectAnomalies(
                run: run,
                prevStart: prevStart,
                prevEnd: prevEnd,
                audioDuration: audioDuration
            )
            for a in anomalies {
                anomalyCounts[a.rawValue, default: 0] += 1
            }

            if let s = runStartSeconds(run) {
                prevStart = s
                if let e = runEndSeconds(run) { prevEnd = e }
            }
        }

        let stats = RunStats(totalRuns: result.runs.count, classCounts: classCounts,
                              anomalyCounts: anomalyCounts)
        return GroupResult(words: words, runStats: stats)
    }

    // MARK: - Tokenization

    struct Token {
        var text: String
        var startOffset: Int // Character offset in the result text (UTF-16)
        var endOffset: Int   // Exclusive
    }

    /// Whether a UTF-16 code unit is whitespace. Surrogate code units (0xD800–0xDFFF,
    /// e.g. from emoji) are not valid scalars — treat them as non-whitespace so we
    /// never split inside a surrogate pair.
    private static func isWhitespace(utf16CodeUnit cu: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(cu) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let utf16 = text.utf16
        var i = utf16.startIndex
        while i < utf16.endIndex {
            // Skip whitespace.
            if isWhitespace(utf16CodeUnit: utf16[i]) {
                i = utf16.index(after: i)
                continue
            }

            let tokenStart = utf16.distance(from: utf16.startIndex, to: i)
            var j = i
            while j < utf16.endIndex,
                  !isWhitespace(utf16CodeUnit: utf16[j]) {
                j = utf16.index(after: j)
            }
            let tokenEnd = utf16.distance(from: utf16.startIndex, to: j)
            let substr = String(decoding: text.utf16[i ..< j], as: UTF16.self)
            tokens.append(Token(text: substr, startOffset: tokenStart, endOffset: tokenEnd))
            i = j
        }
        return tokens
    }

    // MARK: - Run classification

    static func classifyRun(_ run: AppleRun, tokens: [Token]) -> RunClass {
        let runText = run.text
        // Whitespace: only whitespace characters.
        if runText.allSatisfy({ $0.isWhitespace }) {
            return .whitespace
        }
        // Punctuation only: no letter or digit.
        if !runText.contains(where: { $0.isLetter || $0.isNumber }) {
            return .punctuationOnly
        }

        let runStart = run.charOffset
        let runEnd = run.charOffset + run.charLength

        // Find which tokens this run overlaps.
        let overlapped = tokens.filter { t in
            runStart < t.endOffset && runEnd > t.startOffset
        }

        if overlapped.count >= 2 {
            return .multiWord
        }

        guard let token = overlapped.first else {
            // No overlap with any token (should not happen for a lettered run, but defensively).
            return .subWord
        }

        // wholeWord: the run's range equals the token range, or equals the token
        // minus leading/trailing punctuation.
        let strippedStart = token.startOffset + leadingPunctuationLength(token.text)
        let strippedEnd = token.endOffset - trailingPunctuationLength(token.text)

        if (runStart == token.startOffset && runEnd == token.endOffset)
            || (runStart == strippedStart && runEnd == strippedEnd) {
            return .wholeWord
        }

        return .subWord
    }

    static func leadingPunctuationLength(_ text: String) -> Int {
        var count = 0
        for ch in text.utf16 {
            guard let scalar = Unicode.Scalar(ch) else { break }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                break
            }
            count += 1
        }
        return count
    }

    static func trailingPunctuationLength(_ text: String) -> Int {
        var count = 0
        for ch in text.utf16.reversed() {
            guard let scalar = Unicode.Scalar(ch) else { break }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                break
            }
            count += 1
        }
        return count
    }

    // MARK: - Anomaly detection

    static func detectAnomalies(run: AppleRun, prevStart: Double?, prevEnd: Double?,
                                audioDuration: Double) -> [RunAnomaly] {
        var anomalies: [RunAnomaly] = []

        guard let s = runStartSeconds(run) else {
            // Untimed: check if it contains letters or digits.
            if run.text.contains(where: { $0.isLetter || $0.isNumber }) {
                anomalies.append(.untimedRun)
            }
            return anomalies
        }

        let duration = runDurationSeconds(run) ?? 0
        if duration <= 0 {
            anomalies.append(.zeroLength)
        }

        let e = s + (runDurationSeconds(run) ?? 0)

        if let ps = prevStart, s < ps - 0.001 {
            anomalies.append(.outOfOrder)
        } else if let pe = prevEnd, s < pe - 0.001 {
            anomalies.append(.overlapping)
        }

        if s < 0 || e > audioDuration + 0.5 {
            anomalies.append(.outsideAudio)
        }

        return anomalies
    }

    // MARK: - CMTimeValue helpers

    static func runStartSeconds(_ run: AppleRun) -> Double? {
        run.timeStart?.seconds
    }

    static func runDurationSeconds(_ run: AppleRun) -> Double? {
        run.timeDuration?.seconds
    }

    static func runEndSeconds(_ run: AppleRun) -> Double? {
        guard let s = runStartSeconds(run), let d = runDurationSeconds(run) else { return nil }
        return s + d
    }
}
