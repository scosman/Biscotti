import DataStore
import Foundation
import Transcription

/// A transcript rebuilt with known speakers. See
/// `TranscriptionService.refiner`.
public struct RefinedTranscript: Sendable {
    public let result: TranscriptResult
    /// Speaker ID in `result` -> person name.
    public let speakerNames: [Int: String]
    /// Speaker ID -> where that name came from and how sure it is.
    public let speakerProvenance: [Int: SpeakerNameProvenance]

    public init(
        result: TranscriptResult,
        speakerNames: [Int: String],
        speakerProvenance: [Int: SpeakerNameProvenance] = [:]
    ) {
        self.result = result
        self.speakerNames = speakerNames
        self.speakerProvenance = speakerProvenance
    }
}
