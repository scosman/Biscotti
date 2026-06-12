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
/// cache location: `~/Library/Caches/net.scosman.biscotti.localllm/gemma-4-12b-it-UD-Q4_K_XL.gguf`
///
/// All tests share a single engine instance (load-once/generate-many) to avoid
/// redundant ~8 GB model loads during Phase 4 runs.
@Suite("Integration (LLM_RUN_AI=1)", .enabled(if: isAITestEnabled), .serialized)
struct IntegrationTests {
    static let modelPath: URL = {
        if let envPath = ProcessInfo.processInfo.environment["LLM_MODEL_PATH"] {
            return URL(fileURLWithPath: envPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Caches/net.scosman.biscotti.localllm")
            .appendingPathComponent("gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }()

    /// Shared engine loaded once for the entire suite. Protected by Mutex so the
    /// invariant is enforced by the type system, not just the `.serialized` trait.
    static let sharedEngine = Mutex<LLMEngine?>(nil)

    /// Load or return the shared engine. First call performs the expensive model load;
    /// subsequent calls return the cached instance.
    static func engine() async throws -> LLMEngine {
        if let existing = sharedEngine.withLock({ $0 }) {
            return existing
        }
        let config = EngineConfig(contextSize: 4096, seed: 42)
        let engine = try await LLMEngine(modelPath: modelPath, config: config)
        sharedEngine.withLock { $0 = engine }
        return engine
    }

    @Test("Stack works: load, generate, sane result")
    func stackWorks() async throws {
        let engine = try await Self.engine()

        let options = GenerationOptions(
            maxTokens: 128,
            temperature: 0, // greedy for determinism
            seed: 42
        )

        let result = try await engine.generate(
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
        let engine = try await Self.engine()

        let options = GenerationOptions(
            maxTokens: 64,
            temperature: 0,
            seed: 42
        )

        let result1 = try await engine.generate(
            prompt: "Name three primary colors.",
            options: options
        )
        let result2 = try await engine.generate(
            prompt: "Name three primary colors.",
            options: options
        )

        // With temp 0 and the same seed, results should be identical
        #expect(
            result1.text == result2.text,
            "Expected deterministic output, got:\n  run1: \(result1.text)\n  run2: \(result2.text)"
        )
    }

    @Test("Built-in template produces sane tokenization")
    func builtinTemplateSanity() async throws {
        let engine = try await Self.engine()

        // With the built-in template, a simple prompt should tokenize and generate successfully
        let options = GenerationOptions(
            maxTokens: 32,
            temperature: 0,
            seed: 42
        )

        let result = try await engine.generate(
            prompt: "Say hello.",
            system: "You are a friendly assistant.",
            options: options
        )

        #expect(!result.text.isEmpty)
        // The prompt should be more than just the raw text tokens (template added overhead)
        #expect(result.promptTokenCount > 5, "Template should add turn tokens to the prompt")
    }
}

/// Check whether the AI integration tests are enabled.
private let isAITestEnabled: Bool = {
    ProcessInfo.processInfo.environment["LLM_RUN_AI"] == "1"
}()
