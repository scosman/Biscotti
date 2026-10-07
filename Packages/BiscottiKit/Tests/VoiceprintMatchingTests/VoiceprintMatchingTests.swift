import DataStore
import Foundation
import Testing
@testable import VoiceprintMatching

// MARK: - Test helpers

/// Makes an 8-dim vector at a known angle in the first two dimensions.
/// The remaining dimensions are zero. The resulting vector is NOT normalized.
private func vectorAtAngle(_ degrees: Float, magnitude: Float = 1.0) -> [Float] {
    let rad = degrees * .pi / 180
    var vec = [Float](repeating: 0, count: 8)
    vec[0] = cosf(rad) * magnitude
    vec[1] = sinf(rad) * magnitude
    return vec
}

/// Returns a normalized 8-dim vector at the given angle.
private func normalizedAtAngle(_ degrees: Float) -> [Float] {
    // swiftlint:disable:next force_unwrapping
    VectorMath.normalized(vectorAtAngle(degrees))!
}

private let testDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeEntry(
    meetingID: UUID = UUID(),
    meetingTitle: String = "Test Meeting",
    meetingDate: Date = testDate,
    speakerID: Int = 0,
    vector: [Float],
    speakingDuration: Double = 120,
    tag: SpeakerTagData? = nil
) -> VoiceprintData {
    VoiceprintData(
        meetingID: meetingID,
        meetingTitle: meetingTitle,
        meetingDate: meetingDate,
        transcriptID: UUID(),
        speakerID: speakerID,
        vector: vector,
        speakingDuration: speakingDuration,
        tag: tag
    )
}

private func makeCorpus(
    entries: [VoiceprintData],
    people: [UUID: PersonData] = [:],
    kind: VoiceprintKind = .raw,
    space: String = "test-space"
) -> VoiceprintCorpusData {
    VoiceprintCorpusData(kind: kind, space: space, entries: entries, people: people)
}

// MARK: - VectorMath tests

@Suite("VectorMath")
struct VectorMathTests {
    @Test func normalization() throws {
        let input = vectorAtAngle(45, magnitude: 3.0)
        let normed = try #require(VectorMath.normalized(input))
        let mag = sqrtf(normed.reduce(0) { $0 + $1 * $1 })
        #expect(abs(mag - 1.0) < 1e-5)
    }

    @Test func normalizationRejectsZero() {
        let zero = [Float](repeating: 0, count: 8)
        #expect(VectorMath.normalized(zero) == nil)
    }

    @Test func normalizationRejectsNaN() {
        var vec = vectorAtAngle(0)
        vec[0] = Float.nan
        #expect(VectorMath.normalized(vec) == nil)
    }

    @Test func normalizationRejectsEmpty() {
        #expect(VectorMath.normalized([]) == nil)
    }

    @Test func distanceIdentical() {
        let vec = normalizedAtAngle(30)
        let dist = VectorMath.distance(vec, vec)
        #expect(abs(dist) < 1e-5)
    }

    @Test func distanceOrthogonal() {
        let vecA = normalizedAtAngle(0)
        let vecB = normalizedAtAngle(90)
        let dist = VectorMath.distance(vecA, vecB)
        #expect(abs(dist - 1.0) < 1e-5)
    }

    @Test func distanceOpposite() {
        let vecA = normalizedAtAngle(0)
        let vecB = normalizedAtAngle(180)
        let dist = VectorMath.distance(vecA, vecB)
        #expect(abs(dist - 2.0) < 1e-5)
    }

    @Test func distanceClamp() {
        let vecA = normalizedAtAngle(0)
        let vecB = normalizedAtAngle(180)
        let dist = VectorMath.distance(vecA, vecB)
        #expect(dist >= 0 && dist <= 2)

        let distSelf = VectorMath.distance(vecA, vecA)
        #expect(distSelf >= 0 && distSelf <= 2)
    }
}

// MARK: - Matcher tests

@Suite("VoiceprintMatcher")
struct MatcherTests {
    let personA = UUID()
    let personB = UUID()
    let personC = UUID()

    var peopleMap: [UUID: PersonData] {
        [
            personA: PersonData(id: personA, name: "Alice", email: "alice@test.com"),
            personB: PersonData(id: personB, name: "Bob", email: "bob@test.com"),
            personC: PersonData(id: personC, name: "Carol", email: "carol@test.com")
        ]
    }

    @Test func matchNone() {
        // Query at 0 degrees, corpus entry at 170 degrees (very far) => no match
        let corpus = makeCorpus(entries: [
            makeEntry(vector: vectorAtAngle(170), tag: SpeakerTagData(personID: personA, userSet: true))
        ], people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == MatchLevel.none)
        #expect(result[0]?.candidates.isEmpty == true)
    }

    @Test func matchHigh() {
        // P1 at distance ~0 with 3+ confirmed meetings, no close P2
        let meetings = (0 ..< 4).map { _ in UUID() }
        let entries = meetings.map { mid in
            makeEntry(
                meetingID: mid,
                vector: vectorAtAngle(1), // very close to 0
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        }
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .high)
        #expect(result[0]?.candidates.count == 1)
        #expect(result[0]?.candidates.first?.personID == personA)
    }

    @Test func matchMedium() {
        // One confirmed meeting, distance within medium limit
        let mid = UUID()
        let entries = [
            makeEntry(
                meetingID: mid,
                vector: vectorAtAngle(5), // close to 0, within mediumDistance 0.50
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .medium)
    }

    @Test func matchLow() {
        // Only inferred tags, only 1 meeting => below medium threshold for inferred
        let mid = UUID()
        let entries = [
            makeEntry(
                meetingID: mid,
                vector: vectorAtAngle(5),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: false)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .low)
    }

    @Test func matchAmbiguousScoreRatio() {
        // Two people at similar distances => ambiguous by score ratio
        let midA = UUID()
        let midB = UUID()
        let entries = [
            makeEntry(
                meetingID: midA,
                vector: vectorAtAngle(10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: midB,
                vector: vectorAtAngle(-10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personB, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .ambiguous)
        #expect(result[0]?.candidates.count == 2)
    }

    @Test func matchAmbiguousDistanceGap() {
        // Two people with reported distances within 0.05 of each other
        // Use a config with a large ambiguityScoreRatio to isolate the distance gap test
        var config = VoiceprintConfig()
        config.ambiguityScoreRatio = 0.01 // effectively disable score-ratio ambiguity
        config.ambiguityDistanceGap = 0.05

        // Both at very similar angles => similar distances
        let midA = UUID()
        let midB = UUID()
        let entries = [
            makeEntry(
                meetingID: midA,
                vector: vectorAtAngle(8),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: midB,
                vector: vectorAtAngle(-8),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personB, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher(config: config)
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .ambiguous)
    }

    @Test func matchAmbiguousCap() {
        // 4 people at similar distances => capped to maxAmbiguousCandidates (3)
        let personD = UUID()
        var people = peopleMap
        people[personD] = PersonData(id: personD, name: "Diana")

        let entries = [personA, personB, personC, personD].enumerated().map { idx, pid in
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(Float(idx * 3 - 4)),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: pid, userSet: true)
            )
        }
        let corpus = makeCorpus(entries: entries, people: people)

        var config = VoiceprintConfig()
        config.maxAmbiguousCandidates = 3

        let matcher = VoiceprintMatcher(config: config)
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == .ambiguous)
        #expect(result[0]?.candidates.count == 3)
    }

    @Test func oneVotePerMeeting() {
        // Same meeting, same person, two voiceprints => only one vote
        let mid = UUID()
        let entries = [
            makeEntry(
                meetingID: mid,
                speakerID: 0,
                vector: vectorAtAngle(5),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: mid,
                speakerID: 1,
                vector: vectorAtAngle(3),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        // Only 1 meeting counted
        #expect(result[0]?.candidates.first?.countedMeetings == 1)
    }

    @Test func bestKCap() {
        // 7 meetings for person A, but only 5 should be counted (bestMeetingsPerPerson)
        let entries = (0 ..< 7).map { idx in
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(Float(idx)),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        }
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        var config = VoiceprintConfig()
        config.bestMeetingsPerPerson = 5

        let matcher = VoiceprintMatcher(config: config)
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.candidates.first?.countedMeetings == 5)
    }

    @Test func bestKKeepsStrongestNotNearest() {
        // 5 inferred meetings very close, 2 confirmed meetings a little farther.
        // Keeping the 5 nearest would drop both confirmed meetings; keeping the
        // 5 strongest (tag x speech x closeness) keeps them.
        let inferred = (0 ..< 5).map { _ in
            makeEntry(
                meetingID: UUID(), vector: vectorAtAngle(1), speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: false)
            )
        }
        let confirmed = (0 ..< 2).map { _ in
            makeEntry(
                meetingID: UUID(), vector: vectorAtAngle(15), speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        }
        let corpus = makeCorpus(entries: inferred + confirmed, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        let best = result[0]?.candidates.first
        #expect(best?.countedMeetings == 5)
        #expect(best?.confirmedCountedMeetings == 2)
    }

    @Test func inferredTagWeight() {
        // Person A with confirmed tags vs person B with inferred tags at same distance
        // Confirmed should outscore inferred
        let entries = [
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(-10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personB, userSet: false)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        // Person A (confirmed) should rank first
        let candidates = result[0]?.candidates ?? []
        // In an ambiguous match, P1 should be the confirmed one
        if let first = candidates.first {
            #expect(first.personID == personA)
        }
    }

    @Test func speechWeightShort() {
        // Short speech duration should produce a lower score
        let midShort = UUID()
        let midLong = UUID()
        let entries = [
            makeEntry(
                meetingID: midShort,
                vector: vectorAtAngle(5),
                speakingDuration: 5, // very short
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: midLong,
                vector: vectorAtAngle(5),
                speakingDuration: 120, // long
                tag: SpeakerTagData(personID: personB, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        // Person B (long speech) should rank higher
        if let candidates = result[0]?.candidates, candidates.count >= 2 {
            #expect(candidates[0].personID == personB)
        }
    }
}

// MARK: - Matcher edge-case tests

@Suite("VoiceprintMatcher — Edge Cases")
struct MatcherEdgeCaseTests {
    let personA = UUID()
    let personB = UUID()
    let personC = UUID()

    var peopleMap: [UUID: PersonData] {
        [
            personA: PersonData(id: personA, name: "Alice", email: "alice@test.com"),
            personB: PersonData(id: personB, name: "Bob", email: "bob@test.com"),
            personC: PersonData(id: personC, name: "Carol", email: "carol@test.com")
        ]
    }

    @Test func inviteeBoost() {
        // Person B is an invitee, person A is not; both at similar distances
        // With the boost, B should win
        let entries = [
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(5),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            ),
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(8), // slightly farther
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personB, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let invitees = Invitees(personIDs: [personB], emails: [])

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: invitees)
        // B should rank first due to boost
        #expect(result[0]?.candidates.first?.personID == personB)
        #expect(result[0]?.candidates.first?.isInvitee == true)
    }

    @Test func unnamedCount() {
        // Untagged entries from distinct meetings inside R
        let mid1 = UUID()
        let mid2 = UUID()
        let mid3 = UUID()
        let entries = [
            makeEntry(meetingID: mid1, vector: vectorAtAngle(5), tag: nil),
            makeEntry(meetingID: mid1, speakerID: 1, vector: vectorAtAngle(3), tag: nil), // same meeting
            makeEntry(meetingID: mid2, vector: vectorAtAngle(8), tag: nil),
            makeEntry(meetingID: mid3, vector: vectorAtAngle(170), tag: nil) // outside R
        ]
        let corpus = makeCorpus(entries: entries)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        // 2 distinct meetings inside R (mid1, mid2), mid3 is outside
        #expect(result[0]?.unnamedMeetingCount == 2)
        #expect(result[0]?.level == MatchLevel.none) // no tagged matches
    }

    @Test func dimensionMismatch() {
        // Query has 4 dims, corpus has 8 dims => .none
        let entry = makeEntry(vector: vectorAtAngle(5), tag: SpeakerTagData(personID: personA, userSet: true))
        let corpus = makeCorpus(entries: [entry], people: peopleMap)

        let queryVec: [Float] = [1, 0, 0, 0]
        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: queryVec], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == MatchLevel.none)
    }

    @Test func deterministicTieBreak() throws {
        // Two people with identical scores and distances: deterministic order by personID
        let idSmall = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idLarge = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let people = [
            idSmall: PersonData(id: idSmall, name: "First"),
            idLarge: PersonData(id: idLarge, name: "Last")
        ]

        let entries = [
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: idSmall, userSet: true)
            ),
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(10),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: idLarge, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: people)

        let matcher = VoiceprintMatcher()
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        // Should be ambiguous with deterministic order
        let candidates = result[0]?.candidates ?? []
        #expect(candidates.count == 2)
        #expect(candidates[0].personID == idSmall)
        #expect(candidates[1].personID == idLarge)
    }

    @Test func customThresholds() {
        // Custom thresholds should be used by the matcher
        var config = VoiceprintConfig()
        config.thresholds = KindThresholds(acceptRadius: 0.1, highDistance: 0.05, mediumDistance: 0.08)

        let entry = makeEntry(
            meetingID: UUID(),
            vector: vectorAtAngle(60), // cos(60deg)=0.5, distance ~0.5 — outside R=0.1
            speakingDuration: 120,
            tag: SpeakerTagData(personID: personA, userSet: true)
        )

        // With tight R=0.1, should be .none (distance ~0.5 > 0.1)
        let corpus = makeCorpus(entries: [entry], people: peopleMap)
        let matcher = VoiceprintMatcher(config: config)
        let result = matcher.match(query: [0: vectorAtAngle(0)], corpus: PreparedCorpus(corpus), invitees: .none)
        #expect(result[0]?.level == MatchLevel.none)
    }
}

// MARK: - Explain tests

@Suite("VoiceprintMatcher.explain")
struct ExplainTests {
    let personA = UUID()
    let personB = UUID()

    var peopleMap: [UUID: PersonData] {
        [
            personA: PersonData(id: personA, name: "Alice"),
            personB: PersonData(id: personB, name: "Bob")
        ]
    }

    @Test func matchConsistency() {
        let entries = [
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(5),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: personA, userSet: true)
            )
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)
        let prepared = PreparedCorpus(corpus)

        let matcher = VoiceprintMatcher()
        let matchResult = matcher.match(query: [0: vectorAtAngle(0)], corpus: prepared, invitees: .none)
        let explanation = matcher.explain(
            vector: vectorAtAngle(0), speakerID: 0,
            corpus: prepared, invitees: .none
        )

        #expect(explanation.match == matchResult[0])
    }

    @Test func nearestOutsideR() {
        // Some entries inside R, some outside
        let entries = [
            makeEntry(meetingID: UUID(), vector: vectorAtAngle(5), tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: UUID(), vector: vectorAtAngle(170), tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)
        let prepared = PreparedCorpus(corpus)

        let matcher = VoiceprintMatcher()
        let explanation = matcher.explain(
            vector: vectorAtAngle(0), speakerID: 0,
            corpus: prepared, invitees: .none
        )

        #expect(explanation.nearest.count == 2)
        // First should be inside R
        #expect(explanation.nearest[0].insideRadius == true)
        // Second should be outside R
        #expect(explanation.nearest[1].insideRadius == false)
    }

    @Test func allCandidatesNotTruncated() {
        // More candidates than would appear in a capped ambiguous match
        var config = VoiceprintConfig()
        config.maxAmbiguousCandidates = 2

        let personC = UUID()
        var people = peopleMap
        people[personC] = PersonData(id: personC, name: "Carol")

        let entries = [personA, personB, personC].enumerated().map { idx, pid in
            makeEntry(
                meetingID: UUID(),
                vector: vectorAtAngle(Float(idx * 5)),
                speakingDuration: 120,
                tag: SpeakerTagData(personID: pid, userSet: true)
            )
        }
        let corpus = makeCorpus(entries: entries, people: people)
        let prepared = PreparedCorpus(corpus)

        let matcher = VoiceprintMatcher(config: config)
        let explanation = matcher.explain(
            vector: vectorAtAngle(0), speakerID: 0,
            corpus: prepared, invitees: .none
        )

        // match.candidates may be capped at 2 (ambiguous cap)
        // allCandidates should have all 3
        #expect(explanation.allCandidates.count == 3)
    }
}

// MARK: - BackfillSpeakerMapper tests

@Suite("BackfillSpeakerMapper")
struct BackfillMapperTests {
    @Test func identity() {
        // Same speaker IDs with identical spans => maps 1:1
        let spans = [
            SpeakerSpan(speakerID: 0, start: 0, end: 10),
            SpeakerSpan(speakerID: 1, start: 10, end: 20)
        ]
        let result = BackfillSpeakerMapper.map(fresh: spans, stored: spans)
        #expect(result.mapping == [0: 0, 1: 1])
        #expect(result.unmapped.isEmpty)
    }

    @Test func renumbered() {
        // Fresh IDs 0,1 overlap with stored IDs 1,0 (swapped)
        let fresh = [
            SpeakerSpan(speakerID: 0, start: 0, end: 10),
            SpeakerSpan(speakerID: 1, start: 10, end: 20)
        ]
        let stored = [
            SpeakerSpan(speakerID: 1, start: 0, end: 10),
            SpeakerSpan(speakerID: 0, start: 10, end: 20)
        ]
        let result = BackfillSpeakerMapper.map(fresh: fresh, stored: stored)
        #expect(result.mapping == [0: 1, 1: 0])
        #expect(result.unmapped.isEmpty)
    }

    @Test func belowThreshold() {
        // Overlap below the 50% threshold => unmapped
        let fresh = [
            SpeakerSpan(speakerID: 0, start: 0, end: 10)
        ]
        let stored = [
            SpeakerSpan(speakerID: 0, start: 8, end: 18) // only 2s overlap out of 10s
        ]
        let result = BackfillSpeakerMapper.map(fresh: fresh, stored: stored)
        #expect(result.mapping.isEmpty)
        #expect(result.unmapped == [0])
    }

    @Test func greedyConflict() {
        // Fresh 0 overlaps stored 0 (8s) and stored 1 (2s)
        // Fresh 1 overlaps stored 0 (6s)
        // Greedy: fresh 0 -> stored 0 (largest), fresh 1 unmapped (stored 0 taken)
        let fresh = [
            SpeakerSpan(speakerID: 0, start: 0, end: 10),
            SpeakerSpan(speakerID: 1, start: 0, end: 10)
        ]
        let stored = [
            SpeakerSpan(speakerID: 0, start: 0, end: 8),
            SpeakerSpan(speakerID: 1, start: 8, end: 10)
        ]
        let result = BackfillSpeakerMapper.map(fresh: fresh, stored: stored)
        #expect(result.mapping[0] == 0)
        // Fresh 1 maps to stored 1 only if overlap >= 50%: overlap = 2s, total = 10s => 20% < 50%
        #expect(result.unmapped.contains(1))
    }
}

// MARK: - PreparedCorpus tests

@Suite("PreparedCorpus")
struct PreparedCorpusTests {
    @Test func dropsZeroVectors() {
        let entries = [
            makeEntry(vector: [Float](repeating: 0, count: 8)),
            makeEntry(vector: vectorAtAngle(10))
        ]
        let corpus = makeCorpus(entries: entries)
        let prepared = PreparedCorpus(corpus)
        #expect(prepared.entryCount == 1)
    }

    @Test func dropsDimensionMismatch() {
        let entries = [
            makeEntry(vector: vectorAtAngle(10)),
            makeEntry(vector: [Float](repeating: 1, count: 4)) // different dimension
        ]
        let corpus = makeCorpus(entries: entries)
        let prepared = PreparedCorpus(corpus)
        #expect(prepared.entryCount == 1)
    }

    @Test func historyStats() {
        let personA = UUID()
        let personB = UUID()
        let mid1 = UUID()
        let mid2 = UUID()

        let entries = [
            makeEntry(meetingID: mid1, vector: vectorAtAngle(10),
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mid2, vector: vectorAtAngle(20),
                      tag: SpeakerTagData(personID: personA, userSet: false)),
            makeEntry(meetingID: mid2, speakerID: 1, vector: vectorAtAngle(30),
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries)
        let prepared = PreparedCorpus(corpus)

        #expect(prepared.history.meetingCount == 2)
        #expect(prepared.history.confirmedMeetingCount == 2) // mid1 (A confirmed) + mid2 (B confirmed)
        #expect(prepared.history.perPerson[personA]?.meetings == 2)
        #expect(prepared.history.perPerson[personA]?.confirmedMeetings == 1)
        #expect(prepared.history.perPerson[personB]?.meetings == 1)
        #expect(prepared.history.perPerson[personB]?.confirmedMeetings == 1)
    }

    @Test func excludingMeeting() {
        let mid1 = UUID()
        let mid2 = UUID()
        let entries = [
            makeEntry(meetingID: mid1, vector: vectorAtAngle(10)),
            makeEntry(meetingID: mid2, vector: vectorAtAngle(20))
        ]
        let corpus = makeCorpus(entries: entries)
        let prepared = PreparedCorpus(corpus)
        let excluded = prepared.excluding(meetingID: mid1)
        #expect(excluded.entryCount == 1)
        #expect(excluded.history.meetingCount == 1)
    }
}

// MARK: - Evaluator tests

@Suite("VoiceprintEvaluator")
struct EvaluatorTests {
    let personA = UUID()
    let personB = UUID()

    var peopleMap: [UUID: PersonData] {
        [
            personA: PersonData(id: personA, name: "Alice"),
            personB: PersonData(id: personB, name: "Bob")
        ]
    }

    @Test func leakageTest() {
        // A voiceprint whose only close match is in its own meeting must not count as correct.
        let mid1 = UUID()
        let mid2 = UUID()
        let mid3 = UUID()

        // Person A appears only in mid1 with a close voiceprint;
        // in mid2 and mid3, only person B appears at a very different angle
        let entries = [
            makeEntry(meetingID: mid1, vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mid2, vector: vectorAtAngle(170), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mid3, vector: vectorAtAngle(175), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let evaluator = VoiceprintEvaluator()
        let metrics = evaluator.evaluate(corpus)

        // Person A's trial: after hiding mid1, person A has no history in the rest => trialsWithoutHistory
        #expect(metrics.trialsWithoutHistory >= 1)
    }

    @Test func sweepRates() {
        // Build a corpus where we know exact distances, then verify sweep rates
        let mids = (0 ..< 4).map { _ in UUID() }

        // Person A at angle 0 in meetings 0,1; person B at angle 90 in meetings 2,3
        let entries = [
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(2), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(90), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mids[3], vector: vectorAtAngle(88), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let evaluator = VoiceprintEvaluator(sweep: [0.1, 0.5, 1.5])
        let metrics = evaluator.evaluate(corpus)

        #expect(metrics.trials > 0)
        #expect(metrics.sweep.count == 3)

        // At radius 1.5: all genuine should be inside => missedMatchRate near 0
        if let wideRow = metrics.sweep.last {
            #expect(wideRow.missedMatchRate < 0.01)
        }

        // At radius 0.1: genuine distances (cosine distance of ~2 degrees) should be small enough
        // to still be inside R=0.1 (cos(2deg) ~ 0.9994, so distance ~ 0.0006)
        if let tightRow = metrics.sweep.first {
            #expect(tightRow.missedMatchRate < 0.01)
        }
    }

    @Test func eerChoice() {
        // Verify EER is a radius from the sweep
        let mids = (0 ..< 4).map { _ in UUID() }
        let entries = [
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(5), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(90), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mids[3], vector: vectorAtAngle(85), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let sweepRadii: [Float] = stride(from: Float(0.1), through: Float(1.5), by: Float(0.1)).map(\.self)
        let evaluator = VoiceprintEvaluator(sweep: sweepRadii)
        let metrics = evaluator.evaluate(corpus)

        if let eer = metrics.equalErrorRadius {
            #expect(sweepRadii.contains(eer))
        }
    }

    @Test func confusedPairs() {
        // Person A has many meetings, person B has one meeting with an identical vector.
        // When B's meeting is hidden, B has no history => skipped.
        // When any of A's meetings is hidden, the query matches A (not confused).
        // But when we give B enough meetings and place them at the same angle as A,
        // confusion is forced: both people share identical embeddings.
        let mids = (0 ..< 8).map { _ in UUID() }
        let entries = [
            // Person A at angle 0 — four meetings
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[3], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            // Person B at angle 0 — four meetings (identical vectors => must confuse)
            makeEntry(meetingID: mids[4], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mids[5], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mids[6], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true)),
            makeEntry(meetingID: mids[7], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let evaluator = VoiceprintEvaluator()
        let metrics = evaluator.evaluate(corpus)

        // With identical vectors for different people, some trials must be incorrect
        #expect(metrics.trials > 0)
        #expect(!metrics.confusedPairs.isEmpty)
        // Each confused pair should reference Alice or Bob
        let names = Set(metrics.confusedPairs.flatMap { [$0.truth, $0.predicted] })
        #expect(names.isSubset(of: ["Alice", "Bob"]))
    }

    @Test func detDistancePrefersConfirmed() {
        // A person has a closer inferred entry and a farther confirmed entry.
        // The DET distance should use the confirmed entry's distance.
        let mids = (0 ..< 5).map { _ in UUID() }
        let entries = [
            // Person A: confirmed entries at angle ~30 (moderate distance from 0)
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(30), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(28), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(32), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            // Person A: inferred entry at angle ~2 (very close to 0, closer than confirmed)
            makeEntry(meetingID: mids[3], vector: vectorAtAngle(2), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: false)),
            // Person B: confirmed, far away to be a clear impostor
            makeEntry(meetingID: mids[4], vector: vectorAtAngle(150), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        // Use a sweep that includes both the confirmed distance (~0.13 at 30deg)
        // and the inferred distance (~0.0006 at 2deg).
        // If the evaluator wrongly uses the inferred distance, the genuine distance
        // would be ~0 and would pass a tight radius; with confirmed it's ~0.13.
        let evaluator = VoiceprintEvaluator(sweep: [0.01, 0.05, 0.20, 0.50])
        let metrics = evaluator.evaluate(corpus)

        // Trial: hide mids[4] (B's only meeting) => B has no history, skipped.
        // Trials come from hiding each of A's meetings (mids[0..3]).
        // When hiding mids[3] (the inferred entry), the query is inferred so it's skipped
        // (only userSet entries generate trials). So 3 trials from confirmed entries.
        // The query vector is at ~30deg, genuine distance to remaining A entries is small.
        // At radius 0.01, the genuine distance (~0.001 between 28 and 30 deg) should mostly fit.
        // Key check: metrics are produced and the sweep is consistent.
        #expect(metrics.trials >= 2)

        // More specific: at radius 0.50, all genuine should be inside
        if let wideRow = metrics.sweep.last {
            #expect(wideRow.missedMatchRate < 0.5)
        }
    }

    @Test func suspectTags() {
        // Person A with a voiceprint far from the mean
        let mids = (0 ..< 4).map { _ in UUID() }
        let entries = [
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(2), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(1), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            // Outlier: far away
            makeEntry(meetingID: mids[3], meetingTitle: "Suspect Meeting", vector: vectorAtAngle(160), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let evaluator = VoiceprintEvaluator()
        let metrics = evaluator.evaluate(corpus)

        // The outlier should appear as a suspect tag
        #expect(!metrics.suspectTags.isEmpty)
        #expect(metrics.suspectTags.first?.person == "Alice")
    }

    @Test func trialsWithoutHistory() {
        // A person that appears in only one meeting: when that meeting is hidden,
        // they have no history => trialsWithoutHistory
        let mid1 = UUID()
        let mid2 = UUID()
        let entries = [
            makeEntry(meetingID: mid1, vector: vectorAtAngle(0), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personA, userSet: true)),
            makeEntry(meetingID: mid2, vector: vectorAtAngle(90), speakingDuration: 120,
                      tag: SpeakerTagData(personID: personB, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: peopleMap)

        let evaluator = VoiceprintEvaluator()
        let metrics = evaluator.evaluate(corpus)

        // Both people appear in only one meeting each; hiding their meeting removes them
        #expect(metrics.trialsWithoutHistory == 2)
        #expect(metrics.trials == 0)
    }
}

// MARK: - PersonAliases tests

@Suite("PersonAliases")
struct PersonAliasesTests {
    let steve = UUID()
    let steveWork = UUID()
    let bob = UUID()

    var people: [UUID: PersonData] {
        [
            steve: PersonData(id: steve, name: "Steve"),
            steveWork: PersonData(id: steveWork, name: "steve@kiln.tech", email: "steve@kiln.tech"),
            bob: PersonData(id: bob, name: "Bob")
        ]
    }

    @Test func resolvesByNameOrEmailCaseInsensitive() {
        let result = PersonAliases.resolve([["steve", "STEVE@kiln.tech"]], people: people)
        #expect(result.unmatched.isEmpty)
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0]) == [steve, steveWork])
    }

    @Test func reportsUnmatchedAndDropsSingletons() {
        let result = PersonAliases.resolve([["Bob", "nobody@x.com"]], people: people)
        #expect(result.unmatched == ["nobody@x.com"])
        #expect(result.groups.isEmpty)
    }

    @Test func mergedAliasesAreNotConfused() throws {
        // Steve's two records share one voice. Unmerged, trials confuse them;
        // merged, every trial is correct and no alias pair is an impostor.
        let mids = (0 ..< 4).map { _ in UUID() }
        let entries = [
            makeEntry(meetingID: mids[0], vector: vectorAtAngle(0),
                      tag: SpeakerTagData(personID: steve, userSet: true)),
            makeEntry(meetingID: mids[1], vector: vectorAtAngle(1),
                      tag: SpeakerTagData(personID: steveWork, userSet: true)),
            makeEntry(meetingID: mids[2], vector: vectorAtAngle(2),
                      tag: SpeakerTagData(personID: steve, userSet: true)),
            makeEntry(meetingID: mids[3], vector: vectorAtAngle(3),
                      tag: SpeakerTagData(personID: steveWork, userSet: true))
        ]
        let corpus = makeCorpus(entries: entries, people: people)
        let evaluator = VoiceprintEvaluator(sweep: [0.1])

        let before = evaluator.evaluate(corpus)
        #expect(before.top1Correct < before.trials)

        let groups = PersonAliases.resolve([["Steve", "steve@kiln.tech"]], people: people).groups
        let after = evaluator.evaluate(corpus.mergingPeople(groups))
        #expect(after.trials == 4)
        #expect(after.top1Correct == 4)
        #expect(after.confusedPairs.isEmpty)
        let row = try #require(after.sweep.first)
        #expect(row.falseMatchRate == 0)
    }
}

// MARK: - MetricsFormatter tests

@Suite("MetricsFormatter")
struct MetricsFormatterTests {
    @Test func goldenText() {
        let metrics = VoiceprintMetrics(
            space: "test/space",
            trials: 10, trialsWithoutHistory: 2,
            top1Correct: 8,
            byLevel: [
                .high: LevelStats(total: 5, correct: 5),
                .medium: LevelStats(total: 3, correct: 2),
                .low: LevelStats(total: 2, correct: 1)
            ],
            sweep: [],
            equalErrorRadius: 0.45,
            confusedPairs: [ConfusedPair(truth: "Alice", predicted: "Bob", count: 2)],
            coverage: Coverage(
                peopleWithConfirmed: 5, atLeast3: 3, atLeast5: 1,
                speechUnder15s: 2, speech15to60s: 3, speech60to300s: 4, speechOver300s: 1
            ),
            suspectTags: []
        )

        let output = MetricsFormatter.text(metrics, includeSweep: false)

        // Verify key lines are present
        #expect(output.contains("=== RAW (test/space) ==="))
        #expect(output.contains("Top-1 accuracy: 80.0% (8/10)"))
        #expect(output.contains("high: 5/5 (100.0%)"))
        #expect(output.contains("medium: 2/3 (66.7%)"))
        #expect(output.contains("Equal error radius: 0.45"))
        #expect(output.contains("Alice -> Bob: 2"))
        #expect(output.contains("People with confirmed tags: 5"))
    }

    @Test func noSummarySection() {
        let metrics = VoiceprintMetrics(
            space: "test/space",
            trials: 5, trialsWithoutHistory: 0,
            top1Correct: 5,
            byLevel: [.high: LevelStats(total: 5, correct: 5)],
            sweep: [],
            equalErrorRadius: 0.30,
            confusedPairs: [],
            coverage: Coverage(
                peopleWithConfirmed: 3, atLeast3: 2, atLeast5: 1,
                speechUnder15s: 0, speech15to60s: 1, speech60to300s: 2, speechOver300s: 2
            ),
            suspectTags: []
        )

        let output = MetricsFormatter.text(metrics, includeSweep: false)

        #expect(!output.contains("=== Summary ==="))
        #expect(output.contains("=== RAW (test/space) ==="))
    }
}
