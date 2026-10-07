import Foundation
import SwiftData

// MARK: - VoiceprintKind

/// DataStore's own copy of the embedding kind, so read models do not expose
/// Transcription types. Mirrors `EmbeddingKind` in the Transcription package.
public enum VoiceprintKind: String, Sendable, Codable, CaseIterable {
    /// Raw embedder output (256-dim for pyannote-v3).
    case raw
}

// MARK: - Voiceprint

/// One speaker's voiceprint of one kind, from one transcript. Does NOT store a
/// person: identity is resolved at read time from the owning transcript's
/// `speakerAssignments[speakerID]` (functional spec §3.2).
@Model public final class Voiceprint {
    public var id = UUID()
    public var createdAt = Date()

    /// The diarization speaker ID within the owning transcript.
    public var speakerID: Int = 0

    /// `VoiceprintKind.rawValue` ("raw").
    public var kindRaw: String = VoiceprintKind.raw.rawValue

    /// Identifies the SpeakerKit models that produced this vector.
    /// Voiceprints from different spaces cannot be compared.
    public var embeddingSpace: String = ""

    /// Number of Float32 values in the vector.
    public var dimension: Int = 0

    /// Raw (not normalized) vector, little-endian Float32. `Data`, not `[Float]`:
    /// SwiftData cannot materialize collections from on-disk stores in SPM modules.
    public var vectorData = Data()

    /// Sum of the speaker's diarization time ranges, in seconds.
    public var speakingDuration: Double = 0

    /// The transcript that owns this voiceprint. Cascade-deleted with the transcript.
    public var transcript: TranscriptRecord?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        speakerID: Int,
        kind: VoiceprintKind,
        embeddingSpace: String,
        vector: [Float],
        speakingDuration: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.speakerID = speakerID
        kindRaw = kind.rawValue
        self.embeddingSpace = embeddingSpace
        dimension = vector.count
        vectorData = VectorCoding.encode(vector)
        self.speakingDuration = speakingDuration
    }
}
