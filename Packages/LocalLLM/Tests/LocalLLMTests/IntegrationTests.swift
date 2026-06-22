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
}

/// Check whether the AI integration tests are enabled.
private let isAITestEnabled: Bool =
    ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"
