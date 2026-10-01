import DataStore
import Dispatch
import Foundation
import LocalLLM
import Synchronization
import Testing
@testable import Intelligence

private let isAITestEnabled =
    ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"

/// LLM-backed speaker-identification tests exercising voiceprint evidence.
///
/// These require the real Gemma 4 12B model on disk and
/// `BISCOTTI_RUN_AI_TESTS=1` in the environment. A bare `swift test` skips
/// them entirely. Run via `make test-ai`.
///
/// Each case builds the real first user message with
/// `IntelligencePrompts.analysisFirstUser` and a handwritten
/// `<voiceprint_matches>` block, runs with `MeetingAnalyzer.speakerOptions`,
/// and parses with `SpeakerMappingParser`. Output varies, so each case runs
/// 3 times and passes when >= 2 runs are correct.
@Suite("Intelligence AI Tests (BISCOTTI_RUN_AI_TESTS=1)", .enabled(if: isAITestEnabled), .serialized)
struct IntelligenceAITests {
    // MARK: - Shared model connection

    static let modelPath: URL = {
        if let envPath = ProcessInfo.processInfo.environment["LLM_MODEL_PATH"] {
            return URL(fileURLWithPath: envPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Biscotti/llms")
            .appendingPathComponent("gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }()

    /// Shared in-process connection loaded once for the entire suite.
    static let sharedConnection = Mutex<LLMConnection?>(nil)

    /// Registers an `atexit` handler exactly once, right after the model is
    /// loaded. LIFO ordering ensures this runs before ggml's Metal-device
    /// static destructor. Without this, the normal `exit()` path runs
    /// ggml's destructor while residency sets are alive -> SIGABRT.
    private static let registerAtexitOnce: Void = {
        atexit {
            let sem = DispatchSemaphore(value: 0)
            Task {
                if let conn = IntelligenceAITests.sharedConnection.withLock({ $0 }) {
                    await conn.close()
                    IntelligenceAITests.sharedConnection.withLock { $0 = nil }
                }
                LocalLLMRuntime.shutdown()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 30.0)
        }
    }()

    /// Load or return the shared connection.
    static func connection() async throws -> LLMConnection {
        if let existing = sharedConnection.withLock({ $0 }) {
            return existing
        }
        let config = EngineConfig(contextSize: 4096, seed: 42)
        let conn = try await LLMService.openConnection(
            model: modelPath, backend: .inProcess, config: config
        )
        sharedConnection.withLock { $0 = conn }
        _ = registerAtexitOnce
        return conn
    }

    // MARK: - Helpers

    /// Run a speaker-identification prompt 3 times, return parsed results.
    private static func runSpeakerID(
        conn: LLMConnection, userContent: String
    ) async throws -> [[Int: SpeakerMappingParser.SpeakerMapping]] {
        let messages: [LLMMessage] = [
            .system(IntelligencePrompts.analysisSystem),
            .user(userContent)
        ]
        var results: [[Int: SpeakerMappingParser.SpeakerMapping]] = []
        for _ in 0 ..< 3 {
            let result = try await conn.generate(
                messages: messages, options: MeetingAnalyzer.speakerOptions
            )
            results.append(SpeakerMappingParser.parse(result.text))
        }
        return results
    }

    // MARK: - Test cases

    @Test("same-human-two-entries: Sam/Samantha with email")
    func sameHumanTwoEntries() async throws {
        let conn = try await Self.connection()

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 5 earlier meetings, 3 with names that the user confirmed.

        Speaker 0: voice is close to more than one known person: \
        Sam <sam@kiln.tech> (3 meetings, 2 confirmed by the user) and \
        Samantha (no email) (2 meetings, 1 confirmed by the user).
        Speaker 1: no voiceprint available for this speaker.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 1: Hi Samantha, shall we start?
        Speaker 0: Sure, let me pull up the notes from last week.
        Speaker 1: Great, I had a few questions about the API changes.
        Speaker 0: Go ahead, I reviewed the PR this morning.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Team Sync", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, userContent: userContent)
        var successes = 0
        for parsed in results {
            // Speaker 0 should be identified as Sam/Samantha with the email
            if let mapping = parsed[0],
               mapping.name.lowercased().contains("sam"),
               mapping.email == "sam@kiln.tech"
            {
                successes += 1
            }
        }
        #expect(
            successes >= 2,
            "Expected >= 2/3 runs to identify Speaker 0 as Sam with sam@kiln.tech"
        )
    }

    @Test("different-humans-similar-voices: transcript disambiguates to Amit")
    func differentHumansSimilarVoices() async throws {
        let conn = try await Self.connection()

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 4 earlier meetings, 2 with names that the user confirmed.

        Speaker 0: voice is close to more than one known person: \
        Dave (no email) (2 meetings, 1 confirmed by the user) and \
        Amit (no email) (2 meetings, 1 confirmed by the user).
        Speaker 1: no voiceprint available for this speaker.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 1: Let's go through the action items from last time.
        Speaker 0: Sure. I finished the database migration yesterday.
        Speaker 1: Nice work. Thanks, Amit. What about the load tests?
        Speaker 0: I'll have those ready by end of week.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Sprint Review", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, userContent: userContent)
        var successes = 0
        for parsed in results {
            // Speaker 0 should be Amit (transcript says "thanks, Amit")
            if let mapping = parsed[0],
               mapping.name.lowercased().contains("amit")
            {
                successes += 1
            }
        }
        #expect(
            successes >= 2,
            "Expected >= 2/3 runs to identify Speaker 0 as Amit"
        )
    }

    @Test("high-confidence-match: Steve identified by voiceprint alone")
    func highConfidenceMatch() async throws {
        let conn = try await Self.connection()

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 6 earlier meetings, 4 with names that the user confirmed.

        Speaker 0: no voiceprint available for this speaker.
        Speaker 1: High confidence match to Steve <steve@kiln.tech>. \
        Heard in 5 earlier meetings, 3 confirmed by the user.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 0: Good morning. Let's review the deployment plan.
        Speaker 1: Sounds good. I think we should roll out to staging first.
        Speaker 0: Agreed. Can you handle the staging deploy today?
        Speaker 1: Yes, I'll get that done after this call.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Deployment Planning", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, userContent: userContent)
        var successes = 0
        for parsed in results {
            // Speaker 1 should be Steve with the email
            if let mapping = parsed[1],
               mapping.name.lowercased().contains("steve"),
               mapping.email == "steve@kiln.tech"
            {
                successes += 1
            }
        }
        #expect(
            successes >= 2,
            "Expected >= 2/3 runs to identify Speaker 1 as Steve with steve@kiln.tech"
        )
    }
}
