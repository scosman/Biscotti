import Testing
@testable import Intelligence

@Suite("ContextSizing")
struct ContextSizingTests {
    // MARK: - estimateInputTokens

    @Test("estimateInputTokens divides total character count by 2")
    func estimateBasic() {
        // 1000 system + 2000 user = 3000 chars / 2 = 1500
        #expect(ContextSizing.estimateInputTokens(systemCharCount: 1000, userCharCount: 2000) == 1500)
    }

    @Test("estimateInputTokens with no system message")
    func estimateNoSystem() {
        #expect(ContextSizing.estimateInputTokens(systemCharCount: 0, userCharCount: 500) == 250)
    }

    @Test("estimateInputTokens floors to minimum of 1")
    func estimateMinimum() {
        // Both empty: (0 + 0) / 2 = 0, clamped to 1
        #expect(ContextSizing.estimateInputTokens(systemCharCount: 0, userCharCount: 0) == 1)
        // Single char: (0 + 1) / 2 = 0 (integer division), clamped to 1
        #expect(ContextSizing.estimateInputTokens(systemCharCount: 0, userCharCount: 1) == 1)
    }

    @Test("estimateInputTokens with odd total truncates via integer division")
    func estimateOddTotal() {
        // 3 + 4 = 7, / 2 = 3 (integer division)
        #expect(ContextSizing.estimateInputTokens(systemCharCount: 3, userCharCount: 4) == 3)
    }

    // MARK: - contextSize (single pair)

    @Test("contextSize adds output reservation for short messages")
    func contextSizeShortMessages() {
        let system = String(repeating: "x", count: 400)
        let user = String(repeating: "y", count: 600)
        // (400 + 600) / 2 = 500 estimated tokens + 3072 = 3572
        let size = ContextSizing.contextSize(forSystem: system, user: user)
        #expect(size == 500 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize caps at maxContextSize for long inputs")
    func contextSizeCapped() {
        // 60000 chars user -> (0 + 60000) / 2 = 30000 + 3072 = 33072, capped at 32768
        let system = ""
        let user = String(repeating: "z", count: 60000)
        let size = ContextSizing.contextSize(forSystem: system, user: user)
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("contextSize with typical summary prompt")
    func contextSizeTypicalSummary() {
        // System ~300 chars, user ~10000 chars (short transcript)
        let system = String(repeating: "s", count: 300)
        let user = String(repeating: "u", count: 10000)
        // (300 + 10000) / 2 = 5150 + 3072 = 8222
        let size = ContextSizing.contextSize(forSystem: system, user: user)
        #expect(size == 5150 + ContextSizing.outputTokenReservation)
    }

    // MARK: - contextSize (multi-pair)

    @Test("contextSize forPairs uses the largest pair")
    func multiPairUsesMax() {
        let smallSystem = String(repeating: "a", count: 100)
        let smallUser = String(repeating: "b", count: 200)
        let largeSystem = String(repeating: "c", count: 500)
        let largeUser = String(repeating: "d", count: 10000)

        let pairs = [
            (system: smallSystem, user: smallUser),
            (system: largeSystem, user: largeUser)
        ]
        let size = ContextSizing.contextSize(forPairs: pairs)

        // Large pair: (500 + 10000) / 2 = 5250
        // Small pair: (100 + 200) / 2 = 150
        // Max = 5250 + 3072 = 8322
        #expect(size == 5250 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize forPairs with empty array returns minimum + reservation")
    func multiPairEmpty() {
        let size = ContextSizing.contextSize(forPairs: [])
        // max of empty is nil, fallback to 1, so 1 + 3072 = 3073
        #expect(size == 1 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize forPairs caps at maxContextSize")
    func multiPairCapped() {
        let longUser = String(repeating: "x", count: 65000)
        let pairs = [
            (system: "", user: longUser)
        ]
        let size = ContextSizing.contextSize(forPairs: pairs)
        #expect(size == ContextSizing.maxContextSize)
    }

    // MARK: - Constants

    @Test("outputTokenReservation is 3072")
    func outputReservation() {
        #expect(ContextSizing.outputTokenReservation == 3072)
    }

    @Test("maxContextSize is 32768")
    func maxContext() {
        #expect(ContextSizing.maxContextSize == 32768)
    }

    // MARK: - End-to-end scenarios

    @Test("Short meeting transcript: context well under 32k")
    func endToEndShortTranscript() {
        // Typical short meeting: ~300 char system, ~5000 char transcript
        let system = String(repeating: "s", count: 300)
        let user = String(repeating: "t", count: 5000)
        let size = ContextSizing.contextSize(forSystem: system, user: user)
        // (300 + 5000) / 2 = 2650 + 3072 = 5722 — saves ~27k vs static 32k
        #expect(size == 5722)
        #expect(size < ContextSizing.maxContextSize)
    }

    @Test("Long meeting transcript: hits cap, no memory regression")
    func endToEndLongTranscript() {
        // Long meeting: ~300 char system, ~60000 char transcript
        let system = String(repeating: "s", count: 300)
        let user = String(repeating: "t", count: 60000)
        let size = ContextSizing.contextSize(forSystem: system, user: user)
        // Capped at 32768 — identical to the old static allocation
        #expect(size == ContextSizing.maxContextSize)
    }
}
