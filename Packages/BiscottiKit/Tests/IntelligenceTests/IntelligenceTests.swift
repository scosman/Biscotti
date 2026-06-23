import DataStore
import Foundation
import LocalLLM
import Testing
import Transcription
@testable import Intelligence

// MARK: - Fakes

/// Records all calls and returns scripted responses.
final class FakeLLMRunner: LLMRunning, @unchecked Sendable {
    /// Number of times `withSession` was called.
    var sessionCount = 0
    /// The session used by the runner.
    let session: FakeSession

    init(session: FakeSession = FakeSession()) {
        self.session = session
    }

    /// The most recently passed `EngineConfig`.
    var lastConfig: EngineConfig?

    func withSession<T: Sendable>(
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        sessionCount += 1
        lastConfig = config
        return try await body(session)
    }
}

/// Fake session that records generate/generateStreaming calls and returns
/// scripted responses. Uses the messages API.
final class FakeSession: LLMSession, @unchecked Sendable {
    /// Recorded message lists from generate calls.
    var generateCalls: [[LLMMessage]] = []
    /// Scripted responses for sequential generate calls.
    var generateResponses: [String] = []
    /// Error to throw on generate (if set).
    var generateError: (any Error)?

    /// Recorded message lists from generateStreaming calls.
    var streamingCalls: [[LLMMessage]] = []
    /// Scripted token sequences for streaming calls.
    var streamingTokens: [[String]] = []
    /// When set, the `.done` event carries this text instead of the joined
    /// tokens. Used to test that the summary path prefers canonical `.done` text.
    var canonicalDoneText: String?

    /// Canned token count for `countTokens`. Returns this value for every call.
    var tokenCount: Int = 100

    /// Recorded reconfigure calls (context sizes).
    var reconfigureCalls: [Int] = []

    private var generateCallIndex = 0
    private var streamingCallIndex = 0

    func countTokens(
        messages _: [LLMMessage]
    ) async throws -> Int {
        tokenCount
    }

    func reconfigure(contextSize: Int) async throws {
        reconfigureCalls.append(contextSize)
    }

    func generate(
        messages: [LLMMessage], options _: GenerationOptions
    ) async throws -> String {
        generateCalls.append(messages)
        if let error = generateError {
            throw error
        }
        let idx = generateCallIndex
        generateCallIndex += 1
        guard idx < generateResponses.count else {
            return ""
        }
        return generateResponses[idx]
    }

    func generateStreaming(
        messages: [LLMMessage], options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        streamingCalls.append(messages)
        let idx = streamingCallIndex
        streamingCallIndex += 1

        let tokens: [String] = if idx < streamingTokens.count {
            streamingTokens[idx]
        } else {
            []
        }

        let doneText = canonicalDoneText ?? tokens.joined()
        let result = makeGenerationResult(text: doneText)
        let events: [StreamEvent] =
            tokens.map { .token($0) } + [.done(result)]
        var iterator = events.makeIterator()
        return AsyncThrowingStream {
            iterator.next()
        }
    }
}

/// Constructs a `GenerationResult` via JSON decoding. The struct has no
/// public init (memberwise is internal to LocalLLM), but it is `Codable`.
private func makeGenerationResult(text: String) -> GenerationResult {
    let json: [String: Any] = [
        "text": text,
        "promptTokenCount": 0,
        "generatedTokenCount": 1,
        "cachedPromptTokenCount": 0,
        "finishReason": ["endOfTurn": [String: Any]()],
        "promptEvalDuration": 0.0,
        "generationDuration": 0.0,
        "totalDuration": 0.0,
        "renderedPrompt": "",
        "rawText": text
    ]
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: json)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(GenerationResult.self, from: data)
}

/// Fake model provider with toggleable download state.
final class FakeModelProvider: ModelProviding, @unchecked Sendable {
    var downloaded: Bool
    let modelURL: URL

    var downloadCalled = false
    var downloadShouldFail = false
    var downloadProgress: [(Int64, Int64?)] = []

    init(downloaded: Bool = true) {
        self.downloaded = downloaded
        modelURL = URL(fileURLWithPath: "/fake/model.gguf")
    }

    func isDownloaded() -> Bool {
        downloaded
    }

    func download(
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        downloadCalled = true
        for (bytes, total) in downloadProgress {
            progress(bytes, total)
        }
        if downloadShouldFail {
            throw NSError(
                domain: "FakeDownload", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download failed"]
            )
        }
        downloaded = true
    }
}

/// An LLM runner that blocks in `withSession` until explicitly released.
final class BlockingLLMRunner: LLMRunning, @unchecked Sendable {
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let (eStream, eCont) = AsyncStream<Void>.makeStream()
        enteredStream = eStream
        enteredContinuation = eCont
        let (rStream, rCont) = AsyncStream<Void>.makeStream()
        releaseStream = rStream
        releaseContinuation = rCont
    }

    func waitUntilEntered() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield()
    }

    func withSession<T: Sendable>(
        config _: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        enteredContinuation.yield()
        var iterator = releaseStream.makeAsyncIterator()
        _ = await iterator.next()
        return try await body(FakeSession())
    }
}

// MARK: - Shared helpers

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
    let seg3 = TranscriptSegment(
        speakerID: 0, speakerLabel: "Speaker 0",
        startTime: 10, endTime: 15,
        text: "Let's get started", confidence: 0.95,
        noSpeechProbability: 0.05, words: nil
    )
    return TranscriptResult(
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: speakerCount,
        segments: [seg1, seg2, seg3],
        speakerEmbeddings: [:],
        processingDuration: 3.0
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

/// Groups the Intelligence service and its fakes for test convenience.
struct IntelligenceFixture {
    let intel: Intelligence
    let runner: FakeLLMRunner
    let models: FakeModelProvider
}

@MainActor private func makeIntelligence(
    store: DataStore,
    session: FakeSession = FakeSession(),
    downloaded: Bool = true,
    enabled: Bool = true
) -> IntelligenceFixture {
    let runner = FakeLLMRunner(session: session)
    let models = FakeModelProvider(downloaded: downloaded)
    let settings = AISettings(enabled: enabled)
    let intel = Intelligence(
        store: store, llm: runner, models: models,
        settings: { settings }
    )
    return IntelligenceFixture(intel: intel, runner: runner, models: models)
}

// MARK: - SpeakerMappingParser Tests

@Suite("SpeakerMappingParser")
struct SpeakerMappingParserTests {
    @Test("parses well-formed lines")
    func wellFormed() {
        let raw = """
        0 | Daniel Lee | daniel@acme.com
        1 | Priya Patel |
        """
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.count == 2)
        #expect(result[0]?.name == "Daniel Lee")
        #expect(result[0]?.email == "daniel@acme.com")
        #expect(result[1]?.name == "Priya Patel")
        #expect(result[1]?.email == nil)
    }

    @Test("strips code fences")
    func codeFenced() {
        let raw = """
        ```
        0 | Alice | alice@x.com
        1 | Bob |
        ```
        """
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.count == 2)
        #expect(result[0]?.name == "Alice")
        #expect(result[0]?.email == "alice@x.com")
        #expect(result[1]?.name == "Bob")
    }

    @Test("blank email field yields nil")
    func blankEmail() {
        let raw = "0 | Alice |  "
        let result = SpeakerMappingParser.parse(raw)
        #expect(result[0]?.email == nil)
    }

    @Test("extra prose around valid lines is ignored")
    func extraProse() {
        let raw = """
        Based on my analysis:
        0 | Daniel Lee | daniel@acme.com
        I'm not sure about the others.
        1 | Priya |
        That's my best guess.
        """
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.count == 2)
        #expect(result[0]?.name == "Daniel Lee")
        #expect(result[1]?.name == "Priya")
    }

    @Test("malformed lines are skipped")
    func malformed() {
        let raw = """
        0 | Alice | alice@x.com
        not a valid line
        x | BadIndex |
        | MissingIndex |
        2 |  |
        """
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.count == 1)
        #expect(result[0]?.name == "Alice")
    }

    @Test("fully garbage input yields empty map")
    func garbage() {
        let raw = "This is just random text with no valid speaker mappings."
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.isEmpty)
    }

    @Test("empty input yields empty map")
    func emptyInput() {
        let result = SpeakerMappingParser.parse("")
        #expect(result.isEmpty)
    }

    @Test("duplicate index uses last wins")
    func duplicateIndex() {
        let raw = """
        0 | Alice |
        0 | Bob |
        """
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.count == 1)
        #expect(result[0]?.name == "Bob")
    }

    @Test("negative index is skipped")
    func negativeIndex() {
        let raw = "-1 | Alice |"
        let result = SpeakerMappingParser.parse(raw)
        #expect(result.isEmpty)
    }
}

// MARK: - TranscriptFormatter Tests

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {
    @Test("produces correct turn-per-line with names")
    func withNames() {
        let transcript = TranscriptData(
            id: UUID(), createdAt: Date(), speakerCount: 2,
            segments: [
                SegmentData(
                    id: UUID(), speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5, text: "Hello"
                ),
                SegmentData(
                    id: UUID(), speakerID: 1,
                    speakerLabel: "Speaker 1",
                    startTime: 5, endTime: 10, text: "Hi there"
                )
            ]
        )
        let result = TranscriptFormatter.plain(
            transcript, names: [0: "Alice", 1: "Bob"]
        )
        #expect(result == "Alice: Hello\nBob: Hi there")
    }

    @Test("falls back to speakerLabel when no name")
    func fallbackToLabel() {
        let transcript = TranscriptData(
            id: UUID(), createdAt: Date(), speakerCount: 2,
            segments: [
                SegmentData(
                    id: UUID(), speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5, text: "Hello"
                ),
                SegmentData(
                    id: UUID(), speakerID: 1,
                    speakerLabel: "Speaker 1",
                    startTime: 5, endTime: 10, text: "Hi"
                )
            ]
        )
        let result = TranscriptFormatter.plain(
            transcript, names: [0: "Alice"]
        )
        #expect(result == "Alice: Hello\nSpeaker 1: Hi")
    }

    @Test("collapses consecutive same-speaker segments")
    func collapseSameSpeaker() {
        let transcript = TranscriptData(
            id: UUID(), createdAt: Date(), speakerCount: 1,
            segments: [
                SegmentData(
                    id: UUID(), speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5, text: "Hello"
                ),
                SegmentData(
                    id: UUID(), speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 5, endTime: 10, text: "everyone"
                ),
                SegmentData(
                    id: UUID(), speakerID: 1,
                    speakerLabel: "Speaker 1",
                    startTime: 10, endTime: 15, text: "Hi"
                )
            ]
        )
        let result = TranscriptFormatter.plain(transcript, names: [:])
        #expect(result == "Speaker 0: Hello everyone\nSpeaker 1: Hi")
    }

    @Test("empty transcript produces empty string")
    func emptyTranscript() {
        let transcript = TranscriptData(
            id: UUID(), createdAt: Date(), speakerCount: 0, segments: []
        )
        let result = TranscriptFormatter.plain(transcript, names: [:])
        #expect(result == "")
    }
}

// MARK: - IntelligencePrompts Tests

@Suite("IntelligencePrompts")
struct IntelligencePromptsTests {
    @Test("analysisSystem is non-empty")
    func analysisSystemNonEmpty() {
        #expect(!IntelligencePrompts.analysisSystem.isEmpty)
    }

    @Test("meetingDetailsBlock includes title and date")
    func meetingDetailsBlockBasic() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Standup", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(result.contains("<meeting_details>"))
        #expect(result.contains("Title: Standup"))
        #expect(result.contains("Date:"))
        #expect(result.contains("</meeting_details>"))
    }

    @Test("meetingDetailsBlock omits empty title")
    func meetingDetailsBlockNoTitle() {
        let detail = MeetingDetailData(
            id: UUID(), title: "", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(!result.contains("Title:"))
        // Should still have the date line
        #expect(result.contains("Date:"))
    }

    @Test("meetingDetailsBlock includes end date when present")
    func meetingDetailsBlockWithEndDate() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Meeting", date: Date(),
            endDate: Date().addingTimeInterval(3600),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(result.contains(" - "))
    }

    @Test("meetingDetailsBlock omits location when absent")
    func meetingDetailsBlockNoLocation() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Meeting", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(!result.contains("Location:"))
    }

    @Test("meetingDetailsBlock includes calendar fields")
    func meetingDetailsBlockCalendar() {
        let calendar = CalendarContextData(
            conferencePlatform: "Zoom",
            location: "Room 42",
            organizer: PersonData(id: UUID(), name: "Org", email: "org@x.com"),
            attendees: [PersonData(id: UUID(), name: "Att", email: "att@x.com")],
            eventNotes: "Discuss roadmap"
        )
        let detail = MeetingDetailData(
            id: UUID(), title: "Planning", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil,
            calendar: calendar
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(result.contains("Location: Room 42"))
        #expect(result.contains("Conference: Zoom"))
        #expect(result.contains("Invitees:"))
        #expect(result.contains("- Org <org@x.com>"))
        #expect(result.contains("- Att <att@x.com>"))
        #expect(result.contains("Description:\nDiscuss roadmap"))
    }

    @Test("meetingDetailsBlock omits empty eventNotes")
    func meetingDetailsBlockNoNotes() {
        let calendar = CalendarContextData(eventNotes: "")
        let detail = MeetingDetailData(
            id: UUID(), title: "Meeting", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil,
            calendar: calendar
        )
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(!result.contains("Description:"))
    }

    @Test("meetingDetailsBlock always includes date even when other fields empty")
    func meetingDetailsBlockMinimalFields() {
        let detail = MeetingDetailData(
            id: UUID(), title: "", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        // Date is non-optional, so the block always has at least a date line
        let result = IntelligencePrompts.meetingDetailsBlock(detail)
        #expect(result.contains("Date:"))
        #expect(!result.contains("Title:"))
    }

    @Test("userSpeakerMappingBlock renders entries sorted by key")
    func userSpeakerMappingBlock() {
        let human: [Int: PersonData] = [
            1: PersonData(id: UUID(), name: "Bob", email: "bob@x.com"),
            0: PersonData(id: UUID(), name: "Alice", email: nil)
        ]
        let result = IntelligencePrompts.userSpeakerMappingBlock(human)
        #expect(result.contains("<user_speaker_person_mapping>"))
        #expect(result.contains("0 | Alice | "))
        #expect(result.contains("1 | Bob | bob@x.com"))
        // Check sorted order: 0 before 1
        let lines = result.components(separatedBy: "\n")
        let dataLines = lines.filter { $0.contains("|") }
        #expect(dataLines[0].hasPrefix("0"))
        #expect(dataLines[1].hasPrefix("1"))
    }

    @Test("userSpeakerMappingBlock returns empty for empty map")
    func userSpeakerMappingBlockEmpty() {
        let result = IntelligencePrompts.userSpeakerMappingBlock([:])
        #expect(result == "")
    }

    @Test("analysisFirstUser includes transcript with Speaker-N labels and speaker task")
    func analysisFirstUserContent() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            transcriptSpeakerLabeled: "Speaker 0: Hello\nSpeaker 1: Hi"
        )
        #expect(result.contains("<transcript>"))
        #expect(result.contains("Speaker 0: Hello"))
        #expect(result.contains("Speaker 1: Hi"))
        #expect(result.contains("</transcript>"))
        #expect(result.contains("Match diarization speakers"))
        #expect(result.contains("<speakerIndex> | <Full Name>"))
    }

    @Test("summaryOnlyFirstUser includes named transcript and summary task")
    func summaryOnlyFirstUserContent() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.summaryOnlyFirstUser(
            detail: detail,
            transcriptNamed: "Alice: Hello\nBob: Hi"
        )
        #expect(result.contains("<transcript>"))
        #expect(result.contains("Alice: Hello"))
        #expect(result.contains("</transcript>"))
        #expect(result.contains("## Action Items"))
        #expect(!result.contains("Match diarization"))
    }

    @Test("summaryFollowUpUser is the summary instructions")
    func summaryFollowUpContent() {
        #expect(IntelligencePrompts.summaryFollowUpUser.contains("## Action Items"))
        #expect(!IntelligencePrompts.summaryFollowUpUser.contains("<transcript>"))
    }
}

// MARK: - Intelligence Orchestration Tests

@Suite("Intelligence orchestration")
struct IntelligenceOrchestrationTests {
    @Test("auto-run runs speaker-ID then summary in one session (multi-turn)")
    @MainActor func bothTasks() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |\n1 | Bob |"]
        session.streamingTokens = [["## Meeting Notes\n", "Summary text"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 1)
        // Speaker-ID = buffered generate, Summary = streaming
        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.count == 1)

        // Verify multi-turn message sequencing
        let speakerMsgs = session.generateCalls[0]
        #expect(speakerMsgs.count == 2) // system + user
        #expect(speakerMsgs[0].role == .system)
        #expect(speakerMsgs[1].role == .user)

        let summaryMsgs = session.streamingCalls[0]
        #expect(summaryMsgs.count == 4) // system + user + assistant + user
        #expect(summaryMsgs[0].role == .system)
        #expect(summaryMsgs[1].role == .user)
        #expect(summaryMsgs[2].role == .assistant)
        #expect(summaryMsgs[2].content == "0 | Alice |\n1 | Bob |") // verbatim
        #expect(summaryMsgs[3].role == .user)

        // KV-reuse invariant: summary follow-up is lean (just summary
        // instructions), NOT a second copy of the transcript.
        let followUp = summaryMsgs[3].content
        #expect(!followUp.contains("<transcript>"))
        #expect(!followUp.contains("Hello everyone"))
        #expect(followUp.contains("## Action Items")) // summary instructions

        #expect(fixture.intel.jobs[meetingID] == .completed)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "## Meeting Notes\nSummary text")
        #expect(detail?.editedSummary == false)

        let transcript = detail?.preferredTranscript
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
        #expect(transcript?.speakerAssignments[1]?.name == "Bob")
    }

    @Test("auto-run skips speakers when all are human-set (summary-only)")
    @MainActor func allSpeakersHumanSet() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(store: store)

        // Manually assign both speakers
        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)

        let session = FakeSession()
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 1)
        #expect(session.generateCalls.isEmpty) // No speaker-ID
        #expect(session.streamingCalls.count == 1) // Summary only

        // Summary-only uses named transcript (single turn)
        let msgs = session.streamingCalls[0]
        #expect(msgs.count == 2) // system + user (no multi-turn)
        // Transcript should use resolved names, not Speaker-N
        #expect(msgs[1].content.contains("Alice:"))
    }

    @Test("auto-run with settings disabled is no-op")
    @MainActor func settingsDisabled() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let fixture = makeIntelligence(store: store, enabled: false)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
        #expect(fixture.intel.jobs[meetingID] == nil)
    }

    @Test("no model is no-op and clears preparing status")
    @MainActor func noModel() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let fixture = makeIntelligence(store: store, downloaded: false)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
        #expect(fixture.intel.jobs[meetingID] == nil)
    }

    @Test("edited-summary guard skips summary but runs speaker-ID")
    @MainActor func editedSummaryGuard() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        try await store.setSummary("My notes", for: meetingID)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.isEmpty)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "My notes")
        #expect(detail?.editedSummary == true)
    }

    @Test("no-session when both tasks skipped (all human-set + edited summary)")
    @MainActor func noSessionWhenBothSkipped() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(store: store)

        // All speakers human-set
        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)

        // Summary edited
        try await store.setSummary("My notes", for: meetingID)

        let fixture = makeIntelligence(store: store)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("streaming accumulation flows into streamingSummary")
    @MainActor func streamingAccumulation() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.streamingTokens = [["Hello", " World"]]

        // Set up all human-set speakers so only summary runs (simpler test)
        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.intel.streamingSummary[meetingID] == nil)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Hello World")
    }

    @Test("failure sets status to .failed")
    @MainActor func failureSetsStatus() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.generateError = NSError(
            domain: "Test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Test error"]
        )

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        if case let .failed(message) = fixture.intel.jobs[meetingID] {
            #expect(message.contains("Test error"))
        } else {
            Issue.record("Expected .failed status")
        }
    }

    @Test("no transcript is no-op")
    @MainActor func noTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Transcript")

        let fixture = makeIntelligence(store: store)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("second concurrent runAutoEnhancements is rejected")
    @MainActor func inFlightGuard() async throws {
        let store = try makeStore()
        let (meetingID1, _) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 1"
        )
        let (meetingID2, _) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 2"
        )

        let blocker = BlockingLLMRunner()
        let models = FakeModelProvider(downloaded: true)
        let intel = Intelligence(
            store: store, llm: blocker, models: models,
            settings: { AISettings(enabled: true) }
        )

        let task1 = Task { @MainActor in
            await intel.runAutoEnhancements(meetingID: meetingID1)
        }
        await blocker.waitUntilEntered()

        await intel.runAutoEnhancements(meetingID: meetingID2)
        #expect(intel.jobs[meetingID2] == nil)

        blocker.release()
        await task1.value
        #expect(intel.jobs[meetingID1] == .completed)
    }

    @Test("canonical .done text used over accumulated tokens")
    @MainActor func doneEventCanonicalText() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.streamingTokens = [["par", "tial"]]
        session.canonicalDoneText = "CANONICAL FINAL"

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "CANONICAL FINAL")
    }

    @Test("auto-enhancement opens model-only and reconfigures to right size")
    @MainActor func contextSizingAutoEnhancement() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]
        session.tokenCount = 500

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        let config = fixture.runner.lastConfig
        #expect(config != nil)
        #expect(config?.contextSize == 0)

        #expect(session.reconfigureCalls.count == 1)
        // Token count = 500 base + 512 assistant reserve = 1012
        let expectedContextSize = ContextSizing.contextSize(
            forInputTokens: session.tokenCount + MeetingAnalyzer.speakerOptions.maxTokens
        )
        #expect(session.reconfigureCalls.first == expectedContextSize)
    }
}

// MARK: - Intelligence runAnalysis Tests

@Suite("Intelligence runAnalysis")
struct IntelligenceRunAnalysisTests {
    @Test("manual runAnalysis works")
    @MainActor func manualRunAnalysis() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Generated summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        #expect(fixture.runner.sessionCount == 1)
        #expect(fixture.intel.jobs[meetingID] == .completed)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Generated summary")
        #expect(detail?.editedSummary == false)
    }

    @Test("manual runAnalysis ignores settings.enabled")
    @MainActor func manualIgnoresSettings() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]

        // settings disabled, but manual still runs
        let fixture = makeIntelligence(
            store: store, session: session, enabled: false
        )
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        #expect(fixture.runner.sessionCount == 1)
        #expect(fixture.intel.jobs[meetingID] == .completed)
    }

    @Test("manual runAnalysis respects editedSummary guard when not forced")
    @MainActor func editedGuardNotForced() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )
        try await store.setSummary("User's notes", for: meetingID)

        let session = FakeSession()
        // Speaker-ID still runs; summary is skipped
        session.generateResponses = ["0 | Alice |"]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        // Speaker-ID ran, summary did not
        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.isEmpty)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "User's notes")
    }

    @Test("manual runAnalysis with force overwrites edited summary")
    @MainActor func forceOverwrites() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )
        try await store.setSummary("User's notes", for: meetingID)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["New summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: true
        )

        #expect(fixture.runner.sessionCount == 1)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "New summary")
        #expect(detail?.editedSummary == false)
    }

    @Test("no model is no-op for manual runAnalysis")
    @MainActor func noModelManualRunAnalysis() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let fixture = makeIntelligence(store: store, downloaded: false)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("runAnalysis is rejected while another run is in-flight")
    @MainActor func runAnalysisInFlightGuard() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let blocker = BlockingLLMRunner()
        let models = FakeModelProvider(downloaded: true)
        let intel = Intelligence(
            store: store, llm: blocker, models: models,
            settings: { AISettings(enabled: true) }
        )

        let task1 = Task { @MainActor in
            await intel.runAutoEnhancements(meetingID: meetingID)
        }
        await blocker.waitUntilEntered()

        await intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )
        #expect(intel.jobs[meetingID] == .preparing)

        blocker.release()
        await task1.value
    }

    @Test("manual runAnalysis opens model-only and reconfigures")
    @MainActor func contextSizingManualRunAnalysis() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]
        session.tokenCount = 200

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        let config = fixture.runner.lastConfig
        #expect(config != nil)
        #expect(config?.contextSize == 0)

        #expect(session.reconfigureCalls.count == 1)
    }
}

// MARK: - Intelligence Download Tests

@Suite("Intelligence download state machine")
struct IntelligenceDownloadTests {
    @Test("refreshModelState reflects disk presence")
    @MainActor func refreshModelState() throws {
        let store = try makeStore()
        let models = FakeModelProvider(downloaded: false)
        let intel = Intelligence(
            store: store,
            llm: FakeLLMRunner(),
            models: models,
            settings: { AISettings(enabled: true) }
        )

        #expect(intel.download == .notDownloaded)

        models.downloaded = true
        intel.refreshModelState()
        #expect(intel.download == .downloaded)

        models.downloaded = false
        intel.refreshModelState()
        #expect(intel.download == .notDownloaded)
    }

    @Test("successful download transitions to .downloaded")
    @MainActor func successfulDownload() async throws {
        let store = try makeStore()
        let models = FakeModelProvider(downloaded: false)
        let intel = Intelligence(
            store: store,
            llm: FakeLLMRunner(),
            models: models,
            settings: { AISettings(enabled: true) }
        )

        await intel.downloadModel()

        #expect(intel.download == .downloaded)
        #expect(models.downloadCalled)
        #expect(intel.isModelDownloaded)
    }

    @Test("failed download transitions to .failed")
    @MainActor func failedDownload() async throws {
        let store = try makeStore()
        let models = FakeModelProvider(downloaded: false)
        models.downloadShouldFail = true

        let intel = Intelligence(
            store: store,
            llm: FakeLLMRunner(),
            models: models,
            settings: { AISettings(enabled: true) }
        )

        await intel.downloadModel()

        if case let .failed(message) = intel.download {
            #expect(message.contains("Download failed"))
        } else {
            Issue.record("Expected .failed state")
        }
    }

    @Test("isModelDownloaded reflects provider state")
    @MainActor func isModelDownloaded() throws {
        let store = try makeStore()
        let models = FakeModelProvider(downloaded: true)
        let intel = Intelligence(
            store: store,
            llm: FakeLLMRunner(),
            models: models,
            settings: { AISettings(enabled: true) }
        )

        #expect(intel.isModelDownloaded == true)
        models.downloaded = false
        #expect(intel.isModelDownloaded == false)
    }
}

// MARK: - Gating truth table

@Suite("Gating truth table")
struct GatingTruthTableTests {
    @Test("doSpeakers iff at least one non-human-set speaker")
    @MainActor func doSpeakersGating() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        // No human-set speakers: speaker-ID should run
        let session1 = FakeSession()
        session1.generateResponses = [""]
        session1.streamingTokens = [["S"]]
        let fixture1 = makeIntelligence(store: store, session: session1)
        await fixture1.intel.runAutoEnhancements(meetingID: meetingID)
        #expect(session1.generateCalls.count == 1) // speakers ran
    }

    @Test("auto doSummary = !editedSummary")
    @MainActor func autoDoSummary() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        // Not edited: summary runs
        let session1 = FakeSession()
        session1.generateResponses = [""]
        session1.streamingTokens = [["S"]]
        let fixture1 = makeIntelligence(store: store, session: session1)
        await fixture1.intel.runAutoEnhancements(meetingID: meetingID)
        #expect(session1.streamingCalls.count == 1)
    }

    @Test("manual runAnalysis not gated by settings.enabled")
    @MainActor func manualNotGatedByToggle() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.generateResponses = [""]
        session.streamingTokens = [["S"]]
        let fixture = makeIntelligence(store: store, session: session, enabled: false)
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )
        // Should still have opened a session despite settings.enabled = false
        #expect(fixture.runner.sessionCount == 1)
    }
}

// MARK: - MeetingAnalyzer.cleanTitle Tests

@Suite("MeetingAnalyzer.cleanTitle")
struct CleanTitleTests {
    @Test("bare title passes through")
    func bareTitle() {
        #expect(MeetingAnalyzer.cleanTitle("Weekly Standup") == "Weekly Standup")
    }

    @Test("trims whitespace and newlines")
    func trimWhitespace() {
        #expect(MeetingAnalyzer.cleanTitle("  Sprint Planning  \n") == "Sprint Planning")
    }

    @Test("takes first non-empty line")
    func firstLine() {
        #expect(MeetingAnalyzer.cleanTitle("Design Review\nSome extra text") == "Design Review")
    }

    @Test("strips Title: prefix (case-insensitive)")
    func stripsTitleColonPrefix() {
        #expect(MeetingAnalyzer.cleanTitle("Title: Budget Meeting") == "Budget Meeting")
        #expect(MeetingAnalyzer.cleanTitle("title: budget meeting") == "budget meeting")
        #expect(MeetingAnalyzer.cleanTitle("TITLE: Budget Meeting") == "Budget Meeting")
    }

    @Test("strips Title - prefix")
    func stripsTitleDashPrefix() {
        #expect(MeetingAnalyzer.cleanTitle("Title - Sprint Review") == "Sprint Review")
    }

    @Test("strips surrounding double quotes")
    func stripsDoubleQuotes() {
        #expect(MeetingAnalyzer.cleanTitle("\"Team Sync\"") == "Team Sync")
    }

    @Test("strips surrounding smart quotes")
    func stripsSmartQuotes() {
        #expect(MeetingAnalyzer.cleanTitle("\u{201C}Team Sync\u{201D}") == "Team Sync")
    }

    @Test("strips surrounding single quotes")
    func stripsSingleQuotes() {
        #expect(MeetingAnalyzer.cleanTitle("'Team Sync'") == "Team Sync")
    }

    @Test("strips surrounding smart single quotes")
    func stripsSmartSingleQuotes() {
        #expect(MeetingAnalyzer.cleanTitle("\u{2018}Team Sync\u{2019}") == "Team Sync")
    }

    @Test("strips prefix and quotes together")
    func stripsPrefixAndQuotes() {
        #expect(MeetingAnalyzer.cleanTitle("Title: \"Team Sync\"") == "Team Sync")
    }

    @Test("caps at 120 characters")
    func capsLength() {
        let long = String(repeating: "A", count: 200)
        let result = MeetingAnalyzer.cleanTitle(long)
        #expect(result?.count == 120)
    }

    @Test("empty input returns nil")
    func emptyReturnsNil() {
        #expect(MeetingAnalyzer.cleanTitle("") == nil)
    }

    @Test("whitespace-only input returns nil")
    func whitespaceOnlyReturnsNil() {
        #expect(MeetingAnalyzer.cleanTitle("   \n  ") == nil)
    }

    @Test("quotes-only input returns nil")
    func quotesOnlyReturnsNil() {
        #expect(MeetingAnalyzer.cleanTitle("\"\"") == nil)
    }

    @Test("skips empty lines before first real line")
    func skipsLeadingEmptyLines() {
        #expect(MeetingAnalyzer.cleanTitle("\n\n  Team Sync\n") == "Team Sync")
    }

    @Test("mismatched quotes are not stripped")
    func mismatchedQuotes() {
        // Opening double, closing single -- should NOT strip
        #expect(MeetingAnalyzer.cleanTitle("\"Team Sync'") == "\"Team Sync'")
    }
}

// MARK: - Title Prompt Tests

@Suite("IntelligencePrompts title")
struct IntelligencePromptsTitleTests {
    @Test("titleTaskInstructions is non-empty and asks for a title")
    func titleInstructionsContent() {
        #expect(!IntelligencePrompts.titleTaskInstructions.isEmpty)
        #expect(IntelligencePrompts.titleTaskInstructions.lowercased().contains("title"))
    }

    @Test("titleFollowUpUser equals titleTaskInstructions")
    func titleFollowUpContent() {
        #expect(IntelligencePrompts.titleFollowUpUser == IntelligencePrompts.titleTaskInstructions)
    }

    @Test("titleOnlyFirstUser includes transcript and title instructions")
    func titleOnlyFirstUserContent() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let result = IntelligencePrompts.titleOnlyFirstUser(
            detail: detail,
            transcriptNamed: "Alice: Hello\nBob: Hi"
        )
        #expect(result.contains("<transcript>"))
        #expect(result.contains("Alice: Hello"))
        #expect(result.contains("</transcript>"))
        #expect(result.lowercased().contains("title"))
        // Should NOT contain speaker-ID or summary instructions
        #expect(!result.contains("Match diarization"))
        #expect(!result.contains("## Action Items"))
    }
}

// MARK: - Title Gating Tests

@Suite("Title gating truth table")
struct TitleGatingTests {
    @Test("doTitle = true when title is default and not edited")
    @MainActor func doTitleWhenDefault() async throws {
        let store = try makeStore()
        // createMeeting uses Meeting.defaultTitle by default helper
        let (meetingID, _) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        let session = FakeSession()
        // Speakers + summary + title: generate for speakers, stream for summary,
        // generate for title
        session.generateResponses = ["0 | Alice |", "Sprint Planning"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Title turn ran (2 generate calls: speakers + title)
        #expect(session.generateCalls.count == 2)
        // Summary ran
        #expect(session.streamingCalls.count == 1)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Sprint Planning")
    }

    @Test("doTitle = false when title is user-set (not default)")
    @MainActor func noTitleWhenCustomTitle() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(
            store: store, title: "My Custom Meeting"
        )

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Only 1 generate call (speakers); no title
        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.count == 1)
    }

    @Test("doTitle = false when title is default but editedTitle is true")
    @MainActor func noTitleWhenEditedTitle() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )
        // Mark as user-edited (then set back to the default text)
        try await store.setTitle(Meeting.defaultTitle, for: meetingID)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Only 1 generate call (speakers); title was skipped
        #expect(session.generateCalls.count == 1)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == Meeting.defaultTitle)
    }

    @Test("title generation is independent of force flag")
    @MainActor func titleIndependentOfForce() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |", "Sprint Planning"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        // force=true should not affect title gating
        await fixture.intel.runAnalysis(
            meetingID: meetingID, transcriptID: transcriptID, force: true
        )

        // Title should still run (default title, not edited)
        #expect(session.generateCalls.count == 2)
    }

    @Test("applyGeneratedTitle leaves editedTitle false")
    func applyGeneratedTitleLeavesEditedTitleFalse() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: Meeting.defaultTitle)

        try await store.applyGeneratedTitle("Sprint Planning", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Sprint Planning")
        #expect(detail?.editedTitle == false)
    }

    @Test("applyGeneratedTitle is no-op when title is not default")
    func applyGeneratedTitleNoop() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Custom Title")

        try await store.applyGeneratedTitle("Sprint Planning", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Custom Title")
    }

    @Test("applyGeneratedTitle is no-op when editedTitle is true")
    func applyGeneratedTitleNoopEdited() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: Meeting.defaultTitle)
        // User renames then renames back to default — editedTitle = true
        try await store.setTitle(Meeting.defaultTitle, for: meetingID)

        try await store.applyGeneratedTitle("Sprint Planning", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        // applyGeneratedTitle should be a no-op because editedTitle is true
        #expect(detail?.title == Meeting.defaultTitle)
    }

    @Test("applyGeneratedTitle throws notFound for missing meeting")
    func applyGeneratedTitleThrowsNotFound() async throws {
        let store = try DataStore(storage: .inMemory)
        await #expect(throws: DataStoreError.self) {
            try await store.applyGeneratedTitle("Test", for: UUID())
        }
    }
}

// MARK: - Title Orchestration Tests

@Suite("Title orchestration")
struct TitleOrchestrationTests {
    @Test("multi-turn: speakers + summary + title all run")
    @MainActor func allThreeTurns() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        let session = FakeSession()
        // generate call 1: speakers, generate call 2: title
        session.generateResponses = ["0 | Alice |", "Sprint Planning"]
        session.streamingTokens = [["Summary text"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Verify session usage: 1 session, 2 generate calls, 1 streaming call
        #expect(fixture.runner.sessionCount == 1)
        #expect(session.generateCalls.count == 2)
        #expect(session.streamingCalls.count == 1)

        // Verify the title turn's messages are threaded properly
        let titleMsgs = session.generateCalls[1]
        // system + user (speakers) + assistant (speaker result) + user (summary) +
        // assistant (summary result) + user (title)
        #expect(titleMsgs.count == 6)
        #expect(titleMsgs[0].role == .system)
        #expect(titleMsgs[1].role == .user)
        #expect(titleMsgs[2].role == .assistant)
        #expect(titleMsgs[3].role == .user)
        #expect(titleMsgs[4].role == .assistant) // summary output
        #expect(titleMsgs[5].role == .user)
        // Title follow-up should be the title instructions (no transcript)
        #expect(!titleMsgs[5].content.contains("<transcript>"))
        #expect(titleMsgs[5].content.lowercased().contains("title"))

        #expect(fixture.intel.jobs[meetingID] == .completed)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Summary text")
        #expect(detail?.title == "Sprint Planning")
    }

    @Test("summary + title (no speakers): two-turn conversation")
    @MainActor func summaryAndTitle() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        // Assign all speakers so speaker turn is skipped
        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)

        let session = FakeSession()
        // Only title generate; summary is streaming
        session.generateResponses = ["Sprint Retro"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(session.generateCalls.count == 1) // title only
        #expect(session.streamingCalls.count == 1) // summary

        // Title turn messages: system + user (summary-only first) +
        // assistant (summary) + user (title follow-up)
        let titleMsgs = session.generateCalls[0]
        #expect(titleMsgs.count == 4)
        #expect(titleMsgs[3].role == .user)
        #expect(titleMsgs[3].content.lowercased().contains("title"))

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Sprint Retro")
    }

    @Test("title-only: no speakers, no summary, just title")
    @MainActor func titleOnly() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        // All speakers assigned → no speaker turn
        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)

        // Summary edited → no summary turn
        try await store.setSummary("User's notes", for: meetingID)

        let session = FakeSession()
        session.generateResponses = ["Sprint Planning"]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Only 1 generate call (title), no streaming
        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.isEmpty)

        // Title-only messages: system + user (title-only first user)
        let msgs = session.generateCalls[0]
        #expect(msgs.count == 2)
        // Should use named transcript (Alice/Bob), not Speaker-N
        #expect(msgs[1].content.contains("Alice:"))

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Sprint Planning")
        // Summary should not have been overwritten
        #expect(detail?.summary == "User's notes")
    }

    @Test("no-session when all tasks skipped (speakers done + summary edited + title not default)")
    @MainActor func allTasksSkippedIncludingTitle() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: "Custom Title"
        )

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)
        try await store.setSummary("User's notes", for: meetingID)

        let fixture = makeIntelligence(store: store)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("cleanTitle applied to raw model output")
    @MainActor func cleanTitleApplied() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)
        try await store.setSummary("Notes", for: meetingID)

        let session = FakeSession()
        // Model wraps the title in quotes with a Title: prefix
        session.generateResponses = ["Title: \"Sprint Planning\""]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.title == "Sprint Planning")
    }

    @Test("empty cleaned title is not applied")
    @MainActor func emptyCleanedTitleNotApplied() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store, title: Meeting.defaultTitle
        )

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: bob, for: transcriptID)
        try await store.setSummary("Notes", for: meetingID)

        let session = FakeSession()
        // Model returns only whitespace — cleanTitle returns nil
        session.generateResponses = ["  \n  "]

        let fixture = makeIntelligence(store: store, session: session)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        // Title should remain unchanged
        #expect(detail?.title == Meeting.defaultTitle)
    }
}

// MARK: - EnhancementStatus generatingTitle Tests

@Suite("EnhancementStatus generatingTitle")
struct EnhancementStatusTitleTests {
    @Test("generatingTitle is a distinct case")
    func generatingTitleDistinct() {
        let status = EnhancementStatus.generatingTitle
        #expect(status != .preparing)
        #expect(status != .identifyingSpeakers)
        #expect(status != .summarizing)
        #expect(status != .completed)
    }
}

// MARK: - Meeting.defaultTitle Tests

@Suite("Meeting.defaultTitle")
struct MeetingDefaultTitleTests {
    @Test("defaultTitle is 'Untitled Meeting'")
    func defaultTitleValue() {
        #expect(Meeting.defaultTitle == "Untitled Meeting")
    }
}

// MARK: - MeetingDetailData editedTitle Tests

@Suite("MeetingDetailData editedTitle")
struct MeetingDetailDataEditedTitleTests {
    @Test("editedTitle defaults to false")
    func editedTitleDefaultFalse() {
        let detail = MeetingDetailData(
            id: UUID(), title: "Test", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        #expect(detail.editedTitle == false)
    }

    @Test("editedTitle passes through from store")
    func editedTitleFromStore() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Test")
        try await store.setTitle("Custom", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.editedTitle == true)
    }
}

// MARK: - humanSetSpeakerMappings DataStore Tests

@Suite("DataStore humanSetSpeakerMappings")
struct HumanSetSpeakerMappingsTests {
    @Test("returns only human-set mappings")
    func returnsOnlyHumanSet() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)

        // Manually assign speaker 0 (userSet=true)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)
        // AI assigns speaker 1 (userSet=false)
        try await store.setSpeakerAssignments([1: bob], for: transcriptID)

        let human = try await store.humanSetSpeakerMappings(for: transcriptID)
        #expect(human.count == 1)
        #expect(human[0]?.name == "Alice")
        #expect(human[0]?.email == "alice@x.com")
        #expect(human[1] == nil)
    }

    @Test("returns empty when no human-set mappings")
    func returnsEmptyWhenNone() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignments([0: bob], for: transcriptID)

        let human = try await store.humanSetSpeakerMappings(for: transcriptID)
        #expect(human.isEmpty)
    }

    @Test("drops dangling person IDs")
    func dropsDangling() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)

        // Manually inject a dangling person ID
        let danglingID = UUID()
        try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            var assignments = record.speakerAssignments
            assignments[1] = SpeakerAssignmentEntry(personID: danglingID, userSet: true)
            record.speakerAssignments = assignments
        }

        let human = try await store.humanSetSpeakerMappings(for: transcriptID)
        #expect(human.count == 1) // Only Alice; dangling dropped
        #expect(human[0]?.name == "Alice")
    }

    @Test("throws notFound for missing transcript")
    func throwsForMissingTranscript() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.humanSetSpeakerMappings(for: UUID())
        }
    }
}
