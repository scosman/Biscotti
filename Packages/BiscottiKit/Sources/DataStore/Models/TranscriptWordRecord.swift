import Foundation
import SwiftData

// MARK: - TranscriptWordRecord

/// Word-level detail within a segment. `index` gives stable ordering.
@Model public final class TranscriptWordRecord: @unchecked Sendable {
    #Unique<TranscriptWordRecord>([\.id])

    public var id: UUID
    /// Stable ordering within the segment.
    public var index: Int
    public var word: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// The reliable per-word confidence from Whisper (0.0-1.0).
    public var probability: Float
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
