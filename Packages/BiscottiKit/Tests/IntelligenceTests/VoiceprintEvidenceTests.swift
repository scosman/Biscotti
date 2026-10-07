import DataStore
import Foundation
import LocalLLM
import Testing
import Transcription
@testable import Intelligence

// MARK: - VoiceprintEvidence Tests

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private func makeTranscriptResult(speakerCount: Int = 2) -> TranscriptResult {
    let seg1 = TranscriptSegment(
        speakerID: 0, speakerLabel: "Speaker 0",
        startTime: 0, endTime: 5,
        text: "Hello everyone", confidence: 0.9,
        noSpeechProbability: 0.1, words: nil
    )
    let seg2 = TranscriptSegment(
        speakerID: 1, speakerLabel: "Speaker 1",
        startTime: 5, endTime: 10,
        text: "Hi there", confidence: 0.85,
        noSpeechProbability: 0.15, words: nil
    )
    return TranscriptResult(
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: speakerCount,
        segments: [seg1, seg2],
        processingDuration: 2.0
    )
}

private func makeMeetingWithTranscript(
    store: DataStore, title: String = "Test Meeting"
) async throws -> (UUID, UUID) {
    let meetingID = try await store.createMeeting(title: title)
    let result = makeTranscriptResult()
    let transcriptID = try await store.addTranscript(
        result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(transcriptID, for: meetingID)
    return (meetingID, transcriptID)
}

@Suite("VoiceprintEvidence")
struct VoiceprintEvidenceTests {
    @Test("block returns empty string when no voiceprints exist")
    func noVoiceprints() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)
        let detail = try #require(try await store.meetingDetail(id: meetingID))
        let transcript = try #require(detail.preferredTranscript)

        let block = await VoiceprintEvidence.block(
            store: store, meetingID: meetingID,
            transcript: transcript, detail: detail, human: [:]
        )
        #expect(block == "")
    }

    @Test("block returns empty when corpus has no history")
    func emptyCorpus() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let dim = 128
        let vector = [Float](repeating: 0.1, count: dim)
        try await store.addVoiceprints(
            [NewVoiceprint(speakerID: 0, vector: vector, speakingDuration: 10)],
            kind: .raw, space: "test-space", to: transcriptID
        )

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        let transcript = try #require(detail.preferredTranscript)

        let block = await VoiceprintEvidence.block(
            store: store, meetingID: meetingID,
            transcript: transcript, detail: detail, human: [:]
        )
        #expect(block == "")
    }

    @Test("compute returns result with corpus and matches")
    func computeWithCorpus() async throws {
        let store = try makeStore()
        let dim = 128

        let (_, transcriptID1) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 1"
        )
        let vector1 = [Float](repeating: 0.1, count: dim)
        try await store.addVoiceprints(
            [NewVoiceprint(speakerID: 0, vector: vector1, speakingDuration: 30)],
            kind: .raw, space: "test-space", to: transcriptID1
        )

        let (meetingID2, transcriptID2) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 2"
        )
        let vector2 = [Float](repeating: 0.1, count: dim)
        try await store.addVoiceprints(
            [NewVoiceprint(speakerID: 0, vector: vector2, speakingDuration: 20)],
            kind: .raw, space: "test-space", to: transcriptID2
        )

        let detail = try #require(try await store.meetingDetail(id: meetingID2))
        let transcript = try #require(detail.preferredTranscript)

        let result = try await VoiceprintEvidence.compute(
            store: store, meetingID: meetingID2,
            transcript: transcript, detail: detail, human: [:]
        )

        #expect(result.corpus.entryCount > 0)
        #expect(result.queryVectors[0] != nil)
    }

    @Test("block suppresses errors gracefully")
    func blockSuppressesErrors() async throws {
        let store = try makeStore()
        let fakeID = UUID()
        let detail = MeetingDetailData(
            id: fakeID, title: "Ghost", date: Date(),
            duration: nil, hasAudio: false,
            preferredTranscript: nil
        )
        let transcript = TranscriptData(
            id: UUID(), createdAt: Date(), speakerCount: 1,
            segments: [SegmentData(
                id: UUID(),
                speakerID: 0, speakerLabel: "Speaker 0",
                startTime: 0, endTime: 5, text: "Hello"
            )]
        )

        let block = await VoiceprintEvidence.block(
            store: store, meetingID: fakeID,
            transcript: transcript, detail: detail, human: [:]
        )
        #expect(block == "")
    }
}
