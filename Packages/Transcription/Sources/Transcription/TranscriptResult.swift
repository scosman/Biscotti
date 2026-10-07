import Foundation

// MARK: - TranscriptWord

/// A word within a transcript segment, with timing and optional speaker attribution.
public struct TranscriptWord: Sendable, Codable, Equatable {
    /// The word text.
    public let word: String

    /// Start time in seconds from audio start.
    public let startTime: TimeInterval

    /// End time in seconds from audio start.
    public let endTime: TimeInterval

    /// Whisper's probability for this word (0.0-1.0).
    public let probability: Float

    /// Speaker cluster ID from diarization, if available.
    public let speakerID: Int?

    public init(
        word: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        probability: Float,
        speakerID: Int?
    ) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.probability = probability
        self.speakerID = speakerID
    }
}

// MARK: - TranscriptSegment

/// A segment of the transcript with speaker attribution and timing.
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID

    /// Speaker cluster ID (0-based). Nil if no speaker could be determined.
    public let speakerID: Int?

    /// Human-readable speaker label (e.g. "Speaker 0", "Unknown").
    public let speakerLabel: String

    /// Start time in seconds from audio start.
    public let startTime: TimeInterval

    /// End time in seconds from audio start.
    public let endTime: TimeInterval

    /// The transcribed text for this segment.
    public let text: String

    /// Average log-probability from Whisper (higher is more confident).
    /// Note: segment-level confidence from the SDK is unreliable (often 0);
    /// use word-level probabilities for confidence assessment instead.
    public let confidence: Float

    /// Whisper's no-speech probability for this segment.
    public let noSpeechProbability: Float

    /// Word-level detail, if word timestamps were enabled.
    public let words: [TranscriptWord]?

    public init(
        id: UUID = UUID(),
        speakerID: Int?,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Float,
        noSpeechProbability: Float,
        words: [TranscriptWord]?
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.noSpeechProbability = noSpeechProbability
        self.words = words
    }
}

// MARK: - Embedding Types

/// The kind of speaker centroid vector.
public enum EmbeddingKind: String, Sendable, Codable, CaseIterable {
    /// Raw embedder output (256-dim for pyannote-v3).
    case raw
}

/// One kind of per-speaker centroid vectors from one diarization run.
public struct SpeakerEmbeddingSet: Sendable, Codable, Equatable {
    /// Which projection produced these vectors.
    public let kind: EmbeddingKind

    /// Embedding space key; see ``SpeakerEmbeddingSpace``.
    public let space: String

    /// Raw (not normalized) vectors by diarization speaker ID.
    /// Speakers can be absent (e.g. under `.trainableOnly` centroid source).
    public let vectors: [Int: [Float]]

    public init(kind: EmbeddingKind, space: String, vectors: [Int: [Float]]) {
        self.kind = kind
        self.space = space
        self.vectors = vectors
    }
}

// MARK: - TranscriptResult

/// The complete result of processing an audio file through STT + diarization.
public struct TranscriptResult: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID

    /// When this transcript was created.
    public let createdAt: Date

    /// Opaque transcription method identifier (e.g. "v1").
    /// Records which method produced this result, enabling re-transcribe
    /// with the same or a newer method.
    public let transcriptionMethodId: String

    /// Detected language code (e.g. "en").
    public let language: String

    /// Number of distinct speakers detected by diarization.
    public let speakerCount: Int

    /// Ordered transcript segments with speaker attribution.
    public let segments: [TranscriptSegment]

    /// Centroid embedding sets from diarization. Each set contains vectors
    /// keyed by diarization speaker ID. Empty when diarization produced no
    /// centroids.
    public let embeddingSets: [SpeakerEmbeddingSet]

    /// Sum of each diarization speaker's time ranges, in seconds.
    public let speakerSpeechDurations: [Int: TimeInterval]

    /// Wall-clock time spent processing (STT + diarization + merging).
    public let processingDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcriptionMethodId: String,
        language: String,
        speakerCount: Int,
        segments: [TranscriptSegment],
        embeddingSets: [SpeakerEmbeddingSet] = [],
        speakerSpeechDurations: [Int: TimeInterval] = [:],
        processingDuration: TimeInterval
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcriptionMethodId = transcriptionMethodId
        self.language = language
        self.speakerCount = speakerCount
        self.segments = segments
        self.embeddingSets = embeddingSets
        self.speakerSpeechDurations = speakerSpeechDurations
        self.processingDuration = processingDuration
    }
}
