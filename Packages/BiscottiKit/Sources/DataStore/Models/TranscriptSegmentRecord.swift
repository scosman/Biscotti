import Foundation
import SwiftData

// MARK: - TranscriptSegmentRecord

/// A modeled SwiftData entity for a transcript segment -- queryable and relational,
/// not a JSON blob. `index` gives stable ordering (SwiftData relationships are unordered).
@Model public final class TranscriptSegmentRecord {
    public var id = UUID()
    /// Stable ordering within the transcript.
    public var index: Int = 0
    /// Diarization cluster id (nil = no match).
    public var speakerID: Int?
    /// Human-readable label, e.g. "Speaker 0", "Unknown".
    public var speakerLabel: String = ""
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 0
    public var text: String = ""
    public var noSpeechProbability: Float = 0

    @Relationship(deleteRule: .cascade)
    public var words: [TranscriptWordRecord] = []

    public init(
        id: UUID = UUID(),
        index: Int,
        speakerID: Int? = nil,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        noSpeechProbability: Float
    ) {
        self.id = id
        self.index = index
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.noSpeechProbability = noSpeechProbability
    }
}
