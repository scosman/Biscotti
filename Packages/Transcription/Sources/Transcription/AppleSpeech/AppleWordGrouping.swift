import Foundation
import WhisperKit

/// Input data from a single Apple attributed run. Mirrors the data extracted
/// from `AttributedString` run attributes without importing Speech.
public struct AppleRunInput: Equatable, Sendable {
    /// The text of this run.
    public let text: String
    /// UTF-16 character offset within the result text.
    public let charOffset: Int
    /// UTF-16 character length of this run.
    public let charLength: Int
    /// Start time in seconds (nil if untimed).
    public let start: Double?
    /// Duration in seconds (nil if untimed).
    public let duration: Double?
    /// Transcription confidence (nil if not reported).
    public let confidence: Double?

    public init(
        text: String, charOffset: Int, charLength: Int,
        start: Double?, duration: Double?, confidence: Double?
    ) {
        self.text = text
        self.charOffset = charOffset
        self.charLength = charLength
        self.start = start
        self.duration = duration
        self.confidence = confidence
    }
}

/// Input data from one Apple result (one final transcription event).
public struct AppleResultInput: Equatable, Sendable {
    /// The full text of this result.
    public let text: String
    /// Audio time range start for this result (seconds).
    public let rangeStart: Double
    /// Audio time range duration for this result (seconds).
    public let rangeDuration: Double
    /// Attributed runs extracted from this result.
    public let runs: [AppleRunInput]

    public init(
        text: String, rangeStart: Double, rangeDuration: Double,
        runs: [AppleRunInput]
    ) {
        self.text = text
        self.rangeStart = rangeStart
        self.rangeDuration = rangeDuration
        self.runs = runs
    }
}

/// A word extracted from Apple results with optional timing.
public struct AppleWord: Equatable, Sendable {
    public let text: String
    public let start: Double?
    public let end: Double?
    public let confidence: Double?

    public init(text: String, start: Double?, end: Double?, confidence: Double?) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Converts Apple SpeechTranscriber results into words with timing derived
/// from attributed runs, then bridges them into WhisperKit `TranscriptionResult`
/// for the shared speaker-attribution + assembly pipeline.
///
/// Pure: no Speech framework import. Testable with plain structs.
public enum AppleWordGrouping {
    // MARK: - Word extraction

    /// Extract words from a single result by tokenizing on whitespace and
    /// assigning times from overlapping timed runs.
    public static func words(in result: AppleResultInput) -> [AppleWord] {
        let tokens = tokenize(result.text)
        return tokens.map { token in
            let overlapping = result.runs.filter { run in
                let runEnd = run.charOffset + run.charLength
                return run.charOffset < token.endOffset
                    && runEnd > token.startOffset
                    && run.start != nil
            }

            if overlapping.isEmpty {
                return AppleWord(text: token.text, start: nil, end: nil, confidence: nil)
            }

            let start = overlapping.compactMap(\.start).min()
            let end = overlapping.compactMap { run in
                guard let runStart = run.start, let dur = run.duration else { return nil as Double? }
                return runStart + dur
            }.max()
            let confValues = overlapping.compactMap(\.confidence)
            let confidence = confValues.isEmpty
                ? nil
                : confValues.reduce(0, +) / Double(confValues.count)

            return AppleWord(text: token.text, start: start, end: end, confidence: confidence)
        }
    }

    // MARK: - Untimed fill

    /// Fill untimed words from context: previous timed word's end, or next
    /// timed word's start, or evenly spread across the result range.
    /// Words are never dropped.
    public static func fillUntimed(
        _ words: [AppleWord],
        result: AppleResultInput
    ) -> [AppleWord] {
        // Check if any word has timing at all.
        let hasAnyTimed = words.contains { $0.start != nil }

        if !hasAnyTimed {
            // Spread evenly across the result range.
            let count = words.count
            guard count > 0 else { return words }
            let step = count > 1 ? result.rangeDuration / Double(count) : result.rangeDuration
            return words.enumerated().map { idx, word in
                let wordStart = result.rangeStart + Double(idx) * step
                let wordEnd = result.rangeStart + Double(idx + 1) * step
                return AppleWord(text: word.text, start: wordStart, end: wordEnd, confidence: word.confidence)
            }
        }

        var filled = words
        // Forward pass: untimed words take previous timed word's end.
        var lastEnd: Double?
        for idx in filled.indices {
            if filled[idx].start != nil {
                lastEnd = filled[idx].end
            } else if let prevEnd = lastEnd {
                filled[idx] = AppleWord(
                    text: filled[idx].text, start: prevEnd, end: prevEnd,
                    confidence: filled[idx].confidence
                )
            }
        }

        // Backward pass: remaining untimed words (before any timed word)
        // take the next timed word's start.
        var nextStart: Double?
        for idx in filled.indices.reversed() {
            if filled[idx].start != nil {
                nextStart = filled[idx].start
            } else if let followingStart = nextStart {
                filled[idx] = AppleWord(
                    text: filled[idx].text, start: followingStart, end: followingStart,
                    confidence: filled[idx].confidence
                )
            }
        }

        return filled
    }

    // MARK: - Bridge to WhisperKit types

    /// Convert Apple results into `[TranscriptionResult]` for the shared
    /// speaker-attribution + assembly pipeline.
    ///
    /// One `TranscriptionSegment` per result. Empty results (zero words) are
    /// dropped. Results are ordered by the first word's start time.
    public static func transcriptionResults(
        from results: [AppleResultInput],
        language: String
    ) -> [TranscriptionResult] {
        var segments = buildSegments(from: results)

        // Sort by first word start time and re-index.
        segments.sort { $0.start < $1.start }
        segments = reindex(segments)

        let combinedText = segments.map(\.text).joined(separator: " ")
        let result = TranscriptionResult(
            text: combinedText,
            segments: segments,
            language: language,
            timings: TranscriptionTimings()
        )

        return [result]
    }

    /// Build one `TranscriptionSegment` per non-empty result.
    private static func buildSegments(
        from results: [AppleResultInput]
    ) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []

        for result in results {
            let raw = words(in: result)
            let filled = fillUntimed(raw, result: result)
            guard !filled.isEmpty else { continue }

            let starts = filled.compactMap(\.start)
            let ends = filled.compactMap(\.end)
            guard let segStart = starts.min(), let segEnd = ends.max() else { continue }

            let timings = filled.map { word in
                WordTiming(
                    word: " " + word.text,
                    tokens: [],
                    start: Float(word.start ?? segStart),
                    end: Float(word.end ?? segEnd),
                    probability: Float(word.confidence ?? 1.0)
                )
            }

            let text = filled.map(\.text).joined(separator: " ")
            let segment = TranscriptionSegment(
                id: segments.count, seek: 0,
                start: Float(segStart), end: Float(segEnd),
                text: text, tokens: [],
                temperature: 0, avgLogprob: 0,
                compressionRatio: 0, noSpeechProb: 0,
                words: timings
            )
            segments.append(segment)
        }

        return segments
    }

    /// Re-assign sequential IDs after sorting.
    private static func reindex(
        _ segments: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        segments.enumerated().map { idx, seg in
            TranscriptionSegment(
                id: idx,
                seek: seg.seek,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                tokens: seg.tokens,
                temperature: seg.temperature,
                avgLogprob: seg.avgLogprob,
                compressionRatio: seg.compressionRatio,
                noSpeechProb: seg.noSpeechProb,
                words: seg.words
            )
        }
    }

    // MARK: - Tokenization

    struct Token {
        var text: String
        var startOffset: Int // UTF-16 offset in the result text
        var endOffset: Int // Exclusive
    }

    /// Whether a UTF-16 code unit is whitespace. Surrogate code units
    /// (0xD800–0xDFFF) are not valid scalars — treat them as non-whitespace
    /// so we never split inside a surrogate pair.
    private static func isWhitespace(utf16CodeUnit codeUnit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(codeUnit) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let utf16 = text.utf16
        var pos = utf16.startIndex
        while pos < utf16.endIndex {
            if isWhitespace(utf16CodeUnit: utf16[pos]) {
                pos = utf16.index(after: pos)
                continue
            }

            let tokenStart = utf16.distance(from: utf16.startIndex, to: pos)
            var end = pos
            while end < utf16.endIndex,
                  !isWhitespace(utf16CodeUnit: utf16[end])
            {
                end = utf16.index(after: end)
            }
            let tokenEnd = utf16.distance(from: utf16.startIndex, to: end)
            let substr = String(decoding: text.utf16[pos ..< end], as: UTF16.self)
            tokens.append(Token(text: substr, startOffset: tokenStart, endOffset: tokenEnd))
            pos = end
        }
        return tokens
    }
}
