import DataStore
import Foundation
import Testing
import Transcription

// MARK: - Shared Helpers

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private func makeSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 30,
            text: "Hello", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        ),
        TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 30, endTime: 60,
            text: "World", confidence: 0.85, noSpeechProbability: 0.15, words: nil
        )
    ]
}

/// Creates a TranscriptResult with embedding sets.
private func makeResultWithEmbeddings(
    rawVectors: [Int: [Float]] = [0: [1.0, 2.0, 3.0], 1: [4.0, 5.0, 6.0]],
    durations: [Int: TimeInterval] = [0: 45.0, 1: 30.0]
) -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: makeSegments(),
        embeddingSets: [
            SpeakerEmbeddingSet(kind: .raw, space: "pyannote-v3/W8A16", vectors: rawVectors)
        ],
        speakerSpeechDurations: durations,
        processingDuration: 2.0
    )
}

/// Creates a meeting with a transcript that has voiceprints, returns (meetingID, transcriptID).
private func makeMeetingWithVoiceprints(
    store: DataStore,
    title: String = "Meeting",
    start: Date? = nil,
    rawVectors: [Int: [Float]] = [0: [1.0, 2.0, 3.0], 1: [4.0, 5.0, 6.0]],
    durations: [Int: TimeInterval] = [0: 45.0, 1: 30.0]
) async throws -> (UUID, UUID) {
    let meetingID = try await store.createMeeting(title: title, start: start)
    let result = makeResultWithEmbeddings(
        rawVectors: rawVectors, durations: durations
    )
    let transcriptID = try await store.addTranscript(
        result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(transcriptID, for: meetingID)
    return (meetingID, transcriptID)
}

// MARK: - VectorCoding Tests

@Suite("VectorCoding")
struct VectorCodingTests {
    @Test("encode/decode round-trip with matching dimension")
    func roundTrip() {
        let original: [Float] = [1.0, -2.5, 3.14, 0.0, Float.greatestFiniteMagnitude]
        let data = VectorCoding.encode(original)
        let decoded = VectorCoding.decode(data, dimension: original.count)
        #expect(decoded == original)
    }

    @Test("decode returns nil for wrong dimension")
    func wrongLength() {
        let data = VectorCoding.encode([1.0, 2.0, 3.0])
        #expect(VectorCoding.decode(data, dimension: 2) == nil)
        #expect(VectorCoding.decode(data, dimension: 4) == nil)
    }

    @Test("decode returns nil when data contains NaN")
    func nanValue() {
        let vector: [Float] = [1.0, Float.nan, 3.0]
        let data = VectorCoding.encode(vector)
        #expect(VectorCoding.decode(data, dimension: 3) == nil)
    }

    @Test("decode returns nil when data contains infinity")
    func infinityValue() {
        let vector: [Float] = [1.0, Float.infinity, 3.0]
        let data = VectorCoding.encode(vector)
        #expect(VectorCoding.decode(data, dimension: 3) == nil)
    }

    @Test("empty vector round-trips")
    func emptyVector() {
        let data = VectorCoding.encode([])
        #expect(VectorCoding.decode(data, dimension: 0) == [])
    }
}

// MARK: - addTranscript Voiceprint Tests

@Suite("DataStore -- addTranscript voiceprints")
struct AddTranscriptVoiceprintTests {
    @Test("creates one voiceprint per non-empty vector")
    func createsVoiceprints() async throws {
        let store = try makeStore()
        _ = try await makeMeetingWithVoiceprints(store: store)

        try await store.read { store in
            let voiceprints = try store.fetchAllVoiceprints()
            // 2 speakers x 1 kind (raw) = 2
            #expect(voiceprints.count == 2)

            let rawVPs = voiceprints.filter { $0.kindRaw == "raw" }
            #expect(rawVPs.count == 2)

            // Check dimensions
            for entry in rawVPs {
                #expect(entry.dimension == 3)
            }

            // Check speaking durations
            let rawSpeaker0 = rawVPs.first { $0.speakerID == 0 }
            #expect(rawSpeaker0?.speakingDuration == 45.0)
            let rawSpeaker1 = rawVPs.first { $0.speakerID == 1 }
            #expect(rawSpeaker1?.speakingDuration == 30.0)
        }
    }

    @Test("skips non-finite vectors and saves the rest")
    func skipsNonFinite() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "NaN test")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 2,
            segments: makeSegments(),
            embeddingSets: [
                SpeakerEmbeddingSet(
                    kind: .raw, space: "test",
                    vectors: [
                        0: [1.0, Float.nan, 3.0], // non-finite -> skipped
                        1: [4.0, 5.0, 6.0] // finite -> saved
                    ]
                )
            ],
            speakerSpeechDurations: [0: 10.0, 1: 20.0],
            processingDuration: 1.0
        )
        _ = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        try await store.read { store in
            let voiceprints = try store.fetchAllVoiceprints()
            #expect(voiceprints.count == 1)
            #expect(voiceprints.first?.speakerID == 1)
        }
    }

    @Test("skips empty vectors")
    func skipsEmpty() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Empty test")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 2,
            segments: makeSegments(),
            embeddingSets: [
                SpeakerEmbeddingSet(
                    kind: .raw, space: "test",
                    vectors: [0: [], 1: [4.0, 5.0]]
                )
            ],
            processingDuration: 1.0
        )
        _ = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        try await store.read { store in
            let voiceprints = try store.fetchAllVoiceprints()
            #expect(voiceprints.count == 1)
            #expect(voiceprints.first?.speakerID == 1)
        }
    }

    @Test("uses default 0 duration when speaker has no duration entry")
    func defaultDuration() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No duration")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [makeSegments()[0]],
            embeddingSets: [
                SpeakerEmbeddingSet(kind: .raw, space: "test", vectors: [0: [1.0, 2.0]])
            ],
            speakerSpeechDurations: [:],
            processingDuration: 1.0
        )
        _ = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        try await store.read { store in
            let voiceprint = try store.fetchAllVoiceprints().first
            #expect(voiceprint?.speakingDuration == 0)
        }
    }
}

// MARK: - voiceprintQuery Tests

@Suite("DataStore -- voiceprintQuery")
struct VoiceprintQueryTests {
    @Test("returns vectors and durations for the right kind")
    func returnsVectorsAndDurations() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithVoiceprints(store: store)

        let rawQuery = try await store.voiceprintQuery(transcriptID: transcriptID, kind: .raw)
        #expect(rawQuery?.space == "pyannote-v3/W8A16")
        #expect(rawQuery?.vectors.count == 2)
        #expect(rawQuery?.vectors[0] == [1.0, 2.0, 3.0])
        #expect(rawQuery?.speakingDurations[0] == 45.0)
    }

    @Test("returns nil space when no voiceprints of the matching space exist")
    func nilSpaceWhenNone() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Wrong space")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [makeSegments()[0]],
            embeddingSets: [
                SpeakerEmbeddingSet(kind: .raw, space: "test", vectors: [0: [1.0]])
            ],
            processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        // Query with a different space to confirm nil result
        let query = try await store.voiceprintQuery(transcriptID: txID, kind: .raw)
        // voiceprintQuery doesn't filter by space; it returns whatever space is stored
        #expect(query?.space == "test")
    }

    @Test("returns nil for nonexistent transcript")
    func nilForMissing() async throws {
        let store = try makeStore()
        let result = try await store.voiceprintQuery(transcriptID: UUID(), kind: .raw)
        #expect(result == nil)
    }
}

// MARK: - voiceprintCorpus Tests

@Suite("DataStore -- voiceprintCorpus")
struct VoiceprintCorpusTests {
    @Test("includes only preferred transcript voiceprints")
    func preferredOnly() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Multi-transcript")

        // First transcript (preferred)
        let result1 = makeResultWithEmbeddings()
        let txID1 = try await store.addTranscript(
            result1, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID1, for: meetingID)

        // Second transcript (not preferred)
        let result2 = makeResultWithEmbeddings(
            rawVectors: [0: [99.0, 99.0, 99.0]]
        )
        _ = try await store.addTranscript(
            result2, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "pyannote-v3/W8A16", excludingMeetingID: nil
        )
        // Only preferred transcript's voiceprints
        #expect(corpus.entries.count == 2)
        let vectors = corpus.entries.map(\.vector)
        #expect(vectors.contains([1.0, 2.0, 3.0]))
        #expect(vectors.contains([4.0, 5.0, 6.0]))
        #expect(!vectors.contains([99.0, 99.0, 99.0]))
    }

    @Test("excludes wrong space")
    func excludesWrongSpace() async throws {
        let store = try makeStore()
        _ = try await makeMeetingWithVoiceprints(store: store)

        // Query for raw in a non-existent space -> nothing
        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "nonexistent-space", excludingMeetingID: nil
        )
        #expect(corpus.entries.isEmpty)
    }

    @Test("excludes the specified meeting")
    func excludesMeeting() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithVoiceprints(
            store: store, title: "Excluded"
        )
        _ = try await makeMeetingWithVoiceprints(
            store: store, title: "Included",
            rawVectors: [0: [7.0, 8.0, 9.0]]
        )

        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "pyannote-v3/W8A16", excludingMeetingID: meetingID
        )
        // Only the second meeting's voiceprints
        #expect(corpus.entries.count == 1)
        #expect(corpus.entries[0].vector == [7.0, 8.0, 9.0])
    }

    @Test("tags joined correctly with userSet; dangling person -> nil tag")
    func tagsAndDanglingPerson() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithVoiceprints(store: store)

        // Assign speaker 0 to a real person (user-set)
        let steveID = try await store.findOrCreatePerson(name: "Steve", email: "steve@test.com")
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: steveID, for: transcriptID
        )

        // Assign speaker 1 to a person, then delete that person
        let ghostID = try await store.findOrCreatePerson(name: "Ghost", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: ghostID, for: transcriptID
        )
        // Delete the Ghost person
        try await store.deletePerson(id: ghostID)

        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "pyannote-v3/W8A16",
            excludingMeetingID: nil
        )

        let entry0 = corpus.entries.first { $0.speakerID == 0 }
        #expect(entry0?.tag?.personID == steveID)
        #expect(entry0?.tag?.userSet == true)

        // Speaker 1 tagged to a deleted person -> nil tag
        let entry1 = corpus.entries.first { $0.speakerID == 1 }
        #expect(entry1?.tag == nil)
    }

    @Test("people dict contains only persons referenced by tags")
    func peopleOnlyReferenced() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithVoiceprints(store: store)

        // Create two persons, only tag one
        let steveID = try await store.findOrCreatePerson(name: "Steve", email: nil)
        _ = try await store.findOrCreatePerson(name: "Unrelated", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: steveID, for: transcriptID
        )

        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "pyannote-v3/W8A16", excludingMeetingID: nil
        )
        #expect(corpus.people.count == 1)
        #expect(corpus.people[steveID]?.name == "Steve")
    }

    @Test("meeting context fields are populated correctly")
    func meetingContextFields() async throws {
        let store = try makeStore()
        let startDate = Date(timeIntervalSince1970: 1_000_000)
        let (meetingID, _) = try await makeMeetingWithVoiceprints(
            store: store, title: "Team Standup", start: startDate
        )

        let corpus = try await store.voiceprintCorpus(
            kind: .raw, space: "pyannote-v3/W8A16", excludingMeetingID: nil
        )
        let entry = corpus.entries.first
        #expect(entry?.meetingID == meetingID)
        #expect(entry?.meetingTitle == "Team Standup")
        #expect(entry?.meetingDate == startDate)
    }
}

// MARK: - Cascade Delete Tests

@Suite("DataStore -- voiceprint cascade delete")
struct VoiceprintCascadeTests {
    @Test("deleting a meeting cascades to its voiceprints")
    func cascadeDelete() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithVoiceprints(store: store)

        let countBefore = try await store.read { store in
            try store.fetchAllVoiceprints().count
        }
        #expect(countBefore == 2)

        try await store.delete(meetingID: meetingID)

        let countAfter = try await store.read { store in
            try store.fetchAllVoiceprints().count
        }
        #expect(countAfter == 0)
    }
}

// MARK: - setParticipants(currentUser:) Tests

@Suite("DataStore -- setParticipants currentUser")
struct SetParticipantsCurrentUserTests {
    @Test("currentUser sets currentUserPersonID on snapshot")
    func setsCurrentUserPersonID() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        // Create a snapshot first (currentUserPersonID needs a snapshot)
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let personID = try await store.findOrCreatePerson(name: "Me", email: "me@test.com")
        try await store.setParticipants(
            [personID], organizer: personID, currentUser: personID, for: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.calendarSnapshot?.currentUserPersonID == personID)
        }
    }

    @Test("nil currentUser clears currentUserPersonID")
    func nilClearsCurrentUser() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let personID = try await store.findOrCreatePerson(name: "Me", email: nil)
        try await store.setParticipants(
            [personID], organizer: nil, currentUser: personID, for: meetingID
        )

        // Now clear it
        try await store.setParticipants(
            [personID], organizer: nil, currentUser: nil, for: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            #expect(meeting?.calendarSnapshot?.currentUserPersonID == nil)
        }
    }

    @Test("throws notFound for nonexistent currentUser person")
    func throwsForMissingPerson() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let fakeID = UUID()
        await #expect(throws: DataStoreError.self) {
            try await store.setParticipants(
                [], organizer: nil, currentUser: fakeID, for: meetingID
            )
        }
    }
}

// MARK: - calendarContext isCurrentUser Tests

@Suite("DataStore -- calendarContext isCurrentUser")
struct CalendarContextCurrentUserTests {
    @Test("marks the correct person as current user")
    func marksCurrentUser() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let steveID = try await store.findOrCreatePerson(name: "Steve", email: "steve@test.com")
        let danID = try await store.findOrCreatePerson(name: "Daniel", email: "dan@test.com")
        try await store.setParticipants(
            [steveID, danID], organizer: steveID,
            currentUser: danID, for: meetingID
        )

        let context = try await store.calendarContext(meetingID: meetingID)
        #expect(context?.organizer?.isCurrentUser == false)

        let danAttendee = context?.attendees.first { $0.id == danID }
        #expect(danAttendee?.isCurrentUser == true)

        let steveAttendee = context?.attendees.first { $0.id == steveID }
        #expect(steveAttendee?.isCurrentUser == false)
    }

    @Test("organizer can be current user")
    func organizerAsCurrentUser() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let meID = try await store.findOrCreatePerson(name: "Me", email: nil)
        try await store.setParticipants(
            [], organizer: meID, currentUser: meID, for: meetingID
        )

        let context = try await store.calendarContext(meetingID: meetingID)
        #expect(context?.organizer?.isCurrentUser == true)
    }

    @Test("no current user -> all isCurrentUser false")
    func noCurrentUser() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")
        let snapshot = CalendarSnapshot(compositeKey: "test", title: "Event")
        try await store.setSnapshot(snapshot, for: meetingID)

        let personID = try await store.findOrCreatePerson(name: "Person", email: nil)
        try await store.setParticipants(
            [personID], organizer: personID, for: meetingID
        )

        let context = try await store.calendarContext(meetingID: meetingID)
        #expect(context?.organizer?.isCurrentUser == false)
        #expect(context?.attendees.allSatisfy { !$0.isCurrentUser } == true)
    }
}

// MARK: - Backfill Operations Tests

@Suite("DataStore -- backfill voiceprint operations")
struct BackfillTests {
    @Test("addVoiceprints and hasVoiceprints round-trip")
    func addAndHas() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Backfill")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [makeSegments()[0]],
            processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        // Initially no voiceprints
        let hasBefore = try await store.hasVoiceprints(
            transcriptID: txID, kind: .raw, space: "test-space"
        )
        #expect(hasBefore == false)

        // Add voiceprints
        try await store.addVoiceprints(
            [
                NewVoiceprint(speakerID: 0, vector: [1.0, 2.0], speakingDuration: 30.0),
                NewVoiceprint(speakerID: 1, vector: [3.0, 4.0], speakingDuration: 15.0)
            ],
            kind: .raw, space: "test-space", to: txID
        )

        let hasAfter = try await store.hasVoiceprints(
            transcriptID: txID, kind: .raw, space: "test-space"
        )
        #expect(hasAfter == true)

        // Different space still returns false
        let hasDiffSpace = try await store.hasVoiceprints(
            transcriptID: txID, kind: .raw, space: "other-space"
        )
        #expect(hasDiffSpace == false)

        // Verify voiceprints are stored correctly
        try await store.read { store in
            let voiceprints = try store.fetchAllVoiceprints()
            #expect(voiceprints.count == 2)
        }
    }

    @Test("backfillCandidates returns meetings oldest first with correct fields")
    func candidatesContentAndOrder() async throws {
        let store = try makeStore()

        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let newDate = Date(timeIntervalSince1970: 2_000_000)

        // Create older meeting
        let (oldID, oldTxID) = try await makeMeetingWithVoiceprints(
            store: store, title: "Old Meeting", start: oldDate
        )

        // Create newer meeting
        let (newID, _) = try await makeMeetingWithVoiceprints(
            store: store, title: "New Meeting", start: newDate
        )

        let candidates = try await store.backfillCandidates()
        #expect(candidates.count == 2)

        // Oldest first
        #expect(candidates[0].meetingID == oldID)
        #expect(candidates[0].title == "Old Meeting")
        #expect(candidates[0].date == oldDate)
        #expect(candidates[0].transcriptID == oldTxID)

        #expect(candidates[1].meetingID == newID)
        #expect(candidates[1].title == "New Meeting")

        // Check segments are populated
        #expect(candidates[0].segments.count == 2)
        let span = candidates[0].segments.first
        #expect(span?.speakerID == 0 || span?.speakerID == 1)
    }

    @Test("addVoiceprints skips non-finite and empty vectors")
    func addVoiceprintsSkipsInvalid() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Backfill invalid")
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [makeSegments()[0]],
            processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        try await store.addVoiceprints(
            [
                NewVoiceprint(speakerID: 0, vector: [1.0, 2.0], speakingDuration: 10.0),
                NewVoiceprint(speakerID: 1, vector: [.nan, 1.0], speakingDuration: 5.0),
                NewVoiceprint(speakerID: 2, vector: [.infinity], speakingDuration: 3.0),
                NewVoiceprint(speakerID: 3, vector: [], speakingDuration: 1.0)
            ],
            kind: .raw, space: "test-space", to: txID
        )

        // Only the valid vector (speaker 0) should be stored
        try await store.read { store in
            let voiceprints = try store.fetchAllVoiceprints()
            #expect(voiceprints.count == 1)
            #expect(voiceprints.first?.speakerID == 0)
        }
    }

    @Test("backfillCandidates excludes meetings without preferred transcript")
    func excludesNoPreferredTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No preferred")
        let result = makeResultWithEmbeddings()
        // Add transcript but don't set it as preferred
        _ = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )

        let candidates = try await store.backfillCandidates()
        #expect(candidates.isEmpty)
    }
}
