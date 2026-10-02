import DataStore
import Foundation
import os
import VoiceprintMatching

/// Result of running voiceprint evidence computation.
public struct VoiceprintEvidenceResult: Sendable {
    public let corpus: PreparedCorpus
    public let queryVectors: [Int: [Float]]
    public let invitees: Invitees
    public let matches: [Int: SpeakerMatch]
    public let block: String

    public init(
        corpus: PreparedCorpus,
        queryVectors: [Int: [Float]],
        invitees: Invitees,
        matches: [Int: SpeakerMatch],
        block: String
    ) {
        self.corpus = corpus
        self.queryVectors = queryVectors
        self.invitees = invitees
        self.matches = matches
        self.block = block
    }
}

private let logger = Logger(subsystem: "net.scosman.biscotti", category: "Voiceprints")

/// Connects DataStore voiceprints to the matcher and renders the LLM block.
public enum VoiceprintEvidence {
    /// Full computation — throws on store errors.
    public static func compute(
        store: DataStore,
        meetingID: UUID,
        transcript: TranscriptData,
        detail: MeetingDetailData,
        human: [Int: PersonData],
        config: VoiceprintConfig = .default,
        kind: VoiceprintKind? = nil
    ) async throws -> VoiceprintEvidenceResult {
        let effectiveKind = kind ?? config.kind

        let allSpeakers = Set(transcript.segments.compactMap(\.speakerID)).sorted()
        let unassigned = allSpeakers.filter { !human.keys.contains($0) }

        let query = try await store.voiceprintQuery(transcriptID: transcript.id, kind: effectiveKind)

        let (corpus, queryVectors) = try await loadCorpus(
            store: store, query: query, kind: effectiveKind, meetingID: meetingID
        )

        let invitees = buildInvitees(detail: detail)
        let unassignedVectors = queryVectors.filter { unassigned.contains($0.key) }

        let matcher = VoiceprintMatcher(config: config)
        let matches: [Int: SpeakerMatch] = await Task.detached(priority: .userInitiated) {
            matcher.match(query: unassignedVectors, corpus: corpus, invitees: invitees)
        }.value

        logResults(matches: matches, corpus: corpus, unassignedCount: unassigned.count)

        let speakersWithVector = Set(queryVectors.keys)
        let assignedPersonIDs = Set(human.values.map(\.id))
        let calendarInvitees = collectInviteePersonData(detail: detail)

        let block = VoiceprintReport.render(
            unassignedSpeakers: unassigned,
            speakersWithVector: speakersWithVector,
            matches: matches,
            history: corpus.history,
            people: corpus.people,
            invitees: calendarInvitees,
            assignedPersonIDs: assignedPersonIDs
        )

        return VoiceprintEvidenceResult(
            corpus: corpus,
            queryVectors: queryVectors,
            invitees: invitees,
            matches: matches,
            block: block
        )
    }

    /// Production entry point — never throws; logs and returns "" on failure.
    public static func block(
        store: DataStore,
        meetingID: UUID,
        transcript: TranscriptData,
        detail: MeetingDetailData,
        human: [Int: PersonData]
    ) async -> String {
        do {
            let result = try await compute(
                store: store, meetingID: meetingID,
                transcript: transcript, detail: detail, human: human
            )
            return result.block
        } catch {
            logger.error("Voiceprint evidence failed: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: - Private

    private static func loadCorpus(
        store: DataStore, query: VoiceprintQueryData?,
        kind: VoiceprintKind, meetingID: UUID
    ) async throws -> (PreparedCorpus, [Int: [Float]]) {
        guard let space = query?.space else {
            let emptyData = VoiceprintCorpusData(
                kind: kind, space: "", entries: [], people: [:]
            )
            return (PreparedCorpus(emptyData), [:])
        }
        let corpusData = try await store.voiceprintCorpus(
            kind: kind, space: space, excludingMeetingID: meetingID
        )
        let corpus = await Task.detached(priority: .userInitiated) {
            PreparedCorpus(corpusData)
        }.value
        return (corpus, query?.vectors ?? [:])
    }

    private static func logResults(
        matches: [Int: SpeakerMatch],
        corpus: PreparedCorpus,
        unassignedCount: Int
    ) {
        let corpusSize = corpus.entryCount
        let meetingCount = corpus.history.meetingCount
        logger.debug(
            "Voiceprint evidence: corpus=\(corpusSize) entries, \(meetingCount) meetings; \(unassignedCount) unassigned speakers"
        )
        for (speakerID, match) in matches.sorted(by: { $0.key < $1.key }) {
            let levelStr = match.level.rawValue
            logger.debug("  Speaker \(speakerID): \(levelStr)")
        }
    }

    private static func buildInvitees(detail: MeetingDetailData) -> Invitees {
        guard let calendar = detail.calendar else { return .none }
        var personIDs = Set<UUID>()
        var emails = Set<String>()

        if let organizer = calendar.organizer {
            personIDs.insert(organizer.id)
            if let email = organizer.email {
                emails.insert(email.lowercased())
            }
        }
        for attendee in calendar.attendees {
            personIDs.insert(attendee.id)
            if let email = attendee.email {
                emails.insert(email.lowercased())
            }
        }
        return Invitees(personIDs: personIDs, emails: emails)
    }

    private static func collectInviteePersonData(detail: MeetingDetailData) -> [PersonData] {
        guard let calendar = detail.calendar else { return [] }
        var result: [PersonData] = []
        let organizerID = calendar.organizer?.id

        if let organizer = calendar.organizer {
            result.append(organizer)
        }
        for attendee in calendar.attendees where attendee.id != organizerID {
            result.append(attendee)
        }
        return result
    }
}
