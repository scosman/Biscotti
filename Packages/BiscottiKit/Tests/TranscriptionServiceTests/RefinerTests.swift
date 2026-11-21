import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
import TranscriptionService
import Vocabulary

/// The speaker-naming hook.
@Suite("TranscriptionService -- refiner")
struct TranscriptionRefinerTests {
    @MainActor
    static func service() throws -> (TranscriptionService, DataStore) {
        let store = try DataStore(storage: .inMemory)
        let service = TranscriptionService(
            store: store, engine: FakeTranscriber(), vocabulary: VocabularyService(store: store)
        )
        return (service, store)
    }

    @MainActor
    static func meeting(_ store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: "Refined")
        try await store.attachAudio([
            AudioFileRef(role: .mic, path: "/tmp/test/mic.aac", byteSize: 1, isPresent: true),
            AudioFileRef(role: .system, path: "/tmp/test/system.aac", byteSize: 1, isPresent: true)
        ], to: meetingID)
        return meetingID
    }

    @Test("A refined transcript becomes preferred, keeps the original, and its names stick")
    @MainActor
    func refinedTranscriptIsPreferred() async throws {
        let (service, store) = try Self.service()
        let meetingID = try await Self.meeting(store)
        service.refiner = { _, original, _ in
            let segment = TranscriptSegment(
                speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 1,
                text: "Named line", confidence: 0, noSpeechProbability: 0, words: nil
            )
            let result = TranscriptResult(
                transcriptionMethodId: original.transcriptionMethodId, language: "en",
                speakerCount: 1, segments: [segment], processingDuration: 0
            )
            return RefinedTranscript(result: result, speakerNames: [0: "Sam Carter"])
        }

        await service.transcribe(meetingID: meetingID)

        #expect(service.jobs[meetingID] == .completed)
        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.versions.count == 2)
        #expect(detail.preferredTranscript?.segments.first?.text == "Named line")
        #expect(detail.preferredTranscript?.speakerName(forID: 0) == "Sam Carter")
    }

    @Test("No refined transcript leaves the engine's as preferred")
    @MainActor
    func nilRefinerResultKeepsOriginal() async throws {
        let (service, store) = try Self.service()
        let meetingID = try await Self.meeting(store)
        service.refiner = { _, _, _ in nil }

        await service.transcribe(meetingID: meetingID)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.versions.count == 1)
        #expect(detail.preferredTranscript?.segments.count == 2)
    }
}

/// Names set by hand survive re-transcription.
@Suite("TranscriptionService -- carry names over")
struct CarryOverTests {
    @Test("A hand-set name moves to the new transcript's matching speaker")
    @MainActor
    func handSetNameIsCarried() async throws {
        let store = try DataStore(storage: .inMemory)
        let engine = FakeTranscriber()
        let service = TranscriptionService(store: store, engine: engine, vocabulary: VocabularyService(store: store))
        let meetingID = try await TranscriptionRefinerTests.meeting(store)
        await service.transcribe(meetingID: meetingID)
        let first = try #require(try await store.meetingDetail(id: meetingID)?.preferredTranscript)
        let nora = try await store.findOrCreatePerson(name: "Nora Hale", email: nil)
        let speaker = try #require(first.segments.first?.speakerID)
        try await store.setSpeakerAssignment(speakerID: speaker, personID: nora, for: first.id)

        // Same audio, new run: a new transcript with the same speakers.
        let original = FakeTranscriber.defaultResult
        engine.backing.cannedResult = TranscriptResult(
            transcriptionMethodId: original.transcriptionMethodId, language: original.language,
            speakerCount: original.speakerCount, segments: original.segments.map {
                TranscriptSegment(
                    speakerID: $0.speakerID, speakerLabel: $0.speakerLabel, startTime: $0.startTime,
                    endTime: $0.endTime, text: $0.text, confidence: $0.confidence,
                    noSpeechProbability: $0.noSpeechProbability, words: $0.words
                )
            },
            processingDuration: original.processingDuration
        )
        await service.reTranscribe(meetingID: meetingID)

        let second = try #require(try await store.meetingDetail(id: meetingID)?.preferredTranscript)
        #expect(second.id != first.id)
        #expect(second.speakerName(forID: speaker) == "Nora Hale")
        #expect(try await store.humanSetSpeakerMappings(for: second.id)[speaker]?.name == "Nora Hale")
    }

    @Test("Matching needs most of both speakers' time to line up")
    func matchingRules() {
        func line(_ speaker: Int, _ start: Double, _ end: Double) -> SegmentData {
            SegmentData(id: UUID(), speakerID: speaker, speakerLabel: "Speaker \(speaker)", startTime: start, endTime: end, text: "x")
        }
        let nora = UUID()
        let old = [line(3, 0, 10), line(3, 20, 30)]
        // New speaker 5 has Nora's time; speaker 6 has half of his plus lots of someone else's.
        let new = [line(5, 0, 10), line(5, 20, 29), line(6, 29, 30), line(6, 40, 80)]
        #expect(TranscriptionService.matchSpeakers(old: old, oldPeople: [3: nora], new: new) == [5: nora])
        let mixed = [line(7, 0, 10), line(7, 40, 80)]
        #expect(TranscriptionService.matchSpeakers(old: old, oldPeople: [3: nora], new: mixed).isEmpty)
    }
}
