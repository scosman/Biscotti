import Dispatch
import Foundation
import Synchronization
import Testing
@testable import LocalLLM

/// Env-gated model-backed integration tests.
///
/// These require the real ~8 GB Gemma 4 12B QAT model on disk and
/// `BISCOTTI_RUN_AI_TESTS=1` in the environment. A bare `swift test` skips
/// these entirely (fast, no model needed).
///
/// The model path is read from `LLM_MODEL_PATH` env var, or defaults to the standard
/// cache location: `~/Library/Application Support/Biscotti/llms/gemma-4-12b-it-UD-Q4_K_XL.gguf`
///
/// All tests share a single in-process connection (load-once/serve-many) to avoid
/// redundant ~8 GB model loads during test runs.
@Suite("Integration (BISCOTTI_RUN_AI_TESTS=1)", .enabled(if: isAITestEnabled), .serialized)
struct IntegrationTests {
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
    /// Protected by Mutex so the invariant is enforced by the type system,
    /// not just the `.serialized` trait.
    static let sharedConnection = Mutex<LLMConnection?>(nil)

    /// One-shot token: registers an `atexit` handler exactly once, right after
    /// the model is loaded. atexit/__cxa_atexit handlers run LIFO, so registering
    /// AFTER the model load guarantees this runs BEFORE ggml's Metal-device static
    /// destructor (which was registered during model load). The handler performs
    /// ordered teardown: close the connection (frees ctx/model, drops Metal residency
    /// sets), then `llama_backend_free()` (frees the Metal device). Without this,
    /// the normal `exit()` path runs ggml's destructor while residency sets are still
    /// alive → `GGML_ASSERT([rsets->data count] == 0)` → SIGABRT.
    ///
    /// We do NOT call `_exit()` here (unlike the CLI/XPC host) because the test
    /// runner's real exit code must be preserved for `make test-ai` pass/fail reporting.
    private static let registerAtexitOnce: Void = {
        atexit {
            let sem = DispatchSemaphore(value: 0)
            Task {
                if let conn = IntegrationTests.sharedConnection.withLock({ $0 }) {
                    await conn.close()
                    IntegrationTests.sharedConnection.withLock { $0 = nil }
                }
                LocalLLMRuntime.shutdown()
                sem.signal()
            }
            // Bounded wait: 30s so a stuck teardown can't hang the run forever.
            _ = sem.wait(timeout: .now() + 30.0)
        }
    }()

    /// Load or return the shared connection. First call opens an in-process
    /// connection (loads the model); subsequent calls return the cached instance.
    static func connection() async throws -> LLMConnection {
        if let existing = sharedConnection.withLock({ $0 }) {
            return existing
        }

        let config = EngineConfig(contextSize: 4096, seed: 42)
        let conn = try await LLMService.openConnection(
            model: modelPath,
            backend: .inProcess,
            config: config
        )
        sharedConnection.withLock { $0 = conn }

        // Register the atexit handler AFTER model load (LIFO ordering ensures it
        // runs before ggml's static destructors). Evaluated once; subsequent calls
        // are no-ops.
        _ = registerAtexitOnce

        return conn
    }

    @Test("Stack works: load, generate, sane result")
    func stackWorks() async throws {
        let conn = try await Self.connection()

        let options = GenerationOptions(
            maxTokens: 128,
            temperature: 0, // greedy for determinism
            seed: 42
        )

        let result = try await conn.generate(
            messages: [.user("What is 2 + 2? Answer with just the number.")],
            options: options
        )

        // Non-empty response
        #expect(!result.text.isEmpty, "Expected non-empty response text")

        // Token counts are sane
        #expect(result.promptTokenCount > 0, "Expected prompt tokens > 0")
        #expect(result.generatedTokenCount > 0, "Expected generated tokens > 0")

        // Timing is sane
        #expect(result.totalDuration > 0, "Expected positive total duration")
        #expect(result.promptEvalDuration > 0, "Expected positive prompt eval duration")
        #expect(result.generationDuration > 0, "Expected positive generation duration")
        #expect(result.tokensPerSecond > 0, "Expected positive tokens/s")

        // Finish reason should be endOfTurn or eos for a short prompt
        #expect(
            result.finishReason == .endOfTurn || result.finishReason == .eos,
            "Expected endOfTurn or eos, got \(result.finishReason)"
        )
    }

    @Test("Greedy decoding is deterministic across two runs")
    func determinism() async throws {
        let conn = try await Self.connection()

        let options = GenerationOptions(
            maxTokens: 64,
            temperature: 0,
            seed: 42
        )

        let result1 = try await conn.generate(
            messages: [.user("Name three primary colors.")],
            options: options
        )
        let result2 = try await conn.generate(
            messages: [.user("Name three primary colors.")],
            options: options
        )

        // With temp 0 and the same seed, results should be identical
        #expect(
            result1.text == result2.text,
            "Expected deterministic output, got:\n  run1: \(result1.text)\n  run2: \(result2.text)"
        )
    }

    @Test("Streaming and buffered generate produce identical results")
    // swiftlint:disable:next function_body_length
    func streamingParityWithBufferedGenerate() async throws {
        let conn = try await Self.connection()

        let options = GenerationOptions(
            maxTokens: 128,
            temperature: 0, // greedy for determinism
            seed: 42
        )

        let prompt = "What color is the sky on a clear day? Answer briefly."

        // Buffered generate
        let bufferedResult = try await conn.generate(
            messages: [.user(prompt)], options: options
        )

        // Streaming generate -- collect all events
        let stream = await conn.generateStreaming(
            messages: [.user(prompt)], options: options
        )
        var streamedContentTokens: [String] = []
        var streamedReasoningTokens: [String] = []
        var streamResult: GenerationResult?
        for try await event in stream {
            switch event {
            case let .token(piece):
                streamedContentTokens.append(piece)
            case let .reasoningToken(piece):
                streamedReasoningTokens.append(piece)
            case let .done(result):
                streamResult = result
            }
        }

        let result = try #require(streamResult, "Stream must end with a .done event")

        // The final result from streaming must match the buffered result.
        #expect(
            result.text == bufferedResult.text,
            "Streaming text must match buffered: '\(result.text)' vs '\(bufferedResult.text)'"
        )
        #expect(
            result.generatedTokenCount == bufferedResult.generatedTokenCount,
            "Token counts must match: \(result.generatedTokenCount) vs \(bufferedResult.generatedTokenCount)"
        )
        #expect(
            result.finishReason == bufferedResult.finishReason,
            "Finish reasons must match: \(result.finishReason) vs \(bufferedResult.finishReason)"
        )
        #expect(
            result.promptTokenCount == bufferedResult.promptTokenCount,
            "Prompt token counts must match"
        )

        // Concatenated content tokens must match the result text modulo leading/trailing
        // whitespace trimming. The stream emits raw untrimmed tokens; OutputParser.parse
        // trims the finished buffer. This modulo-whitespace agreement is the intended
        // invariant -- not a workaround.
        let concatenatedContent = streamedContentTokens.joined()
        #expect(
            concatenatedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                == result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            "Concatenated .token events must equal result.text (modulo whitespace trimming)"
        )

        // Concatenated reasoning tokens must match result.reasoning modulo whitespace
        // (same trimming invariant as above).
        let concatenatedReasoning = streamedReasoningTokens.joined()
        let expectedReasoning = (result.reasoning ?? "")
        #expect(
            concatenatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedReasoning.trimmingCharacters(in: .whitespacesAndNewlines),
            "Concatenated .reasoningToken events must equal result.reasoning (modulo whitespace trimming)"
        )
    }

    @Test("Chat template produces sane tokenization")
    func chatTemplateSanity() async throws {
        let conn = try await Self.connection()

        let options = GenerationOptions(
            maxTokens: 32,
            temperature: 0,
            seed: 42
        )

        let result = try await conn.generate(
            messages: [
                .system("You are a friendly assistant."),
                .user("Say hello.")
            ],
            options: options
        )

        #expect(!result.text.isEmpty)
        // The prompt should be more than just the raw text tokens (template added overhead)
        #expect(result.promptTokenCount > 5, "Template should add turn tokens to the prompt")
    }

    @Test("KV-cache prefix reuse: two-turn extend reuses prefix")
    // swiftlint:disable:next function_body_length
    func kvCacheReuse() async throws {
        let conn = try await Self.connection()

        let options = GenerationOptions(
            maxTokens: 64,
            temperature: 0,
            seed: 42
        )

        // Use a realistically-long transcript so the reuse-fraction assertion is meaningful.
        // A short transcript would tokenize to few tokens, making prefix-match ratios noisy.
        let transcript = """
        [00:01] Alice: Good morning everyone. Let's start with the billing fix — we need to ship before Friday.
        [00:08] Alice: I'll own the backend change. The main issue is the pro-ration calculation for mid-cycle upgrades.
        [00:14] Bob: I can take the migration script, but I need the final schema from Alice by Wednesday at the latest.
        [00:22] Bob: Also, we should decide whether to backfill existing records or only apply to new invoices.
        [00:30] Alice: Good point. Let's backfill — customers have been asking about it. I'll send the schema tomorrow morning.
        [00:38] Carol: Sounds good. I'll plan QA for Thursday. Do we have a staging environment ready?
        [00:42] Carol: Last time the staging DB was stale and I had to re-seed it. Can someone check?
        [00:50] Bob: Staging deploy is actually broken right now. The last CI run failed on a flaky test.
        [00:55] Bob: Dave, can you look at the staging pipeline today? It's blocking QA.
        [01:03] Dave: Already on it. I saw the failure this morning — it's the Stripe webhook retry test timing out.
        [01:08] Dave: I'll have a fix pushed by noon and ping the channel once staging is green.
        [01:15] Alice: Great. Carol, once staging is up, can you also run the regression suite for the payment flow?
        [01:20] Carol: Yes, I'll run the full regression Thursday and report back by end of day.
        [01:25] Carol: I'll also do a quick smoke test on the mobile app since the billing page was updated.
        [01:30] Bob: One more thing — should we flag the migration behind a feature toggle for rollback safety?
        [01:35] Alice: Yes, good call. Bob, add a toggle. We'll enable it in staging first, then prod on Friday.
        [01:42] Dave: I can set up the toggle infrastructure — I already have the feature-flag SDK wired in.
        [01:48] Alice: Perfect. Let's sync again Friday morning to confirm everything landed cleanly.
        [01:52] Alice: I'll send a summary of action items after this call. Thanks everyone.
        """

        let systemMsg = LLMMessage.system(
            "You are a meeting analyst. Answer precisely and concisely."
        )
        let userMsg = LLMMessage.user(
            "Summarize this meeting transcript in one sentence:\n\n"
                + transcript
        )

        // Turn 1: cold start — expect very few cached tokens. Not necessarily 0
        // because the shared LLMConnection/LLMEngine may retain a small BOS/template
        // prefix from a preceding test in the suite. Allow up to 10.
        let result1 = try await conn.generate(
            messages: [systemMsg, userMsg],
            options: options
        )
        #expect(!result1.text.isEmpty, "Turn 1 should produce non-empty output")
        #expect(
            result1.cachedPromptTokenCount < 10,
            "Turn 1 should have near-zero cached tokens (cold start), got \(result1.cachedPromptTokenCount)"
        )

        // Turn 2: extend the conversation with the model's response + a follow-up
        let result2 = try await conn.generate(
            messages: [
                systemMsg,
                userMsg,
                .assistant(result1.text),
                .user("List the action items from the transcript.")
            ],
            options: options
        )
        #expect(!result2.text.isEmpty, "Turn 2 should produce non-empty output")

        // The cached count should be approximately tokens(system + user1), i.e.
        // a large fraction of the turn-1 prompt. The exact number depends on
        // tokenization, but it must be > 0 (some prefix was reused) and less
        // than or equal to the turn-2 prompt total.
        #expect(
            result2.cachedPromptTokenCount > 0,
            "Turn 2 should reuse KV prefix (cachedPromptTokenCount > 0), got \(result2.cachedPromptTokenCount)"
        )
        #expect(
            result2.cachedPromptTokenCount <= result2.promptTokenCount,
            "Cached tokens (\(result2.cachedPromptTokenCount)) must not exceed prompt tokens (\(result2.promptTokenCount))"
        )

        // The reused prefix should cover at least half the turn-1 prompt (the
        // system + transcript is the bulk). This is a conservative threshold.
        let reuseFraction = Double(result2.cachedPromptTokenCount) / Double(result1.promptTokenCount)
        #expect(
            reuseFraction > 0.5,
            "Expected > 50% of turn-1 prompt tokens reused, got \(String(format: "%.1f%%", reuseFraction * 100))"
        )
    }
}

/// Check whether the AI integration tests are enabled.
private let isAITestEnabled: Bool =
    ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"
