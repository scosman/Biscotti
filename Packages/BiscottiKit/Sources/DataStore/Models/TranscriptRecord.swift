import Foundation
import SwiftData

// MARK: - TranscriptRecord

/// A versioned transcript: many per Meeting. Records the inputs that produced it
/// (method, vocabulary, mapped event) so staleness can be detected.
@Model public final class TranscriptRecord: @unchecked Sendable {
    public var id = UUID()
    public var createdAt = Date()

    // MARK: Inputs (drive staleness / "should re-transcribe")

    /// Opaque method id, e.g. "v1" -- bakes in STT model, diarization model + strategy,
    /// all default settings. The Transcription library owns the mapping id -> settings.
    public var transcriptionMethodId: String = ""
    /// Effective custom vocabulary at transcript time.
    public var vocabularyUsed: [String] = []
    /// The calendar event the recording was mapped to at transcription time.
    public var mappedEventIdentifier: String?

    // MARK: Outputs

    public var language: String = ""
    public var speakerCount: Int = 0

    @Relationship(deleteRule: .cascade)
    public var segments: [TranscriptSegmentRecord] = []

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcriptionMethodId: String,
        vocabularyUsed: [String] = [],
        mappedEventIdentifier: String? = nil,
        language: String,
        speakerCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcriptionMethodId = transcriptionMethodId
        self.vocabularyUsed = vocabularyUsed
        self.mappedEventIdentifier = mappedEventIdentifier
        self.language = language
        self.speakerCount = speakerCount
    }
}
