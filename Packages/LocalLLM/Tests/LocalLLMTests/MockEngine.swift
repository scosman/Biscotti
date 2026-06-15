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

    // MARK: - InferenceEngine

    func generate(
        prompt _: String,
        system _: String?,
        options _: GenerationOptions
    ) async throws -> GenerationResult {
        lock.withLock { _generateCallCount += 1 }
        if let error = errorToThrow {
            throw error
        }
        return result
    }

    func generateStreaming(
        prompt _: String,
        system _: String?,
        options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _generateCallCount += 1 }

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
