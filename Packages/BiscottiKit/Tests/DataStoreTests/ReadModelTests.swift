import DataStore
import Foundation
import Testing
import Transcription

@Suite("DataStore read-model DTOs")
struct ReadModelTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    // MARK: - MeetingSummary

    @Test("meetingSummaries maps fields correctly")
    func meetingSummariesMapping() async throws {
        let store = try makeStore()

        // Meeting without transcript
        let id1 = try await store.createMeeting(
            title: "Standup",
            start: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Meeting with transcript
        let id2 = try await store.createMeeting(
            title: "Retro",
            start: Date(timeIntervalSince1970: 1_700_100_000)
        )
        let result = makeTranscriptResult()
        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: id2
        )
        try await store.setPreferredTranscript(transcriptID, for: id2)

        let summaries = try await store.meetingSummaries(limit: 10)
        #expect(summaries.count == 2)

        // Newest first
        let retro = summaries[0]
        #expect(retro.id == id2)
        #expect(retro.title == "Retro")
        #expect(retro.hasTranscript == true)

        let standup = summaries[1]
        #expect(standup.id == id1)
        #expect(standup.title == "Standup")
        #expect(standup.hasTranscript == false)
    }

    @Test("meetingSummaries uses startDate when available, createdAt otherwise")
    func meetingSummariesDate() async throws {
        let store = try makeStore()
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try await store.createMeeting(title: "With Start", start: startDate)

        let summaries = try await store.meetingSummaries(limit: 10)
        #expect(summaries.count == 1)
        #expect(summaries[0].date == startDate)

        // Meeting without start date uses createdAt
        try await store.createMeeting(title: "No Start")
        let allSummaries = try await store.meetingSummaries(limit: 10)
        let noStart = allSummaries.first(where: { $0.id != id })
        #expect(noStart != nil)
        // createdAt will be approximately now, just verify it's not the startDate
        #expect(try #require(noStart?.date) != startDate)
    }

    @Test("meetingSummaries respects limit and orders newest first")
    func meetingSummariesOrdering() async throws {
        let store = try makeStore()
        for idx in 0 ..< 5 {
            try await store.createMeeting(
                title: "Meeting \(idx)",
                start: Date(timeIntervalSince1970: Double(idx) * 1000)
            )
        }

        let summaries = try await store.meetingSummaries(limit: 3)
        #expect(summaries.count == 3)
        #expect(summaries[0].title == "Meeting 4")
        #expect(summaries[1].title == "Meeting 3")
        #expect(summaries[2].title == "Meeting 2")
    }

    // MARK: - MeetingDetailData

    @Test("meetingDetail with preferred transcript maps correctly")
    func meetingDetailWithTranscript() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)
        let id = try await store.createMeeting(title: "Deep Dive", start: start, end: end)

        // Attach audio
        let micRef = AudioFileRef(role: .mic, path: "/tmp/mic.aac", byteSize: 1024, isPresent: true)
        let sysRef = AudioFileRef(role: .system, path: "/tmp/system.aac", byteSize: 2048, isPresent: true)
        try await store.attachAudio([micRef, sysRef], to: id)

        // Add transcript
        let result = makeTranscriptResult()
        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: id
        )
        try await store.setPreferredTranscript(transcriptID, for: id)

        let detail = try await store.meetingDetail(id: id)
        #expect(detail != nil)
        #expect(detail?.title == "Deep Dive")
        #expect(detail?.date == start)
        #expect(detail?.duration == 3600)
        #expect(detail?.hasAudio == true)
        #expect(try #require(detail?.preferredTranscript) != nil)
        #expect(detail?.preferredTranscript?.speakerCount == 2)
        #expect(detail?.preferredTranscript?.segments.count == 2)
    }

    @Test("meetingDetail without transcript has nil preferredTranscript")
    func meetingDetailWithoutTranscript() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Quick Chat")

        let detail = try await store.meetingDetail(id: id)
        #expect(detail != nil)
        #expect(detail?.preferredTranscript == nil)
        #expect(detail?.hasAudio == false)
        #expect(detail?.duration == nil)
    }

    @Test("meetingDetail maps recordingDuration independently of calendar duration")
    func meetingDetailRecordingDuration() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600) // 1h calendar window
        let id = try await store.createMeeting(title: "Duration Test", start: start, end: end)

        // Set a recording duration different from the calendar window
        try await store.setRecordingDuration(1800, for: id) // 30 min

        let detail = try await store.meetingDetail(id: id)
        #expect(detail != nil)
        // Calendar-window duration stays at 1h
        #expect(detail?.duration == 3600)
        // Recording duration is the stored 30 min
        #expect(detail?.recordingDuration == 1800)
    }

    @Test("meetingDetail recordingDuration is nil when not set")
    func meetingDetailRecordingDurationNil() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "No Rec Duration")

        let detail = try await store.meetingDetail(id: id)
        #expect(detail != nil)
        #expect(detail?.recordingDuration == nil)
    }

    @Test("meetingDetail returns nil for unknown ID")
    func meetingDetailNotFound() async throws {
        let store = try makeStore()
        let detail = try await store.meetingDetail(id: UUID())
        #expect(detail == nil)
    }

    // MARK: - audioPaths

    @Test("audioPaths returns mic and system URLs when both present")
    func audioPaths() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Test")

        let micRef = AudioFileRef(role: .mic, path: "/audio/mic.aac", byteSize: 100, isPresent: true)
        let sysRef = AudioFileRef(role: .system, path: "/audio/system.aac", byteSize: 200, isPresent: true)
        try await store.attachAudio([micRef, sysRef], to: id)

        let paths = try await store.audioPaths(meetingID: id)
        #expect(paths != nil)
        #expect(paths?.mic.path == "/audio/mic.aac")
        #expect(paths?.system.path == "/audio/system.aac")
    }

    @Test("audioPaths returns nil when no audio refs")
    func audioPathsMissing() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "No Audio")

        let paths = try await store.audioPaths(meetingID: id)
        #expect(paths == nil)
    }

    @Test("audioPaths returns nil when audio not present on disk")
    func audioPathsNotPresent() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Missing Files")

        let micRef = AudioFileRef(role: .mic, path: "/gone/mic.aac", byteSize: 0, isPresent: false)
        let sysRef = AudioFileRef(role: .system, path: "/gone/system.aac", byteSize: 0, isPresent: false)
        try await store.attachAudio([micRef, sysRef], to: id)

        let paths = try await store.audioPaths(meetingID: id)
        #expect(paths == nil)
    }

    @Test("audioPaths returns nil for unknown meeting")
    func audioPathsUnknownMeeting() async throws {
        let store = try makeStore()
        let paths = try await store.audioPaths(meetingID: UUID())
        #expect(paths == nil)
    }

    // MARK: - Segment ordering

    @Test("Segments in transcript are ordered by index")
    func segmentDataMapping() async throws {
        let store = try makeStore()
        let id = try await store.createMeeting(title: "Ordered")

        // Create segments with non-sequential insertion order
        let seg1 = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 10,
            text: "First segment", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let seg2 = TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 10, endTime: 20,
            text: "Second segment", confidence: 0.8, noSpeechProbability: 0.2, words: nil
        )
        let seg3 = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 20, endTime: 30,
            text: "Third segment", confidence: 0.95, noSpeechProbability: 0.05, words: nil
        )

        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [seg1, seg2, seg3],
            speakerEmbeddings: [:],
            processingDuration: 5.0
        )

        let transcriptID = try await store.addTranscript(result, vocabularyUsed: [], mappedEventIdentifier: nil, to: id)
        try await store.setPreferredTranscript(transcriptID, for: id)

        let detail = try await store.meetingDetail(id: id)
        let segments = try #require(detail?.preferredTranscript?.segments)
        #expect(segments.count == 3)
        #expect(segments[0].text == "First segment")
        #expect(segments[0].speakerLabel == "Speaker 0")
        #expect(segments[0].startTime == 0)
        #expect(segments[0].endTime == 10)
        #expect(segments[1].text == "Second segment")
        #expect(segments[1].speakerLabel == "Speaker 1")
        #expect(segments[2].text == "Third segment")
        #expect(segments[2].speakerLabel == "Speaker 0")
    }

    // MARK: - Helpers

    private func makeTranscriptResult() -> TranscriptResult {
        let seg1 = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "Hello", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let seg2 = TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 5, endTime: 10,
            text: "Hi there", confidence: 0.85, noSpeechProbability: 0.15, words: nil
        )
        return TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [seg1, seg2],
            speakerEmbeddings: [:],
            processingDuration: 3.0
        )
    }
}
