import DataStore
import Foundation

/// Confidence level for a speaker-to-person match.
/// `CodingKeyRepresentable` so `[MatchLevel: ...]` encodes as a JSON object.
public enum MatchLevel: String, Sendable, Codable, CodingKeyRepresentable {
    case high, medium, low, ambiguous, none
}

/// A candidate person for a speaker match.
public struct PersonCandidate: Sendable, Equatable {
    public let personID: UUID
    public let score: Float
    public let reportedDistance: Float
    public let countedMeetings: Int
    public let confirmedCountedMeetings: Int
    public let isInvitee: Bool

    public init(
        personID: UUID, score: Float, reportedDistance: Float,
        countedMeetings: Int, confirmedCountedMeetings: Int, isInvitee: Bool
    ) {
        self.personID = personID
        self.score = score
        self.reportedDistance = reportedDistance
        self.countedMeetings = countedMeetings
        self.confirmedCountedMeetings = confirmedCountedMeetings
        self.isInvitee = isInvitee
    }
}

/// The match result for one speaker.
public struct SpeakerMatch: Sendable, Equatable {
    public let speakerID: Int
    public let level: MatchLevel
    /// Best candidate(s). One for high/medium/low; 2...maxAmbiguousCandidates for ambiguous; empty for none.
    public let candidates: [PersonCandidate]
    /// Distinct meetings with an untagged voiceprint inside R.
    public let unnamedMeetingCount: Int

    public init(speakerID: Int, level: MatchLevel, candidates: [PersonCandidate], unnamedMeetingCount: Int) {
        self.speakerID = speakerID
        self.level = level
        self.candidates = candidates
        self.unnamedMeetingCount = unnamedMeetingCount
    }
}

/// Calendar invitees for the current meeting.
public struct Invitees: Sendable, Equatable {
    public let personIDs: Set<UUID>
    /// Lowercased email addresses.
    public let emails: Set<String>

    public static let none = Invitees(personIDs: [], emails: [])

    public init(personIDs: Set<UUID>, emails: Set<String>) {
        self.personIDs = personIDs
        self.emails = emails
    }
}

/// Debug detail for one speaker (debug window).
public struct SpeakerExplanation: Sendable, Equatable {
    public let match: SpeakerMatch
    /// Every person with score > 0, ranked.
    public let allCandidates: [PersonCandidate]
    /// Closest N voiceprints regardless of R.
    public let nearest: [NearestVoiceprint]

    public init(match: SpeakerMatch, allCandidates: [PersonCandidate], nearest: [NearestVoiceprint]) {
        self.match = match
        self.allCandidates = allCandidates
        self.nearest = nearest
    }
}

/// One of the nearest voiceprints to a query vector.
public struct NearestVoiceprint: Sendable, Equatable {
    public let meetingTitle: String
    public let meetingDate: Date
    public let speakerID: Int
    public let tag: SpeakerTagData?
    public let distance: Float
    public let insideRadius: Bool
    public let speakingDuration: Double

    public init(
        meetingTitle: String, meetingDate: Date, speakerID: Int,
        tag: SpeakerTagData?, distance: Float, insideRadius: Bool,
        speakingDuration: Double
    ) {
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.speakerID = speakerID
        self.tag = tag
        self.distance = distance
        self.insideRadius = insideRadius
        self.speakingDuration = speakingDuration
    }
}

// MARK: - VoiceprintMatcher

/// Matches speaker voiceprints against a prepared corpus.
/// Synchronous and pure; callers run it off the main actor.
public struct VoiceprintMatcher: Sendable {
    private let config: VoiceprintConfig

    public init(config: VoiceprintConfig = .default) {
        self.config = config
    }

    /// Matches each query speaker against the corpus.
    /// A vector that fails normalization or dimension check results in `.none`.
    public func match(
        query: [Int: [Float]],
        corpus: PreparedCorpus,
        invitees: Invitees
    ) -> [Int: SpeakerMatch] {
        let limits = config.thresholds(for: corpus.kind)
        let referenceDim = corpus.entries.first?.vector.count

        var results: [Int: SpeakerMatch] = [:]
        for (speakerID, rawVec) in query {
            guard let qVec = VectorMath.normalized(rawVec),
                  referenceDim == nil || qVec.count == referenceDim
            else {
                results[speakerID] = SpeakerMatch(
                    speakerID: speakerID, level: .none, candidates: [], unnamedMeetingCount: 0
                )
                continue
            }
            let scored = score(
                query: qVec, speakerID: speakerID, corpus: corpus,
                invitees: invitees, limits: limits
            )
            results[speakerID] = scored.match
        }
        return results
    }

    /// Produces debug detail for one speaker. Uses the same scoring as `match`.
    public func explain(
        vector: [Float],
        speakerID: Int,
        corpus: PreparedCorpus,
        invitees: Invitees,
        nearestCount: Int = 15
    ) -> SpeakerExplanation {
        let limits = config.thresholds(for: corpus.kind)
        let referenceDim = corpus.entries.first?.vector.count

        guard let qVec = VectorMath.normalized(vector),
              referenceDim == nil || qVec.count == referenceDim
        else {
            let noMatch = SpeakerMatch(
                speakerID: speakerID, level: .none, candidates: [], unnamedMeetingCount: 0
            )
            return SpeakerExplanation(match: noMatch, allCandidates: [], nearest: [])
        }

        let scored = score(
            query: qVec, speakerID: speakerID, corpus: corpus,
            invitees: invitees, limits: limits
        )

        // Nearest voiceprints: all entries sorted by distance, first nearestCount
        let nearest = scored.allDistances
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.entry.meetingID.uuidString < rhs.entry.meetingID.uuidString
            }
            .prefix(nearestCount)
            .map { item in
                NearestVoiceprint(
                    meetingTitle: item.entry.meetingTitle,
                    meetingDate: item.entry.meetingDate,
                    speakerID: item.entry.speakerID,
                    tag: item.entry.tag,
                    distance: item.distance,
                    insideRadius: item.distance <= limits.acceptRadius,
                    speakingDuration: item.entry.speakingDuration
                )
            }

        return SpeakerExplanation(
            match: scored.match,
            allCandidates: scored.allRanked,
            nearest: Array(nearest)
        )
    }
}

// MARK: - Internal scoring

private struct DistanceEntry {
    let entry: NormalizedEntry
    let distance: Float
}

private struct ScoredResult {
    let match: SpeakerMatch
    let allRanked: [PersonCandidate]
    let allDistances: [DistanceEntry]
}

private extension VoiceprintMatcher {
    func score(
        query: [Float], speakerID: Int, corpus: PreparedCorpus,
        invitees: Invitees, limits: KindThresholds
    ) -> ScoredResult {
        let acceptR = limits.acceptRadius

        // Compute all distances
        let allDistances: [DistanceEntry] = corpus.entries.map { entry in
            DistanceEntry(entry: entry, distance: VectorMath.distance(query, entry.vector))
        }

        // Hits inside R
        let hits = allDistances.filter { $0.distance <= acceptR }

        // Unnamed meeting count: distinct meetings with untagged hits
        let untaggedHits = hits.filter { $0.entry.tag == nil }
        let unnamedMeetingCount = Set(untaggedHits.map(\.entry.meetingID)).count

        // Group tagged hits by person
        var personHits: [UUID: [DistanceEntry]] = [:]
        for hit in hits {
            guard let tag = hit.entry.tag else { continue }
            personHits[tag.personID, default: []].append(hit)
        }

        // Score each person
        var allCandidates: [PersonCandidate] = []
        for (personID, pHits) in personHits {
            let candidate = scoreOnePerson(
                personID: personID, hits: pHits,
                invitees: invitees, corpus: corpus,
                acceptR: acceptR
            )
            if candidate.score > 0 {
                allCandidates.append(candidate)
            }
        }

        // Sort: score desc, reportedDistance asc, personID asc
        allCandidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.reportedDistance != rhs.reportedDistance { return lhs.reportedDistance < rhs.reportedDistance }
            return lhs.personID.uuidString < rhs.personID.uuidString
        }

        // Determine level
        let matchResult = determineLevel(
            ranked: allCandidates, limits: limits,
            speakerID: speakerID, unnamedMeetingCount: unnamedMeetingCount
        )

        return ScoredResult(
            match: matchResult,
            allRanked: allCandidates,
            allDistances: allDistances
        )
    }

    func scoreOnePerson(
        personID: UUID, hits: [DistanceEntry],
        invitees: Invitees, corpus: PreparedCorpus,
        acceptR: Float
    ) -> PersonCandidate {
        // One vote per meeting: keep the closest voiceprint from each meeting
        var perMeeting: [UUID: DistanceEntry] = [:]
        for hit in hits {
            let mid = hit.entry.meetingID
            if let existing = perMeeting[mid] {
                if hit.distance < existing.distance {
                    perMeeting[mid] = hit
                }
            } else {
                perMeeting[mid] = hit
            }
        }

        // Best K meetings, sorted by distance ascending
        let kept = perMeeting.values
            .sorted { $0.distance < $1.distance }
            .prefix(config.bestMeetingsPerPerson)

        // Score
        var totalScore: Float = 0
        for item in kept {
            let tagW: Float = (item.entry.tag?.userSet ?? false) ? 1.0 : config.inferredTagWeight
            let speechW = Float(min(1, max(0, item.entry.speakingDuration) / config.fullSpeechSeconds))
            let closeness = 1 - item.distance / acceptR
            totalScore += tagW * speechW * closeness
        }

        // Invitee boost
        let isInvitee: Bool = {
            if invitees.personIDs.contains(personID) { return true }
            if let email = corpus.people[personID]?.email?.lowercased(),
               invitees.emails.contains(email)
            {
                return true
            }
            return false
        }()
        if isInvitee {
            totalScore *= config.inviteeBoost
        }

        // Reported distance: closest confirmed, else closest of all kept
        let confirmedKept = kept.filter { $0.entry.tag?.userSet ?? false }
        let reportedDistance: Float = if let closest = confirmedKept.min(by: { $0.distance < $1.distance }) {
            closest.distance
        } else if let closest = kept.min(by: { $0.distance < $1.distance }) {
            closest.distance
        } else {
            Float.greatestFiniteMagnitude
        }

        return PersonCandidate(
            personID: personID,
            score: totalScore,
            reportedDistance: reportedDistance,
            countedMeetings: kept.count,
            confirmedCountedMeetings: confirmedKept.count,
            isInvitee: isInvitee
        )
    }

    func determineLevel(
        ranked: [PersonCandidate], limits: KindThresholds,
        speakerID: Int, unnamedMeetingCount: Int
    ) -> SpeakerMatch {
        guard let best = ranked.first else {
            return SpeakerMatch(
                speakerID: speakerID, level: .none,
                candidates: [], unnamedMeetingCount: unnamedMeetingCount
            )
        }

        let runner = ranked.count > 1 ? ranked[1] : nil

        // Check ambiguous first
        if let runner {
            let scoreAmbiguous = runner.score >= config.ambiguityScoreRatio * best.score
            let distAmbiguous = abs(best.reportedDistance - runner.reportedDistance)
                <= config.ambiguityDistanceGap
            if scoreAmbiguous || distAmbiguous {
                let threshold = config.ambiguityScoreRatio * best.score
                let ambiguousCandidates = Array(
                    ranked.filter {
                        $0.score >= threshold || $0.personID == best.personID || $0.personID == runner.personID
                    }
                    .prefix(config.maxAmbiguousCandidates)
                )
                return SpeakerMatch(
                    speakerID: speakerID, level: .ambiguous,
                    candidates: ambiguousCandidates, unnamedMeetingCount: unnamedMeetingCount
                )
            }
        }

        // High
        let runnerMarginOK = runner.map { $0.score <= config.highMarginRatio * best.score } ?? true
        if best.reportedDistance <= limits.highDistance,
           best.countedMeetings >= config.highMinMeetings,
           best.confirmedCountedMeetings >= config.highMinConfirmed,
           runnerMarginOK
        {
            return SpeakerMatch(
                speakerID: speakerID, level: .high,
                candidates: [best], unnamedMeetingCount: unnamedMeetingCount
            )
        }

        // Medium
        if best.reportedDistance <= limits.mediumDistance,
           best.confirmedCountedMeetings >= 1 || best.countedMeetings >= config.mediumMinInferred
        {
            return SpeakerMatch(
                speakerID: speakerID, level: .medium,
                candidates: [best], unnamedMeetingCount: unnamedMeetingCount
            )
        }

        // Low
        return SpeakerMatch(
            speakerID: speakerID, level: .low,
            candidates: [best], unnamedMeetingCount: unnamedMeetingCount
        )
    }
}
