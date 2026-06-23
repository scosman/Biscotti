import Foundation
import Testing
@testable import LocalLLM

// MARK: - Connection Lifecycle

@Suite("LLMConnection Lifecycle")
struct ConnectionLifecycleTests {
    @Test("Open connection transitions to ready")
    func openReady() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)
        let state = await conn.state
        #expect(state == .ready)
        await conn.close()
    }

    @Test("Close transitions to closed")
    func closeTransition() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)
        await conn.close()
        let state = await conn.state
        #expect(state == .closed)
    }

    @Test("Idempotent close does not error")
    func idempotentClose() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)
        await conn.close()
        await conn.close()
        await conn.close()
        let state = await conn.state
        #expect(state == .closed)
    }

    @Test("Reuse after close throws connectionClosed")
    func reuseAfterClose() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)
        await conn.close()

        do {
            _ = try await conn.generate(messages: [.user("test")])
            Issue.record("Expected connectionClosed error")
        } catch let error as LLMServiceError {
            #expect(error == .connectionClosed)
        }
    }

    @Test("Streaming after close throws connectionClosed")
    func streamingAfterClose() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)
        await conn.close()

        let stream = await conn.generateStreaming(messages: [.user("test")])
        do {
            for try await _ in stream {
                Issue.record("Should not yield any events")
            }
            Issue.record("Expected connectionClosed error")
        } catch let error as LLMServiceError {
            #expect(error == .connectionClosed)
        }
    }
}

// MARK: - Buffered Generation

@Suite("LLMConnection Buffered Generation")
struct BufferedGenerationTests {
    @Test("Generate returns MockEngine result")
    func bufferedGenerate() async throws {
        let expectedResult = MockEngine.defaultResult(text: "test output")
        let engine = MockEngine(tokens: ["test", " output"], result: expectedResult)
        let conn = try await LLMService.openConnection(engine: engine)

        let result = try await conn.generate(messages: [.user("test prompt")])
        #expect(result == expectedResult)
        #expect(engine.generateCallCount == 1)

        await conn.close()
    }

    @Test("Multiple sequential generates work")
    func multipleGenerates() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)

        let result1 = try await conn.generate(messages: [.user("first")])
        let result2 = try await conn.generate(messages: [.user("second")])
        #expect(result1 == result2) // Same mock result
        #expect(engine.generateCallCount == 2)

        await conn.close()
    }

    @Test("State transitions through generating and back to ready")
    func stateTransitions() async throws {
        // Use a delay so we can observe the generating state
        let engine = MockEngine(tokenDelay: .milliseconds(100))
        let conn = try await LLMService.openConnection(engine: engine)

        let stateBefore = await conn.state
        #expect(stateBefore == .ready)

        // Wait for the engine to signal that generation has actually started
        // before observing the .generating state.
        let startedStream = engine.makeGenerationStartedStream()

        let task = Task {
            try await conn.generate(messages: [.user("test")])
        }

        // Wait for the engine to enter generation
        var startedIter = startedStream.makeAsyncIterator()
        await startedIter.next()

        let stateGenerating = await conn.state
        #expect(stateGenerating == .generating)

        let result = try await task.value
        #expect(result.text == "Hello world")

        let stateAfter = await conn.state
        #expect(stateAfter == .ready)

        await conn.close()
    }
}

// MARK: - Streaming Generation

@Suite("LLMConnection Streaming Generation")
struct StreamingGenerationTests {
    @Test("Streaming yields tokens then done")
    func streamingRelay() async throws {
        let expectedResult = MockEngine.defaultResult(text: "Hello world")
        let engine = MockEngine(tokens: ["Hello", " world"], result: expectedResult)
        let conn = try await LLMService.openConnection(engine: engine)

        var tokens: [String] = []
        var doneResult: GenerationResult?

        let stream = await conn.generateStreaming(messages: [.user("test")])
        for try await event in stream {
            switch event {
            case let .token(piece):
                tokens.append(piece)
            case .reasoningToken:
                Issue.record("Unexpected reasoning token")
            case let .done(result):
                doneResult = result
            }
        }

        #expect(tokens == ["Hello", " world"])
        #expect(doneResult == expectedResult)

        await conn.close()
    }

    @Test("Streaming with reasoning tokens")
    func streamingWithReasoning() async throws {
        let engine = MockEngine(
            tokens: ["answer"],
            reasoningTokens: ["think", "ing"]
        )
        let conn = try await LLMService.openConnection(engine: engine)

        var contentTokens: [String] = []
        var reasoningTokens: [String] = []

        let stream = await conn.generateStreaming(messages: [.user("test")])
        for try await event in stream {
            switch event {
            case let .token(piece):
                contentTokens.append(piece)
            case let .reasoningToken(piece):
                reasoningTokens.append(piece)
            case .done:
                break
            }
        }

        #expect(reasoningTokens == ["think", "ing"])
        #expect(contentTokens == ["answer"])

        await conn.close()
    }

    @Test("State returns to ready after streaming completes")
    func stateAfterStreaming() async throws {
        let engine = MockEngine()
        let conn = try await LLMService.openConnection(engine: engine)

        let stream = await conn.generateStreaming(messages: [.user("test")])
        for try await _ in stream {}

        let state = await conn.state
        #expect(state == .ready)

        await conn.close()
    }
}

// MARK: - Serial Ordering

@Suite("LLMConnection Serial Queue")
struct SerialOrderingTests {
    @Test("Overlapping generates complete in submission order")
    func serialOrdering() async throws {
        // Use a delay to ensure the first call holds the semaphore while the
        // second is submitted.
        let engine = MockEngine(tokenDelay: .milliseconds(20))
        let conn = try await LLMService.openConnection(engine: engine)

        // Deterministic signal: wait for the engine to confirm the first
        // generation has actually started before launching the second task.
        let startedStream = engine.makeGenerationStartedStream()
        var startedIter = startedStream.makeAsyncIterator()

        // Track completion order via an actor-isolated array
        let tracker = OrderTracker()

        async let first: Void = {
            _ = try await conn.generate(messages: [.user("first")])
            await tracker.record(1)
        }()

        // Wait for the first generate to enter the engine (semaphore acquired).
        await startedIter.next()

        async let second: Void = {
            _ = try await conn.generate(messages: [.user("second")])
            await tracker.record(2)
        }()

        try await first
        try await second

        let order = await tracker.order
        #expect(order == [1, 2])
        #expect(engine.generateCallCount == 2)

        await conn.close()
    }
}

// MARK: - Failed State Transitions

@Suite("LLMConnection Failed State")
struct FailedStateTests {
    @Test("serviceInterrupted transitions connection to .failed")
    func serviceInterruptedMarksFailed() async throws {
        let backend = FailingBackend(
            error: LLMServiceError.serviceInterrupted
        )
        let conn = LLMConnection(backend: backend)
        try await conn.start()

        let stateBefore = await conn.state
        #expect(stateBefore == .ready)

        do {
            _ = try await conn.generate(messages: [.user("test")])
            Issue.record("Expected serviceInterrupted error")
        } catch let error as LLMServiceError {
            #expect(error == .serviceInterrupted)
        }

        let stateAfter = await conn.state
        #expect(stateAfter == .failed(.serviceInterrupted))

        // Subsequent generate should throw the failed error without re-entering the backend
        let callsBefore = backend.generateCallCount
        do {
            _ = try await conn.generate(messages: [.user("another")])
            Issue.record("Expected failed error on subsequent call")
        } catch let error as LLMServiceError {
            #expect(error == .serviceInterrupted)
        }
        #expect(backend.generateCallCount == callsBefore)

        await conn.close()
    }

    @Test("protocolError transitions connection to .failed")
    func protocolErrorMarksFailed() async throws {
        let backend = FailingBackend(
            error: LLMServiceError.protocolError("bad frame")
        )
        let conn = LLMConnection(backend: backend)
        try await conn.start()

        do {
            _ = try await conn.generate(messages: [.user("test")])
            Issue.record("Expected protocolError")
        } catch let error as LLMServiceError {
            #expect(error == .protocolError("bad frame"))
        }

        let stateAfter = await conn.state
        #expect(stateAfter == .failed(.protocolError("bad frame")))

        await conn.close()
    }

    @Test("Per-request error leaves connection ready")
    func perRequestErrorStaysReady() async throws {
        let backend = FailingBackend(
            error: LocalLLMError.contextOverflow(promptTokens: 5000, contextSize: 4096)
        )
        let conn = LLMConnection(backend: backend)
        try await conn.start()

        do {
            _ = try await conn.generate(messages: [.user("test")])
            Issue.record("Expected contextOverflow error")
        } catch is LocalLLMError {
            // Expected
        }

        let stateAfter = await conn.state
        #expect(stateAfter == .ready)

        await conn.close()
    }

    @Test("serviceInterrupted in streaming transitions to .failed")
    func serviceInterruptedInStreamingMarksFailed() async throws {
        let backend = FailingBackend(
            error: LLMServiceError.serviceInterrupted
        )
        let conn = LLMConnection(backend: backend)
        try await conn.start()

        let stream = await conn.generateStreaming(messages: [.user("test")])
        do {
            for try await _ in stream {
                Issue.record("Should not yield events")
            }
            Issue.record("Expected serviceInterrupted")
        } catch let error as LLMServiceError {
            #expect(error == .serviceInterrupted)
        }

        let stateAfter = await conn.state
        #expect(stateAfter == .failed(.serviceInterrupted))

        await conn.close()
    }
}

// MARK: - FailingBackend

/// A test-only `ServiceBackend` that throws a configurable error from
/// `generate`/`generateStreaming`. Used to test `LLMConnection`'s error-handling
/// paths that `MockEngine` + `InProcessBackend` cannot trigger (e.g.
/// `LLMServiceError.serviceInterrupted`).
private final class FailingBackend: ServiceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let error: any Error
    private var _generateCallCount = 0

    var generateCallCount: Int {
        lock.withLock { _generateCallCount }
    }

    init(error: any Error) {
        self.error = error
    }

    func start() async throws {
        // No-op: transitions to ready.
    }

    func countTokens(
        messages _: [LLMMessage],
        applyChatTemplate _: Bool, thinking _: ThinkingMode
    ) async throws -> Int {
        throw error
    }

    func reconfigure(contextSize _: Int) async throws {
        throw error
    }

    func generate(
        id _: UInt64, messages _: [LLMMessage],
        options _: GenerationOptions
    ) async throws -> GenerationResult {
        lock.withLock { _generateCallCount += 1 }
        throw error
    }

    func generateStreaming(
        id _: UInt64, messages _: [LLMMessage],
        options _: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _generateCallCount += 1 }
        let capturedError = error
        return AsyncThrowingStream { $0.finish(throwing: capturedError) }
    }

    func cancel(id _: UInt64) async {}

    func shutdown() async {}

    nonisolated func forceKill() {}
}

/// Actor to track completion order safely across concurrent tasks.
private actor OrderTracker {
    var order: [Int] = []
    func record(_ value: Int) {
        order.append(value)
    }
}

// MARK: - withConnection

@Suite("LLMService.withConnection")
struct WithConnectionTests {
    @Test("withConnection closes on successful return")
    func closesOnSuccess() async throws {
        let engine = MockEngine()
        let capturedConnection = ConnectionBox()

        let result = try await LLMService.withConnection(engine: engine) { conn in
            await capturedConnection.set(conn)
            return try await conn.generate(messages: [.user("test")])
        }

        #expect(result.text == "Hello world")
        let capturedConn = await capturedConnection.get()
        let conn = try #require(capturedConn)
        let state = await conn.state
        #expect(state == .closed)
    }

    @Test("withConnection closes on throw")
    func closesOnThrow() async throws {
        let engine = MockEngine()
        let capturedConnection = ConnectionBox()

        struct TestError: Error {}

        do {
            try await LLMService.withConnection(engine: engine) { conn in
                await capturedConnection.set(conn)
                throw TestError()
            }
            Issue.record("Expected TestError to propagate")
        } catch is TestError {
            // Expected
        }

        let capturedConn = await capturedConnection.get()
        let conn = try #require(capturedConn)
        let state = await conn.state
        #expect(state == .closed)
    }

    @Test("withConnection returns body value")
    func returnsBodyValue() async throws {
        let engine = MockEngine()
        let value = try await LLMService.withConnection(engine: engine) { _ in
            42
        }
        #expect(value == 42)
    }

    @Test("withConnection closes on cancellation")
    func closesOnCancellation() async throws {
        // Engine with a long delay so the body is still running when we cancel
        let engine = MockEngine(
            tokens: (0 ..< 100).map { "tok\($0)" },
            tokenDelay: .milliseconds(50)
        )
        let capturedConnection = ConnectionBox()

        // Deterministic start signal: wait for the engine to confirm generation
        // has begun before cancelling, replacing the old fixed sleep.
        let startedStream = engine.makeGenerationStartedStream()

        let task = Task {
            try await LLMService.withConnection(engine: engine) { conn in
                await capturedConnection.set(conn)
                // Start a long generation that will be interrupted by cancellation
                _ = try await conn.generate(messages: [.user("long")])
            }
        }

        // Wait for the engine to actually begin generation, then cancel.
        var startedIter = startedStream.makeAsyncIterator()
        await startedIter.next()
        task.cancel()

        // Wait for the task to finish (it will throw CancellationError)
        do {
            try await task.value
        } catch {
            // Expected: cancellation
        }

        // Connection should be closed even though cancellation occurred
        let capturedConn = await capturedConnection.get()
        let conn = try #require(capturedConn)
        let state = await conn.state
        #expect(state == .closed)
    }
}

/// Actor to capture a connection reference from inside a closure.
private actor ConnectionBox {
    private var connection: LLMConnection?
    func set(_ conn: LLMConnection) {
        connection = conn
    }

    func get() -> LLMConnection? {
        connection
    }
}

// MARK: - Cancellation

@Suite("LLMConnection Cancellation")
struct CancellationTests {
    @Test("Cancellation releases the semaphore for the next caller")
    func cancellationReleasesSemaphore() async throws {
        // Engine with a long delay so we can cancel mid-generation
        let engine = MockEngine(
            tokens: (0 ..< 100).map { "tok\($0)" },
            tokenDelay: .milliseconds(50)
        )
        let conn = try await LLMService.openConnection(engine: engine)

        // Deterministic start signal: wait for the engine to confirm generation
        // has begun before cancelling, replacing the old fixed sleep.
        let startedStream = engine.makeGenerationStartedStream()

        // Start a long generation and cancel it
        let task = Task {
            _ = try await conn.generate(messages: [.user("long")])
        }

        // Wait for the engine to actually begin generation, then cancel.
        var startedIter = startedStream.makeAsyncIterator()
        await startedIter.next()
        task.cancel()

        // Wait for cancellation to propagate
        do {
            try await task.value
        } catch {
            // Expected: cancelled
        }

        // Now another generate should succeed (semaphore was released)
        // Reset engine to fast mode
        engine.tokens = ["ok"]
        engine.result = MockEngine.defaultResult(text: "ok")
        engine.tokenDelay = nil

        let result = try await conn.generate(messages: [.user("next")])
        #expect(result.text == "ok")

        await conn.close()
    }
}

// MARK: - Error Handling

@Suite("LLMConnection Error Handling")
struct ErrorHandlingTests {
    @Test("MockEngine error surfaces as LocalLLMError")
    func mockErrorSurfaces() async throws {
        let engine = MockEngine(
            errorToThrow: LocalLLMError.contextOverflow(promptTokens: 5000, contextSize: 4096)
        )
        let conn = try await LLMService.openConnection(engine: engine)

        do {
            _ = try await conn.generate(messages: [.user("test")])
            Issue.record("Expected error")
        } catch let error as LocalLLMError {
            #expect(error == .contextOverflow(promptTokens: 5000, contextSize: 4096))
        }

        // Connection should still be usable after a per-request error
        engine.errorToThrow = nil
        let result = try await conn.generate(messages: [.user("recovery")])
        #expect(result.text == "Hello world")

        await conn.close()
    }

    @Test("MockEngine error in streaming surfaces correctly")
    func mockErrorInStreaming() async throws {
        let engine = MockEngine(
            errorToThrow: LocalLLMError.generationFailed("Metal crash")
        )
        let conn = try await LLMService.openConnection(engine: engine)

        let stream = await conn.generateStreaming(messages: [.user("test")])
        do {
            for try await _ in stream {
                Issue.record("Should not yield events on error")
            }
            Issue.record("Expected error")
        } catch let error as LocalLLMError {
            #expect(error == .generationFailed("Metal crash"))
        }

        // Connection should still be usable
        engine.errorToThrow = nil
        let result = try await conn.generate(messages: [.user("recovery")])
        #expect(result.text == "Hello world")

        await conn.close()
    }
}
