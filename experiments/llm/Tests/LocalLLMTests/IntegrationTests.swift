import Foundation
import Synchronization
import Testing
@testable import LocalLLM

/// Env-gated model-backed integration tests.
///
/// These require the real ~8 GB Gemma 4 12B QAT model on disk and `LLM_RUN_AI=1`
/// in the environment. A bare `swift test` skips these entirely (fast, no model needed).
///
/// The model path is read from `LLM_MODEL_PATH` env var, or defaults to the standard
/// cache location: `~/Library/Application Support/Biscotti/llms/gemma-4-12b-it-UD-Q4_K_XL.gguf`
///
/// All tests share a single out-of-process connection (load-once/serve-many) to avoid
/// redundant ~8 GB model loads during test runs. The connection is opened lazily on
/// first use and reclaimed by the deinit `forceKill` backstop when the test process exits
/// (Swift Testing has no suite teardown hook).
@Suite("Integration (LLM_RUN_AI=1)", .enabled(if: isAITestEnabled), .serialized)
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

    /// Shared out-of-process connection loaded once for the entire suite.
    /// Protected by Mutex so the invariant is enforced by the type system,
    /// not just the `.serialized` trait.
    static let sharedConnection = Mutex<LLMConnection?>(nil)

    /// The child process PID captured at connection open time, for reclamation test.
    static let sharedPID = Mutex<pid_t>(0)

    /// Load or return the shared connection. First call opens an out-of-process
    /// connection (spawns the service, loads the model); subsequent calls return
    /// the cached instance.
    static func connection() async throws -> LLMConnection {
        if let existing = sharedConnection.withLock({ $0 }) {
            return existing
        }
        let config = EngineConfig(contextSize: 4096, seed: 42)
        let conn = try await LLMService.openConnection(
            model: modelPath,
            backend: .outOfProcess(),
            config: config
        )
        let pid = await conn.childPID ?? 0
        sharedConnection.withLock { $0 = conn }
        sharedPID.withLock { $0 = pid }
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
            prompt: "What is 2 + 2? Answer with just the number.",
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
            prompt: "Name three primary colors.",
            options: options
        )
        let result2 = try await conn.generate(
            prompt: "Name three primary colors.",
            options: options
        )

        // With temp 0 and the same seed, results should be identical
        #expect(
            result1.text == result2.text,
            "Expected deterministic output, got:\n  run1: \(result1.text)\n  run2: \(result2.text)"
        )
    }

    @Test("Streaming and buffered generate produce identical results")
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
            prompt: prompt, options: options
        )

        // Streaming generate -- collect all events
        let stream = await conn.generateStreaming(
            prompt: prompt, options: options
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

    @Test("Built-in template produces sane tokenization")
    func builtinTemplateSanity() async throws {
        let conn = try await Self.connection()

        // With the built-in template, a simple prompt should tokenize and generate successfully
        let options = GenerationOptions(
            maxTokens: 32,
            temperature: 0,
            seed: 42
        )

        let result = try await conn.generate(
            prompt: "Say hello.",
            system: "You are a friendly assistant.",
            options: options
        )

        #expect(!result.text.isEmpty)
        // The prompt should be more than just the raw text tokens (template added overhead)
        #expect(result.promptTokenCount > 5, "Template should add turn tokens to the prompt")
    }

    @Test("Reclamation: child process is gone after close")
    func reclamation() async throws {
        // Open a dedicated connection for this test (not the shared one)
        let config = EngineConfig(contextSize: 4096, seed: 42)
        let conn = try await LLMService.openConnection(
            model: Self.modelPath,
            backend: .outOfProcess(),
            config: config
        )

        let pid = await conn.childPID
        let childPID = try #require(pid, "Expected a child PID for out-of-process backend")
        #expect(childPID > 0, "PID must be positive")

        // Verify the child is running
        #expect(kill(childPID, 0) == 0, "Child process should be running")

        // Do one generate to confirm the connection works
        let result = try await conn.generate(
            prompt: "Say hi.",
            options: GenerationOptions(maxTokens: 16, temperature: 0, seed: 42)
        )
        #expect(!result.text.isEmpty)

        // Close and verify reclamation
        await conn.close()

        // Give the process a moment to exit
        try await Task.sleep(for: .milliseconds(500))

        let killResult = kill(childPID, 0)
        let savedErrno = errno
        #expect(killResult == -1, "Expected kill to fail (process should be gone)")
        #expect(savedErrno == ESRCH, "Expected ESRCH (no such process), got errno \(savedErrno)")
    }

    @Test("In-process parity: same prompt produces matching result")
    func inProcessParity() async throws {
        let options = GenerationOptions(
            maxTokens: 64,
            temperature: 0,
            seed: 42
        )
        let prompt = "What is the capital of France? Answer in one word."
        let config = EngineConfig(contextSize: 4096, seed: 42)

        // Out-of-process result (from shared connection)
        let conn = try await Self.connection()
        let oopResult = try await conn.generate(prompt: prompt, options: options)

        // In-process result (dedicated connection)
        let ipResult = try await LLMService.withConnection(
            model: Self.modelPath,
            backend: .inProcess,
            config: config
        ) { ipConn in
            try await ipConn.generate(prompt: prompt, options: options)
        }

        // Both should produce the same text with greedy decoding
        #expect(
            oopResult.text == ipResult.text,
            "In-process and out-of-process should produce identical output:\n  oop: \(oopResult.text)\n  ip: \(ipResult.text)"
        )
    }
}

/// Check whether the AI integration tests are enabled.
private let isAITestEnabled: Bool =
    ProcessInfo.processInfo.environment["LLM_RUN_AI"] == "1"
