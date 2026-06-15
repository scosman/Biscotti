import Foundation
import Testing
@testable import LocalLLM

@Suite("LLMEventReceiver")
struct LLMEventReceiverTests {
    @Test("reportToken forwards to handler")
    func tokenForwarding() {
        let receiver = LLMEventReceiver()
        let collector = TokenCollector()

        receiver.setHandlers(
            onToken: { collector.append($0) },
            onReasoningToken: { _ in },
            onDone: { _ in },
            onError: { _ in }
        )

        receiver.reportToken("Hello")
        receiver.reportToken(" world")

        #expect(collector.values == ["Hello", " world"])
    }

    @Test("reportReasoningToken forwards to handler")
    func reasoningTokenForwarding() {
        let receiver = LLMEventReceiver()
        let collector = TokenCollector()

        receiver.setHandlers(
            onToken: { _ in },
            onReasoningToken: { collector.append($0) },
            onDone: { _ in },
            onError: { _ in }
        )

        receiver.reportReasoningToken("Let me")
        receiver.reportReasoningToken(" think...")

        #expect(collector.values == ["Let me", " think..."])
    }

    @Test("reportDone forwards result data to handler")
    func doneForwarding() throws {
        let receiver = LLMEventReceiver()
        let result = MockEngine.defaultResult(text: "The answer is 42.")
        let resultData = try JSONEncoder().encode(result)

        let dataBox = DataBox()
        receiver.setHandlers(
            onToken: { _ in },
            onReasoningToken: { _ in },
            onDone: { dataBox.set($0) },
            onError: { _ in }
        )

        receiver.reportDone(resultData: resultData)

        let decoded = try JSONDecoder().decode(
            GenerationResult.self, from: #require(dataBox.value)
        )
        #expect(decoded.text == "The answer is 42.")
    }

    @Test("reportError forwards error data to handler")
    func errorForwarding() throws {
        let receiver = LLMEventReceiver()
        let payload = LLMErrorPayload.generationFailed("Metal crashed")
        let errorData = try JSONEncoder().encode(payload)

        let dataBox = DataBox()
        receiver.setHandlers(
            onToken: { _ in },
            onReasoningToken: { _ in },
            onDone: { _ in },
            onError: { dataBox.set($0) }
        )

        receiver.reportError(errorData: errorData)

        let decoded = try JSONDecoder().decode(
            LLMErrorPayload.self, from: #require(dataBox.value)
        )
        #expect(decoded == .generationFailed("Metal crashed"))
    }

    @Test("clearHandlers causes callbacks to be dropped")
    func clearHandlersDropsCallbacks() {
        let receiver = LLMEventReceiver()
        let collector = TokenCollector()

        receiver.setHandlers(
            onToken: { collector.append($0) },
            onReasoningToken: { _ in },
            onDone: { _ in },
            onError: { _ in }
        )

        receiver.reportToken("Before")
        receiver.clearHandlers()
        receiver.reportToken("After")

        #expect(collector.values == ["Before"])
    }

    @Test("setHandlers replaces previous handlers")
    func setHandlersReplaces() {
        let receiver = LLMEventReceiver()
        let first = TokenCollector()
        let second = TokenCollector()

        receiver.setHandlers(
            onToken: { first.append($0) },
            onReasoningToken: { _ in },
            onDone: { _ in },
            onError: { _ in }
        )
        receiver.reportToken("A")

        receiver.setHandlers(
            onToken: { second.append($0) },
            onReasoningToken: { _ in },
            onDone: { _ in },
            onError: { _ in }
        )
        receiver.reportToken("B")

        #expect(first.values == ["A"])
        #expect(second.values == ["B"])
    }

    @Test("callbacks without handlers do not crash")
    func callbacksWithoutHandlers() {
        let receiver = LLMEventReceiver()

        // These should not crash -- just log and drop.
        receiver.reportToken("orphan token")
        receiver.reportReasoningToken("orphan reasoning")
        receiver.reportDone(resultData: Data())
        receiver.reportError(errorData: Data())
    }

    @Test("done and error both clear through correctly")
    func doneAndErrorSequence() throws {
        let receiver = LLMEventReceiver()
        let doneCounter = Counter()
        let errorCounter = Counter()

        receiver.setHandlers(
            onToken: { _ in },
            onReasoningToken: { _ in },
            onDone: { _ in doneCounter.increment() },
            onError: { _ in errorCounter.increment() }
        )

        let result = MockEngine.defaultResult()
        let resultData = try JSONEncoder().encode(result)
        receiver.reportDone(resultData: resultData)
        #expect(doneCounter.value == 1)
        #expect(errorCounter.value == 0)

        // Second round with fresh handlers
        receiver.setHandlers(
            onToken: { _ in },
            onReasoningToken: { _ in },
            onDone: { _ in doneCounter.increment() },
            onError: { _ in errorCounter.increment() }
        )

        let payload = LLMErrorPayload.cancelled
        let errorData = try JSONEncoder().encode(payload)
        receiver.reportError(errorData: errorData)
        #expect(doneCounter.value == 1)
        #expect(errorCounter.value == 1)
    }
}

// MARK: - Test Helpers

/// Thread-safe collector for string values.
private final class TokenCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.withLock { _values }
    }

    func append(_ value: String) {
        lock.withLock { _values.append(value) }
    }
}

/// Thread-safe box for a single optional `Data` value.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Data?

    var value: Data? {
        lock.withLock { _value }
    }

    func set(_ data: Data) {
        lock.withLock { _value = data }
    }
}

/// Thread-safe counter.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}
