import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: "net.scosman.biscotti", category: "Voiceprints")

// MARK: - Read DTOs

/// Speaker tag provenance from a transcript's speaker assignments.
public struct SpeakerTagData: Sendable, Equatable {
    /// The person this speaker is tagged as.
    public let personID: UUID
    /// Whether the tag was set by a human (true) or inferred by the LLM (false).
    public let userSet: Bool

    public init(personID: UUID, userSet: Bool) {
        self.personID = personID
        self.userSet = userSet
    }
}

/// A single voiceprint entry with meeting context, decoded vector, and tag.
public struct VoiceprintData: Sendable, Equatable {
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingDate: Date
    public let transcriptID: UUID
    public let speakerID: Int
    /// Raw (not normalized) decoded vector.
    public let vector: [Float]
    public let speakingDuration: Double
    /// Nil when untagged or the tagged person no longer exists.
    public let tag: SpeakerTagData?

    public init(
        meetingID: UUID, meetingTitle: String, meetingDate: Date,
        transcriptID: UUID, speakerID: Int,
        vector: [Float], speakingDuration: Double,
        tag: SpeakerTagData?
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.transcriptID = transcriptID
        self.speakerID = speakerID
        self.vector = vector
        self.speakingDuration = speakingDuration
        self.tag = tag
    }
}

/// The full voiceprint corpus for one kind and space.
public struct VoiceprintCorpusData: Sendable, Equatable {
    public let kind: VoiceprintKind
    public let space: String
    public let entries: [VoiceprintData]
    /// Every person referenced by a tag in `entries`.
    public let people: [UUID: PersonData]

    public init(kind: VoiceprintKind, space: String, entries: [VoiceprintData], people: [UUID: PersonData]) {
        self.kind = kind
        self.space = space
        self.entries = entries
        self.people = people
    }
}

/// Voiceprint vectors for one transcript, used as the matcher's query.
public struct VoiceprintQueryData: Sendable, Equatable {
    /// Nil when the transcript has no voiceprints of this kind.
    public let space: String?
    /// Decoded vectors by diarization speaker ID.
    public let vectors: [Int: [Float]]
    /// Speaking durations by diarization speaker ID.
    public let speakingDurations: [Int: Double]

    public init(space: String?, vectors: [Int: [Float]], speakingDurations: [Int: Double]) {
        self.space = space
        self.vectors = vectors
        self.speakingDurations = speakingDurations
    }
}

// MARK: - Backfill DTOs

/// A voiceprint to be written by the backfill tool.
public struct NewVoiceprint: Sendable, Equatable {
    public let speakerID: Int
    public let vector: [Float]
    public let speakingDuration: Double

    public init(speakerID: Int, vector: [Float], speakingDuration: Double) {
        self.speakerID = speakerID
        self.vector = vector
        self.speakingDuration = speakingDuration
    }
}

/// A diarization span stored in a transcript segment.
public struct StoredSpanData: Sendable, Equatable {
    public let speakerID: Int
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// A meeting eligible for voiceprint backfill.
public struct BackfillCandidateData: Sendable, Equatable {
    public let meetingID: UUID
    public let title: String
    public let date: Date
    public let transcriptID: UUID
    /// Present mic audio file URL, or nil.
    public let micURL: URL?
    /// Present system audio file URL, or nil.
    public let systemURL: URL?
    /// Transcript segments that have a speaker ID, as time spans.
    public let segments: [StoredSpanData]

    public init(
        meetingID: UUID, title: String, date: Date, transcriptID: UUID,
        micURL: URL?, systemURL: URL?, segments: [StoredSpanData]
    ) {
        self.meetingID = meetingID
        self.title = title
        self.date = date
        self.transcriptID = transcriptID
        self.micURL = micURL
        self.systemURL = systemURL
        self.segments = segments
    }
}

// MARK: - Voiceprint Queries

public extension DataStore {
    /// Returns voiceprint vectors and durations for a single transcript,
    /// filtered by kind. Returns `nil` if the transcript does not exist.
    func voiceprintQuery(transcriptID: UUID, kind: VoiceprintKind) throws -> VoiceprintQueryData? {
        guard let record = try transcriptRecord(id: transcriptID) else { return nil }

        let kindStr = kind.rawValue
        let matching = record.voiceprints.filter { $0.kindRaw == kindStr }

        guard !matching.isEmpty else {
            return VoiceprintQueryData(space: nil, vectors: [:], speakingDurations: [:])
        }

        let space = matching.first?.embeddingSpace
        var vectors: [Int: [Float]] = [:]
        var durations: [Int: Double] = [:]

        for entry in matching {
            guard let decoded = VectorCoding.decode(entry.vectorData, dimension: entry.dimension) else {
                logger.debug("Skipping undecodable voiceprint \(entry.id) for speaker \(entry.speakerID)")
                continue
            }
            vectors[entry.speakerID] = decoded
            durations[entry.speakerID] = entry.speakingDuration
        }

        return VoiceprintQueryData(space: space, vectors: vectors, speakingDurations: durations)
    }

    /// Returns the full voiceprint corpus for a kind and space, optionally
    /// excluding one meeting. Only voiceprints from preferred transcripts
    /// are included.
    func voiceprintCorpus(
        kind: VoiceprintKind,
        space: String,
        excludingMeetingID: UUID?
    ) throws -> VoiceprintCorpusData {
        let kindStr = kind.rawValue

        // 1. Fetch all persons once.
        let allPersons = try context.fetch(FetchDescriptor<Person>())
        let personMap = Dictionary(uniqueKeysWithValues: allPersons.map { ($0.id, $0) })

        // 2. Fetch all meetings.
        let allMeetings = try context.fetch(FetchDescriptor<Meeting>())

        var entries: [VoiceprintData] = []
        var referencedPeople: [UUID: PersonData] = [:]

        for meeting in allMeetings {
            // Skip the excluded meeting
            if meeting.id == excludingMeetingID { continue }

            // Must have a preferred transcript
            guard let preferredID = meeting.preferredTranscriptID,
                  let record = meeting.transcripts.first(where: { $0.id == preferredID })
            else { continue }

            // Decode speaker assignments once per record
            let assignments = record.speakerAssignments
            let meetingDate = meeting.startDate ?? meeting.createdAt

            for entry in record.voiceprints {
                // Filter by kind and space
                guard entry.kindRaw == kindStr, entry.embeddingSpace == space else { continue }

                // Decode vector
                guard let decoded = VectorCoding.decode(entry.vectorData, dimension: entry.dimension) else {
                    logger.debug("Corpus: skipping undecodable voiceprint \(entry.id)")
                    continue
                }

                // Resolve tag
                let tag: SpeakerTagData?
                if let assignment = assignments[entry.speakerID],
                   personMap[assignment.personID] != nil
                {
                    tag = SpeakerTagData(personID: assignment.personID, userSet: assignment.userSet)
                    // Track referenced person
                    if referencedPeople[assignment.personID] == nil,
                       let person = personMap[assignment.personID]
                    {
                        referencedPeople[assignment.personID] = PersonData(
                            id: person.id, name: person.name, email: person.email
                        )
                    }
                } else {
                    tag = nil
                }

                entries.append(VoiceprintData(
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    meetingDate: meetingDate,
                    transcriptID: record.id,
                    speakerID: entry.speakerID,
                    vector: decoded,
                    speakingDuration: entry.speakingDuration,
                    tag: tag
                ))
            }
        }

        return VoiceprintCorpusData(
            kind: kind, space: space,
            entries: entries, people: referencedPeople
        )
    }
}

// MARK: - Backfill Operations

public extension DataStore {
    /// Writes voiceprint records for a transcript (used by the backfill tool).
    func addVoiceprints(
        _ items: [NewVoiceprint],
        kind: VoiceprintKind,
        space: String,
        to transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        for item in items {
            guard !item.vector.isEmpty, item.vector.allSatisfy(\.isFinite) else {
                logger.warning("Backfill: skipping non-finite/empty vector for speaker \(item.speakerID)")
                continue
            }
            let voiceprint = Voiceprint(
                speakerID: item.speakerID,
                kind: kind,
                embeddingSpace: space,
                vector: item.vector,
                speakingDuration: item.speakingDuration
            )
            context.insert(voiceprint)
            record.voiceprints.append(voiceprint)
        }
        try save()
    }

    /// Returns whether a transcript already has voiceprints of the given kind and space.
    func hasVoiceprints(transcriptID: UUID, kind: VoiceprintKind, space: String) throws -> Bool {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        let kindStr = kind.rawValue
        return record.voiceprints.contains { $0.kindRaw == kindStr && $0.embeddingSpace == space }
    }

    /// Returns meetings with a preferred transcript, oldest first, for backfill.
    func backfillCandidates() throws -> [BackfillCandidateData] {
        let allMeetings = try context.fetch(FetchDescriptor<Meeting>())

        var candidates: [BackfillCandidateData] = []

        for meeting in allMeetings {
            guard let preferredID = meeting.preferredTranscriptID,
                  let record = meeting.transcripts.first(where: { $0.id == preferredID })
            else { continue }

            let micRef = meeting.audioFiles.first(where: { $0.role == .mic && $0.isPresent })
            let systemRef = meeting.audioFiles.first(where: { $0.role == .system && $0.isPresent })
            let micURL = micRef.map { URL(fileURLWithPath: $0.path) }
            let systemURL = systemRef.map { URL(fileURLWithPath: $0.path) }

            let sortedSegments = record.segments.sorted { $0.index < $1.index }
            let spans: [StoredSpanData] = sortedSegments.compactMap { seg in
                guard let speakerID = seg.speakerID else { return nil }
                return StoredSpanData(
                    speakerID: speakerID,
                    start: seg.startTime,
                    end: seg.endTime
                )
            }

            candidates.append(BackfillCandidateData(
                meetingID: meeting.id,
                title: meeting.title,
                date: meeting.startDate ?? meeting.createdAt,
                transcriptID: record.id,
                micURL: micURL,
                systemURL: systemURL,
                segments: spans
            ))
        }

        // Oldest first
        candidates.sort { $0.date < $1.date }
        return candidates
    }
}

// MARK: - Test Helpers

public extension DataStore {
    /// Fetches all `Voiceprint` rows in the store (for verification in tests).
    func fetchAllVoiceprints() throws -> [Voiceprint] {
        try context.fetch(FetchDescriptor<Voiceprint>())
    }

    /// Deletes a person by ID (for test cleanup only). Does not cascade-check
    /// meeting relationships — callers should not rely on referential integrity
    /// after calling this.
    func deletePerson(id personID: UUID) throws {
        guard let person = try fetchPerson(id: personID) else { return }
        context.delete(person)
        try save()
    }
}
