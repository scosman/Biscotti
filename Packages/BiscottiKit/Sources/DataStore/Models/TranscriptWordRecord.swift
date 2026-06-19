import Foundation
import SwiftData

// MARK: - TranscriptWordRecord

/// Word-level detail within a segment. `index` gives stable ordering.
@Model public final class TranscriptWordRecord {
    public var id = UUID()
    /// Stable ordering within the segment.
    public var index: Int = 0
    public var word: String = ""
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 0
    /// The reliable per-word confidence from Whisper (0.0-1.0).
    public var probability: Float = 0
    /// Speaker cluster ID from diarization, if available.
    public var speakerID: Int?

    public init(
        id: UUID = UUID(),
        index: Int,
        word: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        probability: Float,
        speakerID: Int? = nil
    ) {
        self.id = id
        self.index = index
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.probability = probability
        self.speakerID = speakerID
    }
}
