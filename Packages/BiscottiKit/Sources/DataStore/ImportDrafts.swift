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

/// One importable meeting, as produced by the CSV scanner's single pass
/// over the file (architecture §2.1). Consumed by
/// `DataStore.insertImportedMeetings(_:batchID:)`.
public struct ImportedMeetingDraft: Sendable, Equatable {
    /// Parsed UUID from the row's `id`, or a freshly minted one when the
    /// raw string was not a UUID.
    public let meetingID: UUID
    /// The raw `id` string when it was not a UUID; `nil` otherwise.
    public let externalID: String?
    public let title: String
    public let created: Date
    public let summary: String
    public let notes: String
    /// Empty means "no transcript record" — the row's transcript column
    /// was blank or parsed to zero segments.
    public let transcript: [TranscriptSegmentDraft]

    public init(
        meetingID: UUID,
        externalID: String? = nil,
        title: String,
        created: Date,
        summary: String = "",
        notes: String = "",
        transcript: [TranscriptSegmentDraft] = []
    ) {
        self.meetingID = meetingID
        self.externalID = externalID
        self.title = title
        self.created = created
        self.summary = summary
        self.notes = notes
        self.transcript = transcript
    }
}

/// Everything already in the database that an import must not duplicate
/// (functional spec §2.4). Handed to the scanner so it stays store-free.
public struct ExistingMeetingIdentity: Sendable, Equatable {
    public let meetingIDs: Set<UUID>
    public let externalIDs: Set<String>

    public init(meetingIDs: Set<UUID> = [], externalIDs: Set<String> = []) {
        self.meetingIDs = meetingIDs
        self.externalIDs = externalIDs
    }
}

/// Everything the CSV exporter needs for one meeting (architecture §2.2).
public struct MeetingExportData: Sendable, Equatable {
    public let id: UUID
    public let title: String
    /// The meeting's effective date: `startDate ?? createdAt`.
    public let date: Date
    public let summary: String
    public let notes: String
    /// Segments of the preferred transcript in index order; empty when the
    /// meeting has no transcript.
    public let segments: [SegmentData]
    /// Resolved person names by diarization speaker ID, from the preferred
    /// transcript's speaker assignments.
    public let speakerNames: [Int: String]

    public init(
        id: UUID,
        title: String,
        date: Date,
        summary: String = "",
        notes: String = "",
        segments: [SegmentData] = [],
        speakerNames: [Int: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.summary = summary
        self.notes = notes
        self.segments = segments
        self.speakerNames = speakerNames
    }
}
