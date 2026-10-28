import Foundation

/// One word of a decode, with absolute times on the recording timeline.
///
/// `text` is spelled as the decoder produced it, including any leading space
/// that separates it from the previous word, so rows concatenate words verbatim.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var probability: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, probability: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

extension TimedWord {
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "\u{3002}", "\u{FF1F}", "\u{FF01}"]
    private static let closers: Set<Character> = ["\"", "'", ")", "\u{201D}", "\u{2019}"]

    /// True when the word ends a sentence, after any closing quote or bracket.
    var endsSentence: Bool {
        let trimmed = text.reversed().drop { $0.isWhitespace || Self.closers.contains($0) }
        return trimmed.first.map(Self.sentenceEnders.contains) ?? false
    }
}

/// One decode of a track's retained audio, `windowStart ..< windowEnd`.
public struct Hypothesis: Sendable, Equatable {
    public var words: [TimedWord]
    public var windowStart: TimeInterval
    public var windowEnd: TimeInterval

    public init(words: [TimedWord], windowStart: TimeInterval, windowEnd: TimeInterval) {
        self.words = words
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    var retainedDuration: TimeInterval {
        windowEnd - windowStart
    }
}

/// What one decode changed.
public struct AgreementResult: Sendable, Equatable {
    /// Rows created or changed by this decode, in time order.
    public var rows: [LiveRow]
    /// Audio before this time is final; the session may drop it from the next window.
    public var trimPoint: TimeInterval?

    public init(rows: [LiveRow], trimPoint: TimeInterval?) {
        self.rows = rows
        self.trimPoint = trimPoint
    }
}

/// Turns repeated decodes of one growing audio window into append-only rows.
///
/// LocalAgreement-2 from Whisper-Streaming (arXiv:2307.14743): a word settles
/// once two consecutive decodes agree on it. Matching also compares times, so a
/// phrase the speaker repeats is kept rather than merged. A pure value with no
/// clock and no audio; the session owns scheduling and trimming.
public struct LocalAgreementReducer: Sendable {
    static let committedDropMargin: TimeInterval = 0.05
    static let duplicateStartTolerance: TimeInterval = 0.2
    static let agreementStartTolerance: TimeInterval = 0.5
    static let trimAnyWordAfter: TimeInterval = 25
    /// A window this long with no agreement commits its early words anyway.
    public static let forcedBoundaryWindow: TimeInterval = 30
    static let forcedBoundaryHoldBack: TimeInterval = 5
    /// Committed words this far before the window start can no longer overlap a decode.
    static let committedRetention: TimeInterval = 1
    /// The most settled text a decode is prompted with.
    private static let promptCharacterLimit = 100

    public let track: LiveTrack
    /// The end of the latest decoded window or resolved silence.
    public private(set) var transcribedThrough: TimeInterval
    /// Audio before this time can no longer change. Never decreases.
    public private(set) var settledThrough: TimeInterval

    /// Committed words that a later decode may still repeat.
    private var recentCommitted: [Token] = []
    /// Committed words for `settledText(before:)`: those inside the latest
    /// window, plus enough earlier ones for the prompt.
    private var promptWords: [TimedWord] = []
    private var committedEnd: TimeInterval
    /// The previous decode's uncommitted words: the hypothesis the next decode must agree with.
    private var tail: [Token] = []
    private var rows: LiveRowBuilder

    public init(track: LiveTrack, startTime: TimeInterval = 0) {
        self.track = track
        rows = LiveRowBuilder(track: track)
        transcribedThrough = startTime
        settledThrough = startTime
        committedEnd = startTime
    }

    public var hasTail: Bool {
        !tail.isEmpty
    }

    /// Where this track last started speaking after a pause: the start of the
    /// newest word, settled or not, that follows a pause of 1.5 s, or of its
    /// first word.
    public var latestSpeechStart: TimeInterval? {
        rows.latestSpeechStart
    }

    // MARK: - Conversation order

    /// The other track started speaking at `time`: this track's row that
    /// began before it takes no word from `time` on, so the next words start
    /// a row that follows the other side's in start-time order.
    /// - Returns: The rows this changed, for example tail words that moved to
    ///   their own row.
    public mutating func breakRow(at time: TimeInterval) -> [LiveRow] {
        let before = rows.currentRows
        rows.breakRow(at: time)
        return rows.takeChanges(since: before)
    }

    // MARK: - Decodes

    /// - Parameter heldBackFrom: The start of a word the caller left out of
    ///   `hypothesis` because it may still change. `settledThrough` stays
    ///   before it, since the word is not settled yet.
    public mutating func reduce(_ hypothesis: Hypothesis, heldBackFrom: TimeInterval? = nil) -> AgreementResult {
        let before = rows.currentRows
        recentCommitted.removeAll { $0.word.end < hypothesis.windowStart - Self.committedRetention }
        transcribedThrough = max(transcribedThrough, hypothesis.windowEnd)

        let candidates = hypothesis.words
            .map(Token.init)
            .filter { $0.word.end > committedEnd - Self.committedDropMargin && !isDuplicateOfCommitted($0) }
        var agreed = agreementLength(with: candidates)

        var forcedTrimPoint: TimeInterval?
        if agreed == 0, hypothesis.retainedDuration >= Self.forcedBoundaryWindow {
            let cut = hypothesis.windowEnd - Self.forcedBoundaryHoldBack
            agreed = candidates.prefix { $0.word.end < cut }.count
            forcedTrimPoint = candidates.prefix(agreed).last?.word.end ?? min(cut, candidates.first?.word.start ?? cut)
        }
        commit(candidates.prefix(agreed), forced: forcedTrimPoint != nil)
        prunePromptWords(windowStart: hypothesis.windowStart)
        tail = Array(candidates.dropFirst(agreed))
        rows.setTail(tail.map(\.word))

        let trimPoint = (forcedTrimPoint ?? sentenceTrimPoint(in: hypothesis)).flatMap { $0 > hypothesis.windowStart ? $0 : nil }
        let resolved = max(trimPoint ?? settledThrough, tail.isEmpty ? hypothesis.windowEnd : committedEnd)
        settledThrough = max(settledThrough, min(resolved, heldBackFrom ?? resolved))
        return AgreementResult(rows: rows.takeChanges(since: before), trimPoint: trimPoint)
    }

    /// Commits every tail word and closes the open row. Used at the end of
    /// input and at a discontinuity; the reducer accepts decodes afterward.
    public mutating func finish() -> [LiveRow] {
        let before = rows.currentRows
        commit(tail[...], forced: false)
        tail = []
        rows.closeOpenRow()
        rows.setTail([])
        settledThrough = max(settledThrough, transcribedThrough)
        return rows.takeChanges(since: before)
    }

    /// Commits words a catch-up decode kept straight into rows. A backlog is
    /// decoded once in long windows, so there is no second decode to agree
    /// with; any streaming tail is dropped. Words that end before the last
    /// committed word, or repeat one a window boundary decoded twice, are
    /// left out.
    public mutating func commitCatchUp(_ words: [TimedWord]) -> [LiveRow] {
        let before = rows.currentRows
        tail = []
        if let start = words.first?.start {
            // Only recent words can be decoded twice; the prompt keeps its length.
            recentCommitted.removeAll { $0.word.end < start - Self.committedRetention }
            prunePromptWords(windowStart: start)
        }
        let fresh = words.map(Token.init).filter { $0.word.end > committedEnd - Self.committedDropMargin && !isDuplicateOfCommitted($0) }
        commit(fresh[...], forced: false)
        rows.setTail([])
        transcribedThrough = max(transcribedThrough, committedEnd)
        return rows.takeChanges(since: before)
    }

    /// Records that audio through `time` has been decoded, without settling it.
    public mutating func noteDecoded(through time: TimeInterval) {
        transcribedThrough = max(transcribedThrough, time)
    }

    /// Records audio through `time` that held no speech, or that a recorded gap covers.
    /// With a tail pending, only `transcribedThrough` moves: the tail is still unresolved.
    public mutating func resolveSilence(through time: TimeInterval) {
        transcribedThrough = max(transcribedThrough, time)
        if tail.isEmpty {
            settledThrough = max(settledThrough, time)
        }
    }

    // MARK: - Prompt context

    /// At most the last 100 characters of settled text whose words end by
    /// `time`, in whole words, for prompting the next decode of a window that
    /// starts at `time`. As in Whisper-Streaming, text whose audio is still in
    /// the window is left out: the decoder hears it again.
    public func settledText(before time: TimeInterval) -> String {
        // Whole words, newest first, so text written without spaces is cut at a word too.
        var kept: [String] = []
        var characters = 0
        for word in promptWords.prefix(while: { $0.end <= time + Self.committedDropMargin }).reversed() {
            guard characters + word.text.count <= Self.promptCharacterLimit else { break }
            kept.append(word.text)
            characters += word.text.count
        }
        return kept.reversed().joined().trimmingCharacters(in: .whitespaces)
    }

    /// Keeps the words inside the window, which may leave it at a later trim,
    /// and the fewest earlier words that still give the prompt its full length.
    private mutating func prunePromptWords(windowStart: TimeInterval) {
        var keptFrom = promptWords.firstIndex { $0.end > windowStart + Self.committedDropMargin } ?? promptWords.count
        var characters = 0
        while keptFrom > 0, characters < Self.promptCharacterLimit {
            keptFrom -= 1
            characters += promptWords[keptFrom].text.count
        }
        promptWords.removeFirst(keptFrom)
    }

    // MARK: - Agreement

    private func isDuplicateOfCommitted(_ candidate: Token) -> Bool {
        recentCommitted.contains { committed in
            committed.key == candidate.key && Self.coverSameAudio(committed.word, candidate.word)
        }
    }

    /// Matching text alone is not enough: a speaker who repeats a word right
    /// after a committed one keeps both.
    private static func coverSameAudio(_ first: TimedWord, _ second: TimedWord) -> Bool {
        let overlap = min(first.end, second.end) - max(first.start, second.start)
        let shorter = min(first.end - first.start, second.end - second.start)
        return (overlap > 0 && overlap >= shorter / 2) || abs(first.start - second.start) <= duplicateStartTolerance
    }

    private func agreementLength(with candidates: [Token]) -> Int {
        zip(tail, candidates).prefix { previous, current in
            previous.key == current.key && abs(previous.word.start - current.word.start) <= Self.agreementStartTolerance
        }.count
    }

    private func sentenceTrimPoint(in hypothesis: Hypothesis) -> TimeInterval? {
        let inWindow = recentCommitted.filter { $0.word.end > hypothesis.windowStart }
        let trimWord = hypothesis.retainedDuration > Self.trimAnyWordAfter ? inWindow.last : inWindow.last { $0.endsSentence }
        return trimWord?.word.end
    }

    // MARK: - Committing

    private mutating func commit(_ words: ArraySlice<Token>, forced: Bool) {
        rows.settle(words.map(\.word), forced: forced)
        for token in words {
            recentCommitted.append(token)
            promptWords.append(token.word)
            committedEnd = max(committedEnd, token.word.end)
        }
    }

    // MARK: - Normalization

    /// Lowercased, punctuation and symbols removed except apostrophes,
    /// whitespace collapsed. Used only to compare words.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().compactMap { character -> Character? in
            if apostrophes.contains(character) { return "'" }
            return character.isLetter || character.isNumber || character.isWhitespace ? character : nil
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}"]
}

// MARK: - Internal state types

extension LocalAgreementReducer {
    struct Token: Equatable {
        var word: TimedWord
        var key: String

        init(_ word: TimedWord) {
            self.word = word
            key = LocalAgreementReducer.normalize(word.text)
        }

        var endsSentence: Bool {
            word.endsSentence
        }
    }
}
