import Foundation

// MARK: - Configuration

/// Strategy for merging diarization speaker labels with transcription segments.
public enum DiarizationStrategy: String, Sendable, Codable, CaseIterable {
    /// Split transcription segments at word gaps and assign speakers to sub-segments.
    /// More granular; handles mid-segment speaker changes.
    case subsegment

    /// Assign one speaker to each full transcription segment.
    /// Simpler; works well when segments already correspond to single speakers.
    case segment
}

/// Configuration for the ArgMax speech processing pipeline.
public struct ProcessorConfig: Sendable, Codable, Equatable {
    /// WhisperKit model variant (e.g. "large-v3_turbo", "large-v3_turbo_1307MB").
    public let sttModel: String

    /// HuggingFace repo containing WhisperKit CoreML models.
    public let sttModelRepo: String

    /// Whether to include word-level timestamps in the transcription.
    public let enableWordTimestamps: Bool

    /// Strategy for merging diarization results with transcription.
    public let diarizationStrategy: DiarizationStrategy

    /// Load and unload STT and diarization models sequentially to reduce peak memory.
    /// Recommended for 8 GB Macs.
    public let sequentialLoading: Bool

    public init(
        sttModel: String = "large-v3_turbo",
        sttModelRepo: String = "argmaxinc/whisperkit-coreml",
        enableWordTimestamps: Bool = true,
        diarizationStrategy: DiarizationStrategy = .subsegment,
        sequentialLoading: Bool = false
    ) {
        self.sttModel = sttModel
        self.sttModelRepo = sttModelRepo
        self.enableWordTimestamps = enableWordTimestamps
        self.diarizationStrategy = diarizationStrategy
        self.sequentialLoading = sequentialLoading
    }

    public static let `default` = ProcessorConfig()
}

// MARK: - Transcript Output

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

/// The complete result of processing an audio file through STT + diarization.
public struct TranscriptResult: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID

    /// When this transcript was created.
    public let createdAt: Date

    /// WhisperKit model variant used (e.g. "large-v3_turbo").
    public let modelVersion: String

    /// Detected language code (e.g. "en").
    public let language: String

    /// Number of distinct speakers detected by diarization.
    public let speakerCount: Int

    /// Ordered transcript segments with speaker attribution.
    public let segments: [TranscriptSegment]

    /// Centroid embedding vectors per speaker ID, for cross-file speaker matching.
    /// Key is the speaker cluster ID; value is the embedding vector.
    public let speakerEmbeddings: [Int: [Float]]

    /// Wall-clock time spent processing (STT + diarization + merging).
    public let processingDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        modelVersion: String,
        language: String,
        speakerCount: Int,
        segments: [TranscriptSegment],
        speakerEmbeddings: [Int: [Float]],
        processingDuration: TimeInterval
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modelVersion = modelVersion
        self.language = language
        self.speakerCount = speakerCount
        self.segments = segments
        self.speakerEmbeddings = speakerEmbeddings
        self.processingDuration = processingDuration
    }
}
