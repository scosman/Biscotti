import Foundation
@testable import LocalLLM

/// A model-free `InferenceEngine` for unit tests.
///
/// Returns canned tokens and results without loading any model. Supports
/// scriptable errors and optional per-token delay for timing tests.
///
/// Usage:
/// ```swift
/// let engine = MockEngine(
///     tokens: ["Hello", " world"],
///     result: GenerationResult(text: "Hello world", ...)
/// )
/// ```
final class MockEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Scriptable state

    private var _tokens: [String]
    private var _reasoningTokens: [String]
    private var _result: GenerationResult
    private var _errorToThrow: (any Error)?
    private var _tokenDelay: Duration?
    private var _generateCallCount: Int = 0

    /// Optional signal fired when generate/generateStreaming enters (before token emission).
    /// Used by tests to deterministically detect that a generation has started.
    private var _onGenerationStarted: AsyncStream<Void>.Continuation?

    /// Tokens to emit during streaming generation.
    var tokens: [String] {
        get { lock.withLock { _tokens } }
        set { lock.withLock { _tokens = newValue } }
    }

    /// Reasoning tokens to emit before content tokens during streaming.
    var reasoningTokens: [String] {
        get { lock.withLock { _reasoningTokens } }
        set { lock.withLock { _reasoningTokens = newValue } }
    }

    /// The result returned by buffered `generate` and as the `.done` event in streaming.
    var result: GenerationResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    /// When set, `generate` and `generateStreaming` throw this error instead of
    /// returning a result.
    var errorToThrow: (any Error)? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    /// Optional delay between each token emission (for cancellation tests).
    var tokenDelay: Duration? {
        get { lock.withLock { _tokenDelay } }
        set { lock.withLock { _tokenDelay = newValue } }
    }

    /// How many times `generate` or `generateStreaming` has been called.
    var generateCallCount: Int {
        lock.withLock { _generateCallCount }
    }

    init(
        tokens: [String] = ["Hello", " world"],
        reasoningTokens: [String] = [],
        result: GenerationResult? = nil,
        errorToThrow: (any Error)? = nil,
        tokenDelay: Duration? = nil
    ) {
        _tokens = tokens
        _reasoningTokens = reasoningTokens
        _result = result ?? MockEngine.defaultResult(text: tokens.joined())
        _errorToThrow = errorToThrow
        _tokenDelay = tokenDelay
    }

    /// Create an `AsyncStream` that yields each time `generate`/`generateStreaming` enters.
    /// Opt-in: only tests that need deterministic start-detection call this. The returned
    /// stream yields one element per generation call; consume with `for await _ in stream`.
    func makeGenerationStartedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.withLock { _onGenerationStarted = continuation }
        }
    }

    // MARK: - InferenceEngine

    /// Canned token count for `countTokens`. Defaults to 100.
    var tokenCount: Int {
        get { lock.withLock { _tokenCount } }
        set { lock.withLock { _tokenCount = newValue } }
    }

    private var _tokenCount: Int = 100

    func countTokens(
        messages _: [LLMMessage],
        applyChatTemplate _: Bool,
        thinking _: ThinkingMode
    ) async throws -> Int {
        if let error = errorToThrow {
            throw error
        }
        return tokenCount
    }

    func generate(
        messages _: [LLMMessage],
        options _: GenerationOptions
    ) async throws -> GenerationResult {
        let continuation = lock.withLock {
            _generateCallCount += 1
            return _onGenerationStarted
        }
        continuation?.yield(())
        if let error = errorToThrow {
            throw error
        }
        // Apply token delay to the buffered path too so tests that observe
        // the .generating state have time to check before the result returns.
        if let delay = tokenDelay {
            try? await Task.sleep(for: delay)
        }
        return result
    }

    func generateStreaming(
        messages _: [LLMMessage],
        options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        let continuation = lock.withLock {
            _generateCallCount += 1
            return _onGenerationStarted
        }
        continuation?.yield(())

        // Capture current config under lock
        let capturedTokens = tokens
        let capturedReasoningTokens = reasoningTokens
        let capturedResult = result
        let capturedError = errorToThrow
        let capturedDelay = tokenDelay

        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error = capturedError {
                    continuation.finish(throwing: error)
                    return
                }

                // Emit reasoning tokens first
                for token in capturedReasoningTokens {
                    if Task.isCancelled {
                        continuation.finish(throwing: LocalLLMError.cancelled)
                        return
                    }
                    if let delay = capturedDelay {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled {
                            continuation.finish(throwing: LocalLLMError.cancelled)
                            return
                        }
                    }
                    continuation.yield(.reasoningToken(token))
                }

                // Emit content tokens
                for token in capturedTokens {
                    if Task.isCancelled {
                        continuation.finish(throwing: LocalLLMError.cancelled)
                        return
                    }
                    if let delay = capturedDelay {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled {
                            continuation.finish(throwing: LocalLLMError.cancelled)
                            return
                        }
                    }
                    continuation.yield(.token(token))
                }

                continuation.yield(.done(capturedResult))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func unload() async {
        // No-op for mock
    }

    // MARK: - Helpers

    /// A minimal `GenerationResult` for tests.
    static func defaultResult(text: String = "Hello world") -> GenerationResult {
        GenerationResult(
            text: text,
            reasoning: nil,
            promptTokenCount: 10,
            generatedTokenCount: 2,
            cachedPromptTokenCount: 0,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.01,
            generationDuration: 0.02,
            totalDuration: 0.03,
            renderedPrompt: "",
            rawText: text,
            embeddedChatTemplate: nil
        )
    }
}
