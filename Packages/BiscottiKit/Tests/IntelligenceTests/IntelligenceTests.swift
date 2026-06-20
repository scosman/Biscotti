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
/// scripted responses.
final class FakeSession: LLMSession, @unchecked Sendable {
    /// Recorded (system, user) pairs from generate calls.
    var generateCalls: [(system: String, user: String)] = []
    /// Scripted responses for sequential generate calls.
    var generateResponses: [String] = []
    /// Error to throw on generate (if set).
    var generateError: (any Error)?

    /// Recorded (system, user) pairs from generateStreaming calls.
    var streamingCalls: [(system: String, user: String)] = []
    /// Scripted token sequences for streaming calls.
    var streamingTokens: [[String]] = []
    /// When set, the `.done` event carries this text instead of the joined
    /// tokens. Used to test that the Summarizer prefers canonical `.done` text.
    var canonicalDoneText: String?

    /// Canned token count for `countTokens`. Returns this value for every call.
    var tokenCount: Int = 100

    /// Recorded reconfigure calls (context sizes).
    var reconfigureCalls: [Int] = []

    private var generateCallIndex = 0
    private var streamingCallIndex = 0

    func countTokens(
        system _: String, user _: String
    ) async throws -> Int {
        tokenCount
    }

    func reconfigure(contextSize: Int) async throws {
        reconfigureCalls.append(contextSize)
    }

    func generate(
        system: String, user: String, options _: GenerationOptions
    ) async throws -> String {
        generateCalls.append((system: system, user: user))
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
        system: String, user: String, options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        streamingCalls.append((system: system, user: user))
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
    // Swift's auto-synthesized Codable for enums without associated values
    // encodes as {"caseName":{}} (keyed container), not a bare string.
    let json: [String: Any] = [
        "text": text,
        "promptTokenCount": 0,
        "generatedTokenCount": 1,
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
/// Uses `AsyncStream` channels for signaling to avoid NSLock (which is
/// unavailable in async contexts under Swift 6).
final class BlockingLLMRunner: LLMRunning, @unchecked Sendable {
    // "entered" channel: withSession yields a value when it starts
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    // "release" channel: release() yields a value to unblock withSession
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

    /// Wait until `withSession` has been entered by the first caller.
    func waitUntilEntered() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    /// Allow the blocked `withSession` to proceed and return.
    func release() {
        releaseContinuation.yield()
    }

    func withSession<T: Sendable>(
        config _: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        // Signal that we've entered the session
        enteredContinuation.yield()

        // Block until released
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
    summarize: Bool = true,
    guessSpeakers: Bool = true
) -> IntelligenceFixture {
    let runner = FakeLLMRunner(session: session)
    let models = FakeModelProvider(downloaded: downloaded)
    let settings = AISettings(
        summarize: summarize, guessSpeakers: guessSpeakers
    )
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
        // Only line 0 is valid; "x" is non-numeric, missing index, empty name
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
    @Test("system prompts are non-empty")
    func systemPromptsNonEmpty() {
        #expect(!IntelligencePrompts.summarySystem.isEmpty)
        #expect(!IntelligencePrompts.speakerSystem.isEmpty)
    }

    @Test("summaryUser includes the transcript")
    func summaryUserContent() {
        let result = IntelligencePrompts.summaryUser(
            transcript: "Alice: Hello\nBob: Hi"
        )
        #expect(result.contains("Alice: Hello"))
        #expect(result.contains("Bob: Hi"))
    }

    @Test("speakerUser includes invitees and transcript")
    func speakerUserWithInvitees() {
        let result = IntelligencePrompts.speakerUser(
            transcript: "Speaker 0: Hello",
            invitees: [
                (name: "Alice Smith", email: "alice@x.com"),
                (name: "Bob Jones", email: nil)
            ]
        )
        #expect(result.contains("Alice Smith <alice@x.com>"))
        #expect(result.contains("Bob Jones"))
        #expect(result.contains("Speaker 0: Hello"))
        #expect(result.contains("Meeting invitees:"))
    }

    @Test("speakerUser handles empty invitees")
    func speakerUserNoInvitees() {
        let result = IntelligencePrompts.speakerUser(
            transcript: "Speaker 0: Hello",
            invitees: []
        )
        #expect(result.contains("No invitee list available."))
        #expect(result.contains("Speaker 0: Hello"))
    }
}

// MARK: - Intelligence Orchestration Tests

@Suite("Intelligence orchestration")
struct IntelligenceOrchestrationTests {
    @Test("both toggles on runs speaker-ID then summary in one session")
    @MainActor func bothTogglesOn() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        // Speaker-ID returns a mapping
        session.generateResponses = ["0 | Alice |\n1 | Bob |"]
        // Summary streaming tokens
        session.streamingTokens = [["## Meeting Notes\n", "Summary text"]]

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Exactly one session opened
        #expect(fixture.runner.sessionCount == 1)
        // Speaker-ID generate called first, then streaming summary
        #expect(session.generateCalls.count == 1)
        #expect(session.streamingCalls.count == 1)
        // Status should be completed
        #expect(fixture.intel.jobs[meetingID] == .completed)

        // Summary should be persisted
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "## Meeting Notes\nSummary text")
        #expect(detail?.editedSummary == false)

        // Speaker assignments should be persisted
        let transcript = detail?.preferredTranscript
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
        #expect(transcript?.speakerAssignments[1]?.name == "Bob")
    }

    @Test("only summarize runs summary only (no speaker-ID)")
    @MainActor func summarizeOnly() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(
            store: store, session: session, guessSpeakers: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 1)
        #expect(session.generateCalls.isEmpty) // No speaker-ID
        #expect(session.streamingCalls.count == 1) // Summary only
        #expect(fixture.intel.jobs[meetingID] == .completed)
    }

    @Test("only guessSpeakers runs speaker-ID only (no summary)")
    @MainActor func speakersOnly() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]

        let fixture = makeIntelligence(
            store: store, session: session, summarize: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 1)
        #expect(session.generateCalls.count == 1) // Speaker-ID
        #expect(session.streamingCalls.isEmpty) // No summary
        #expect(fixture.intel.jobs[meetingID] == .completed)
    }

    @Test("both toggles off is no-op")
    @MainActor func bothOff() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let fixture = makeIntelligence(
            store: store, summarize: false, guessSpeakers: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
        #expect(fixture.intel.jobs[meetingID] == nil) // No status set
    }

    @Test("no model is no-op")
    @MainActor func noModel() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let fixture = makeIntelligence(
            store: store, downloaded: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
        #expect(fixture.intel.jobs[meetingID] == nil)
    }

    @Test("edited-summary guard skips summary but runs speaker-ID")
    @MainActor func editedSummaryGuard() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        // User edits the summary
        try await store.setSummary("My notes", for: meetingID)

        let session = FakeSession()
        session.generateResponses = ["0 | Alice |"]

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Speaker-ID ran
        #expect(session.generateCalls.count == 1)
        // Summary was skipped
        #expect(session.streamingCalls.isEmpty)
        // Summary not overwritten
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "My notes")
        #expect(detail?.editedSummary == true)
    }

    @Test("streaming accumulation flows into streamingSummary")
    @MainActor func streamingAccumulation() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        session.streamingTokens = [["Hello", " World"]]

        let fixture = makeIntelligence(
            store: store, session: session, guessSpeakers: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // After completion, streaming summary is cleared
        #expect(fixture.intel.streamingSummary[meetingID] == nil)
        // But the final summary is persisted
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

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        if case let .failed(message) = fixture.intel.jobs[meetingID] {
            #expect(message.contains("Test error"))
        } else {
            Issue.record("Expected .failed status")
        }
    }

    @Test("summary user message contains resolved names after speaker-ID")
    @MainActor func summaryUsesResolvedNames() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        // Speaker-ID maps speaker 0 to Alice
        session.generateResponses = ["0 | Alice |"]
        session.streamingTokens = [["Summary"]]

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // The summary call's user message should contain "Alice" not "Speaker 0"
        let summaryUser = session.streamingCalls.first?.user ?? ""
        #expect(summaryUser.contains("Alice"))
    }

    @Test("no transcript is no-op")
    @MainActor func noTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Transcript")

        let fixture = makeIntelligence(store: store)
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("second concurrent runAutoEnhancements is rejected while one is in-flight")
    @MainActor func inFlightGuard() async throws {
        let store = try makeStore()
        let (meetingID1, _) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 1"
        )
        let (meetingID2, _) = try await makeMeetingWithTranscript(
            store: store, title: "Meeting 2"
        )

        // Use a blocking runner that holds the session open until released
        let blocker = BlockingLLMRunner()
        let models = FakeModelProvider(downloaded: true)
        let intel = Intelligence(
            store: store, llm: blocker, models: models,
            settings: { AISettings(summarize: true, guessSpeakers: false) }
        )

        // Start the first run (it will block in withSession)
        let task1 = Task { @MainActor in
            await intel.runAutoEnhancements(meetingID: meetingID1)
        }
        // Wait for the first run to enter the session
        await blocker.waitUntilEntered()

        // Second run should be immediately rejected (in-flight guard)
        await intel.runAutoEnhancements(meetingID: meetingID2)
        #expect(intel.jobs[meetingID2] == nil) // Never started

        // Release the first run
        blocker.release()
        await task1.value
        #expect(intel.jobs[meetingID1] == .completed)
    }

    @Test("Summarizer uses canonical .done text over accumulated tokens")
    @MainActor func doneEventCanonicalText() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let session = FakeSession()
        // Tokens accumulate to "par" + "tial" = "partial", but the
        // .done event carries a different canonical text.
        session.streamingTokens = [["par", "tial"]]
        session.canonicalDoneText = "CANONICAL FINAL"

        let fixture = makeIntelligence(
            store: store, session: session, guessSpeakers: false
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // The persisted summary must equal the .done result's text,
        // not the concatenated tokens — proving the Summarizer
        // overrides token accumulation with the canonical result.
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

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.runAutoEnhancements(meetingID: meetingID)

        // Session opens in model-only mode (contextSize=0, no KV-cache)
        let config = fixture.runner.lastConfig
        #expect(config != nil)
        #expect(config?.contextSize == 0)

        // Reconfigure called with right-sized context: tokenCount + 3072
        #expect(session.reconfigureCalls.count == 1)
        let expectedContextSize = ContextSizing.contextSize(
            forInputTokens: session.tokenCount
        )
        #expect(session.reconfigureCalls.first == expectedContextSize)
    }
}

// MARK: - Intelligence Generate Summary Tests

@Suite("Intelligence generateSummary")
struct IntelligenceGenerateSummaryTests {
    @Test("manual generate summary works")
    @MainActor func manualGenerate() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let session = FakeSession()
        session.streamingTokens = [["Generated summary"]]

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        #expect(fixture.runner.sessionCount == 1)
        #expect(fixture.intel.jobs[meetingID] == .completed)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Generated summary")
        #expect(detail?.editedSummary == false)
    }

    @Test("manual generate respects editedSummary guard when not forced")
    @MainActor func editedGuardNotForced() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )
        try await store.setSummary("User's notes", for: meetingID)

        let fixture = makeIntelligence(store: store)
        await fixture.intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        // Should not have run
        #expect(fixture.runner.sessionCount == 0)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "User's notes")
    }

    @Test("manual generate with force overwrites edited summary")
    @MainActor func forceOverwrites() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )
        try await store.setSummary("User's notes", for: meetingID)

        let session = FakeSession()
        session.streamingTokens = [["New summary"]]

        let fixture = makeIntelligence(
            store: store, session: session
        )
        await fixture.intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: true
        )

        #expect(fixture.runner.sessionCount == 1)
        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "New summary")
        #expect(detail?.editedSummary == false) // Reset after AI generation
    }

    @Test("no model is no-op for manual generate")
    @MainActor func noModelManualGenerate() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let fixture = makeIntelligence(
            store: store, downloaded: false
        )
        await fixture.intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        #expect(fixture.runner.sessionCount == 0)
    }

    @Test("generateSummary is rejected while another run is in-flight")
    @MainActor func generateSummaryInFlightGuard() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let blocker = BlockingLLMRunner()
        let models = FakeModelProvider(downloaded: true)
        let intel = Intelligence(
            store: store, llm: blocker, models: models,
            settings: { AISettings(summarize: true, guessSpeakers: false) }
        )

        // Start auto-run (blocks in withSession)
        let task1 = Task { @MainActor in
            await intel.runAutoEnhancements(meetingID: meetingID)
        }
        await blocker.waitUntilEntered()

        // Manual generate should be silently rejected (in-flight guard)
        await intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )
        // The first run is still blocked in withSession (body hasn't run),
        // so jobs has no status yet — the key point is that the second call
        // returned without crashing or starting a second session.
        #expect(intel.jobs[meetingID] == nil)

        blocker.release()
        await task1.value
    }

    @Test("manual generateSummary opens model-only and reconfigures")
    @MainActor func contextSizingManualGenerate() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(
            store: store
        )

        let session = FakeSession()
        session.streamingTokens = [["Summary"]]
        session.tokenCount = 200

        let fixture = makeIntelligence(
            store: store, session: session, guessSpeakers: false
        )
        await fixture.intel.generateSummary(
            meetingID: meetingID, transcriptID: transcriptID, force: false
        )

        // Session opens in model-only mode (contextSize=0, no KV-cache)
        let config = fixture.runner.lastConfig
        #expect(config != nil)
        #expect(config?.contextSize == 0)

        // Reconfigure called with right-sized context: tokenCount + 3072
        #expect(session.reconfigureCalls.count == 1)
        let expectedContextSize = ContextSizing.contextSize(
            forInputTokens: session.tokenCount
        )
        #expect(session.reconfigureCalls.first == expectedContextSize)
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
            settings: { AISettings(summarize: true, guessSpeakers: true) }
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
            settings: { AISettings(summarize: true, guessSpeakers: true) }
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
            settings: { AISettings(summarize: true, guessSpeakers: true) }
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
            settings: { AISettings(summarize: true, guessSpeakers: true) }
        )

        #expect(intel.isModelDownloaded == true)
        models.downloaded = false
        #expect(intel.isModelDownloaded == false)
    }
}
