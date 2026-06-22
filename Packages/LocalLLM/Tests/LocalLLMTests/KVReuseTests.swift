import Foundation
import Testing
@testable import LocalLLM

// MARK: - commonPrefixLength

@Suite("commonPrefixLength")
struct CommonPrefixLengthTests {
    @Test("Both arrays empty returns 0")
    func bothEmpty() {
        let result = LLMEngine.commonPrefixLength([], [])
        #expect(result == 0)
    }

    @Test("First array empty returns 0")
    func firstEmpty() {
        let result = LLMEngine.commonPrefixLength([], [1, 2, 3])
        #expect(result == 0)
    }

    @Test("Second array empty returns 0")
    func secondEmpty() {
        let result = LLMEngine.commonPrefixLength([1, 2, 3], [])
        #expect(result == 0)
    }

    @Test("Identical arrays returns full length")
    func identical() {
        let tokens: [Int32] = [10, 20, 30, 40]
        let result = LLMEngine.commonPrefixLength(tokens, tokens)
        #expect(result == 4)
    }

    @Test("Divergent at index 0 returns 0")
    func divergentAtZero() {
        let result = LLMEngine.commonPrefixLength([1, 2, 3], [9, 2, 3])
        #expect(result == 0)
    }

    @Test("Divergent at index k returns k")
    func divergentAtK() {
        let cached: [Int32] = [10, 20, 30, 40, 50]
        let incoming: [Int32] = [10, 20, 99, 40, 50]
        let result = LLMEngine.commonPrefixLength(cached, incoming)
        #expect(result == 2)
    }

    @Test("First is prefix of second returns first.count")
    func firstIsPrefixOfSecond() {
        let shorter: [Int32] = [1, 2, 3]
        let longer: [Int32] = [1, 2, 3, 4, 5]
        let result = LLMEngine.commonPrefixLength(shorter, longer)
        #expect(result == 3)
    }

    @Test("Second is prefix of first returns second.count")
    func secondIsPrefixOfFirst() {
        let longer: [Int32] = [1, 2, 3, 4, 5]
        let shorter: [Int32] = [1, 2, 3]
        let result = LLMEngine.commonPrefixLength(longer, shorter)
        #expect(result == 3)
    }

    @Test("Single-element match returns 1")
    func singleElementMatch() {
        let result = LLMEngine.commonPrefixLength([42], [42])
        #expect(result == 1)
    }

    @Test("Single-element mismatch returns 0")
    func singleElementMismatch() {
        let result = LLMEngine.commonPrefixLength([42], [99])
        #expect(result == 0)
    }
}

// MARK: - GenerationResult.cachedPromptTokenCount

@Suite("GenerationResult cachedPromptTokenCount")
struct CachedPromptTokenCountTests {
    @Test("cachedPromptTokenCount is stored and accessible")
    func storedValue() {
        let result = GenerationResult(
            text: "hello",
            reasoning: nil,
            promptTokenCount: 100,
            generatedTokenCount: 10,
            cachedPromptTokenCount: 75,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 0.5,
            totalDuration: 0.6,
            renderedPrompt: "",
            rawText: "hello",
            embeddedChatTemplate: nil
        )
        #expect(result.cachedPromptTokenCount == 75)
    }

    @Test("cachedPromptTokenCount survives Codable round-trip")
    func codableRoundTrip() throws {
        let result = GenerationResult(
            text: "test",
            reasoning: nil,
            promptTokenCount: 200,
            generatedTokenCount: 5,
            cachedPromptTokenCount: 150,
            finishReason: .eos,
            loadDuration: nil,
            promptEvalDuration: 0.05,
            generationDuration: 0.1,
            totalDuration: 0.15,
            renderedPrompt: "",
            rawText: "test",
            embeddedChatTemplate: nil
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(GenerationResult.self, from: data)
        #expect(decoded.cachedPromptTokenCount == 150)
        #expect(decoded == result)
    }

    @Test("cachedPromptTokenCount 0 for cold start")
    func zeroForColdStart() {
        let result = MockEngine.defaultResult()
        #expect(result.cachedPromptTokenCount == 0)
    }
}
