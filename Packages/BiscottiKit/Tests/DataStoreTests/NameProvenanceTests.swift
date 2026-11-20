import DataStore
import Foundation
import Testing
import Transcription

/// Every speaker name records where it came from.
struct NameProvenanceTests {
    private func makeTranscript(_ store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: "Provenance")
        return try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 4, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
    }

    @Test func labelsMarkOnlyUncertainNames() {
        #expect(SpeakerNameProvenance.confirmed.label("Nora Hale") == "Nora Hale")
        #expect(SpeakerNameProvenance(source: .screen, confidence: .high).label("Nora Hale") == "Nora Hale")
        #expect(SpeakerNameProvenance(source: .screen, confidence: .medium).label("Nora Hale") == "Nora Hale (likely)")
        #expect(SpeakerNameProvenance(source: .voice, confidence: .low).label("Nora Hale") == "Nora Hale (unsure)")
        #expect(SpeakerNameProvenance(source: .guess, confidence: .high).label("Nora Hale") == "Nora Hale (guess)")
    }

    @Test func aGuessIsAlwaysLowAndNeverTrusted() {
        let guess = SpeakerNameProvenance(source: .guess, confidence: .high)
        #expect(guess.confidence == .low)
        #expect(!guess.isTrusted)
        #expect(guess.badgeText == "Guess")
    }

    @Test func onlyStrongAutomaticNamesAreTrusted() {
        #expect(SpeakerNameProvenance(source: .screen, confidence: .high).isTrusted)
        #expect(!SpeakerNameProvenance(source: .screen, confidence: .medium).isTrusted)
        #expect(!SpeakerNameProvenance(source: .voice, confidence: .high).isTrusted)
        #expect(SpeakerNameProvenance(source: .microphone, confidence: .high).isTrusted)
    }

    @Test func olderEntriesReadAsConfirmedOrGuess() throws {
        let person = UUID()
        let json = """
        {"1":{"personID":"\(person.uuidString)","userSet":true},"2":{"personID":"\(person.uuidString)","userSet":false}}
        """
        let decoded = try JSONDecoder().decode([Int: SpeakerAssignmentEntry].self, from: Data(json.utf8))
        #expect(decoded[1]?.effectiveProvenance.source == .confirmed)
        #expect(decoded[2]?.effectiveProvenance.source == .guess)
    }

    @Test func provenanceIsSavedAndReadBack() async throws {
        let store = try DataStore(storage: .inMemory)
        let transcriptID = try await makeTranscript(store)
        let nora = try await store.findOrCreatePerson(name: "Nora Hale", email: nil)
        let screen = SpeakerNameProvenance(
            source: .screen, confidence: .medium, detail: "Highlighted on screen in 3 of 5 turns"
        )
        try await store.setSpeakerAssignment(speakerID: 1, personID: nora, provenance: screen, for: transcriptID)
        let transcript = try #require(try await store.transcript(id: transcriptID))
        #expect(transcript.speakerProvenance[1] == screen)
        #expect(transcript.labeledSpeakerNames[1] == "Nora Hale (likely)")
        // Medium isn't trusted, so it isn't treated like a hand-set name.
        #expect(try await store.humanSetSpeakerMappings(for: transcriptID).isEmpty)
    }

    @Test func aiGuessesDontReplaceScreenNames() async throws {
        let store = try DataStore(storage: .inMemory)
        let transcriptID = try await makeTranscript(store)
        let nora = try await store.findOrCreatePerson(name: "Nora Hale", email: nil)
        let tyler = try await store.findOrCreatePerson(name: "Tyler Grant", email: nil)
        let mike = try await store.findOrCreatePerson(name: "Mike Brooks", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: nora,
            provenance: SpeakerNameProvenance(source: .screen, confidence: .low), for: transcriptID
        )
        try await store.setSpeakerAssignments([1: tyler, 2: nora, 3: mike], for: transcriptID)
        let transcript = try #require(try await store.transcript(id: transcriptID))
        #expect(transcript.speakerAssignments[1]?.name == "Nora Hale")
        #expect(transcript.speakerAssignments[2] == nil)
        #expect(transcript.speakerAssignments[3]?.name == "Mike Brooks")
        #expect(transcript.speakerProvenance[3]?.source == .guess)
        #expect(transcript.labeledSpeakerNames[3] == "Mike Brooks (guess)")
    }

    @Test func handSetNamesAreConfirmed() async throws {
        let store = try DataStore(storage: .inMemory)
        let transcriptID = try await makeTranscript(store)
        let sam = try await store.findOrCreatePerson(name: "Sam Carter", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: sam, for: transcriptID)
        let transcript = try #require(try await store.transcript(id: transcriptID))
        #expect(transcript.speakerProvenance[0]?.source == .confirmed)
        #expect(try await store.confirmedSpeakerMappings(for: transcriptID)[0]?.name == "Sam Carter")
    }
}
