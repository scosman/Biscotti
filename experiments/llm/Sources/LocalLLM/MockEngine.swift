import Foundation

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
public final class MockEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Scriptable state

    private var _tokens: [String]
    private var _reasoningTokens: [String]
    private var _result: GenerationResult
    private var _errorToThrow: (any Error)?
    private var _tokenDelay: Duration?
    private var _generateCallCount: Int = 0

    /// Tokens to emit during streaming generation.
    public var tokens: [String] {
        get { lock.withLock { _tokens } }
        set { lock.withLock { _tokens = newValue } }
    }

    /// Reasoning tokens to emit before content tokens during streaming.
    public var reasoningTokens: [String] {
        get { lock.withLock { _reasoningTokens } }
        set { lock.withLock { _reasoningTokens = newValue } }
    }

    /// The result returned by buffered `generate` and as the `.done` event in streaming.
    public var result: GenerationResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    /// When set, `generate` and `generateStreaming` throw this error instead of
    /// returning a result.
    public var errorToThrow: (any Error)? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    /// Optional delay between each token emission (for cancellation tests).
    public var tokenDelay: Duration? {
        get { lock.withLock { _tokenDelay } }
        set { lock.withLock { _tokenDelay = newValue } }
    }

    /// How many times `generate` or `generateStreaming` has been called.
    public var generateCallCount: Int {
        lock.withLock { _generateCallCount }
    }

    public init(
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

    public func generate(
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult {
        lock.withLock { _generateCallCount += 1 }
        if let error = errorToThrow {
            throw error
        }
        return result
    }

    public func generateStreaming(
        prompt: String,
        system: String?,
        options: GenerationOptions
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

    public func unload() async {
        // No-op for mock
    }

    // MARK: - Helpers

    /// A minimal `GenerationResult` for tests.
    public static func defaultResult(text: String = "Hello world") -> GenerationResult {
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
