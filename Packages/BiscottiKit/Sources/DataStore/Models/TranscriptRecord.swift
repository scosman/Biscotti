import Foundation
import SwiftData

// MARK: - SpeakerAssignmentEntry

/// Per-speaker assignment with provenance. `userSet` is `true` when a human
/// manually assigned this speaker (sheet dropdown / add-person / re-assign);
/// `false` when the LLM auto-run inferred it. Manual assignments are never
/// overwritten by a subsequent LLM run.
public struct SpeakerAssignmentEntry: Codable, Equatable, Sendable {
    public let personID: UUID
    public let userSet: Bool

    public init(personID: UUID, userSet: Bool) {
        self.personID = personID
        self.userSet = userSet
    }
}

// MARK: - TranscriptRecord

/// A versioned transcript: many per Meeting. Records the inputs that produced it
/// (method, vocabulary, mapped event) so staleness can be detected.
@Model public final class TranscriptRecord {
    public var id = UUID()
    public var createdAt = Date()

    // MARK: Inputs (drive staleness / "should re-transcribe")

    /// Opaque method id, e.g. "v1" -- bakes in STT model, diarization model + strategy,
    /// all default settings. The Transcription library owns the mapping id -> settings.
    public var transcriptionMethodId: String = ""
    /// JSON-encoded backing store for `vocabularyUsed`. SwiftData cannot materialize
    /// generic `Array<String>` from on-disk stores in SPM modules; `Data` works reliably.
    private var vocabularyUsedData = Data()

    /// Effective custom vocabulary at transcript time.
    @Transient public var vocabularyUsed: [String] {
        get { (try? JSONDecoder().decode([String].self, from: vocabularyUsedData)) ?? [] }
        set { vocabularyUsedData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// The calendar event the recording was mapped to at transcription time.
    public var mappedEventIdentifier: String?

    /// JSON-encoded backing store for `speakerAssignments`. Maps diarization
    /// speaker IDs to `SpeakerAssignmentEntry` (personID + provenance).
    /// Same Data-backed pattern as `vocabularyUsedData`.
    private var speakerAssignmentsData = Data()

    /// Test-only write access to the raw backing `Data` for
    /// `speakerAssignments`. Used to inject old-shape JSON and verify
    /// lenient decode. Not part of the public API.
    package func setSpeakerAssignmentsData_testOnly(_ data: Data) {
        speakerAssignmentsData = data
    }

    /// Diarization speaker ID -> assignment entry (personID + provenance).
    /// Empty = no assignments (all show "Speaker N"). Resets to empty on
    /// re-transcription. **Lenient decode:** the prior `[Int: UUID]` shape
    /// is treated as empty (the feature has no shipped data to migrate).
    @Transient public var speakerAssignments: [Int: SpeakerAssignmentEntry] {
        get {
            (try? JSONDecoder().decode(
                [Int: SpeakerAssignmentEntry].self, from: speakerAssignmentsData
            )) ?? [:]
        }
        set {
            speakerAssignmentsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

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
        vocabularyUsedData = (try? JSONEncoder().encode(vocabularyUsed)) ?? Data()
        self.mappedEventIdentifier = mappedEventIdentifier
        self.language = language
        self.speakerCount = speakerCount
    }
}
