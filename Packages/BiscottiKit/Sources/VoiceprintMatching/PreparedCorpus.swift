import DataStore
import Foundation

/// Per-person history summary within the corpus.
public struct PersonHistory: Sendable, Equatable {
    /// Distinct meetings tagged to this person.
    public let meetings: Int
    /// Distinct meetings where the tag was user-set.
    public let confirmedMeetings: Int

    public init(meetings: Int, confirmedMeetings: Int) {
        self.meetings = meetings
        self.confirmedMeetings = confirmedMeetings
    }
}

/// Aggregate history statistics for the corpus.
public struct HistoryStats: Sendable, Equatable {
    /// Distinct meetings in the corpus.
    public let meetingCount: Int
    /// Distinct meetings with at least one user-set tag.
    public let confirmedMeetingCount: Int
    /// Per-person history.
    public let perPerson: [UUID: PersonHistory]

    public init(meetingCount: Int, confirmedMeetingCount: Int, perPerson: [UUID: PersonHistory]) {
        self.meetingCount = meetingCount
        self.confirmedMeetingCount = confirmedMeetingCount
        self.perPerson = perPerson
    }
}

/// A normalized, ready-to-query corpus entry.
struct NormalizedEntry {
    let meetingID: UUID
    let meetingTitle: String
    let meetingDate: Date
    let speakerID: Int
    let vector: [Float]
    let speakingDuration: Double
    let tag: SpeakerTagData?
}

/// The voiceprint corpus with all vectors normalized and dimension-checked.
/// Entries that fail normalization or have a mismatched dimension are dropped.
public struct PreparedCorpus: Sendable {
    public let kind: VoiceprintKind
    public let space: String
    public let people: [UUID: PersonData]

    let entries: [NormalizedEntry]
    private let stats: HistoryStats

    /// Number of usable entries after normalization and dimension filtering.
    public var entryCount: Int {
        entries.count
    }

    /// Aggregate history stats, computed once during init.
    public var history: HistoryStats {
        stats
    }

    public init(_ corpus: VoiceprintCorpusData) {
        kind = corpus.kind
        space = corpus.space
        people = corpus.people

        // Determine the reference dimension from the first entry that normalizes.
        var referenceDimension: Int?
        var normalized: [NormalizedEntry] = []
        normalized.reserveCapacity(corpus.entries.count)

        for entry in corpus.entries {
            guard let vec = VectorMath.normalized(entry.vector) else { continue }
            if referenceDimension == nil {
                referenceDimension = vec.count
            } else if vec.count != referenceDimension {
                continue
            }
            normalized.append(NormalizedEntry(
                meetingID: entry.meetingID,
                meetingTitle: entry.meetingTitle,
                meetingDate: entry.meetingDate,
                speakerID: entry.speakerID,
                vector: vec,
                speakingDuration: entry.speakingDuration,
                tag: entry.tag
            ))
        }

        entries = normalized
        stats = Self.computeStats(entries)
    }

    /// Internal init for `excluding(meetingID:)`.
    private init(
        kind: VoiceprintKind, space: String,
        people: [UUID: PersonData], entries: [NormalizedEntry]
    ) {
        self.kind = kind
        self.space = space
        self.people = people
        self.entries = entries
        stats = Self.computeStats(entries)
    }

    /// Returns a copy with all entries from the given meeting removed.
    public func excluding(meetingID: UUID) -> PreparedCorpus {
        PreparedCorpus(
            kind: kind, space: space, people: people,
            entries: entries.filter { $0.meetingID != meetingID }
        )
    }

    private static func computeStats(_ entries: [NormalizedEntry]) -> HistoryStats {
        var meetingIDs: Set<UUID> = []
        var confirmedMeetingIDs: Set<UUID> = []
        // personID -> (set of meetingIDs, set of confirmed meetingIDs)
        var personMeetings: [UUID: Set<UUID>] = [:]
        var personConfirmedMeetings: [UUID: Set<UUID>] = [:]

        for entry in entries {
            meetingIDs.insert(entry.meetingID)
            if let tag = entry.tag, tag.userSet {
                confirmedMeetingIDs.insert(entry.meetingID)
            }
            if let tag = entry.tag {
                personMeetings[tag.personID, default: []].insert(entry.meetingID)
                if tag.userSet {
                    personConfirmedMeetings[tag.personID, default: []].insert(entry.meetingID)
                }
            }
        }

        var perPerson: [UUID: PersonHistory] = [:]
        for (personID, meetingSet) in personMeetings {
            perPerson[personID] = PersonHistory(
                meetings: meetingSet.count,
                confirmedMeetings: personConfirmedMeetings[personID, default: []].count
            )
        }

        return HistoryStats(
            meetingCount: meetingIDs.count,
            confirmedMeetingCount: confirmedMeetingIDs.count,
            perPerson: perPerson
        )
    }
}
