import Foundation

/// A transcript segment produced by `TranscriptTextFormatting.parse`,
/// consumed by the import write path (architecture §2.1).
///
/// Defined in DataStore so both the `Formatting` module (which produces
/// drafts) and the import write path (which consumes them) depend downward
/// onto it.
public struct TranscriptSegmentDraft: Sendable, Equatable {
    public let speakerID: Int
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let text: String

    public init(
        speakerID: Int,
        speakerLabel: String,
        startTime: TimeInterval,
        text: String
    ) {
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.text = text
    }
}
