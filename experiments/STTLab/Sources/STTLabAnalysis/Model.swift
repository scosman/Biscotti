import Foundation

/// Identifies which engine produced a transcript.
public enum EngineID: String, Codable, Sendable, CaseIterable {
    case apple
    case whisper
    case reference
}

/// A single word extracted from an engine's output, with optional timing and confidence.
public struct EngineWord: Codable, Sendable, Equatable {
    /// Display text, with punctuation, no leading/trailing space.
    public var text: String
    /// Start time in seconds on the merged-audio timeline.
    public var start: Double?
    /// End time in seconds on the merged-audio timeline.
    public var end: Double?
    /// Confidence score (engine-specific).
    public var confidence: Double?
    /// Apple result index / Whisper segment / reference segment or chunk.
    public var segmentIndex: Int

    public init(text: String, start: Double? = nil, end: Double? = nil,
                confidence: Double? = nil, segmentIndex: Int) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.segmentIndex = segmentIndex
    }
}

/// A normalized transcript for one engine, built from the engine's raw output.
public struct EngineTranscript: Codable, Sendable {
    public var engine: EngineID
    public var words: [EngineWord]
    /// Engine's display text: Apple = results' text joined with " ";
    /// Whisper = words joined; reference = chunk text joined with " ".
    public var displayText: String
    /// False when the reference returned no word-level times.
    public var hasWordTimes: Bool

    public init(engine: EngineID, words: [EngineWord], displayText: String,
                hasWordTimes: Bool = true) {
        self.engine = engine
        self.words = words
        self.displayText = displayText
        self.hasWordTimes = hasWordTimes
    }
}

/// A word with an optional speaker label assigned by diarization alignment.
public struct AlignedWord: Codable, Sendable {
    public var word: EngineWord
    public var speaker: Int?

    public init(word: EngineWord, speaker: Int? = nil) {
        self.word = word
        self.speaker = speaker
    }
}

/// A segment after speaker alignment (contiguous words from the same speaker).
public struct AlignedSegment: Codable, Sendable {
    public var speaker: Int?
    public var start: Double
    public var end: Double
    public var text: String
    public var wordCount: Int

    public init(speaker: Int? = nil, start: Double, end: Double, text: String, wordCount: Int) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.wordCount = wordCount
    }
}

/// The result of speaker-aligning an engine transcript against a diarization.
public struct AlignedTranscript: Codable, Sendable {
    public var engine: EngineID
    public var segments: [AlignedSegment]
    public var words: [AlignedWord]
    /// Words that had no timing and were dropped before alignment.
    public var droppedUntimedWords: Int

    public init(engine: EngineID, segments: [AlignedSegment], words: [AlignedWord],
                droppedUntimedWords: Int = 0) {
        self.engine = engine
        self.segments = segments
        self.words = words
        self.droppedUntimedWords = droppedUntimedWords
    }
}
