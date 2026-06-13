import Testing

@testable import LocalLLM

@Suite("GenerationResult")
struct GenerationResultTests {
    @Test("tokensPerSecond with known values")
    func tokensPerSecondBasic() {
        let result = GenerationResult(
            text: "Hello",
            reasoning: nil,
            promptTokenCount: 10,
            generatedTokenCount: 100,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.5,
            generationDuration: 4.0,
            totalDuration: 4.5,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        #expect(result.tokensPerSecond == 25.0)
    }

    @Test("tokensPerSecond returns 0 when generationDuration is 0")
    func tokensPerSecondZeroDuration() {
        let result = GenerationResult(
            text: "Hello",
            reasoning: nil,
            promptTokenCount: 10,
            generatedTokenCount: 100,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.5,
            generationDuration: 0.0,
            totalDuration: 0.5,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        #expect(result.tokensPerSecond == 0)
    }

    @Test("tokensPerSecond handles fractional values")
    func tokensPerSecondFractional() {
        let result = GenerationResult(
            text: "",
            reasoning: nil,
            promptTokenCount: 0,
            generatedTokenCount: 187,
            finishReason: .eos,
            loadDuration: 1.0,
            promptEvalDuration: 0.83,
            generationDuration: 6.4,
            totalDuration: 7.23,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        let tps = result.tokensPerSecond
        #expect(abs(tps - 29.21875) < 0.001)
    }

    @Test("All finish reasons are representable")
    func finishReasons() {
        let reasons: [FinishReason] = [.endOfTurn, .eos, .maxTokens, .stopSequence]
        #expect(reasons.count == 4)
    }

    @Test("loadDuration is optional")
    func loadDurationOptional() {
        let withLoad = GenerationResult(
            text: "", reasoning: nil, promptTokenCount: 0, generatedTokenCount: 0,
            finishReason: .eos, loadDuration: 2.5, promptEvalDuration: 0.1,
            generationDuration: 0.1, totalDuration: 0.2,
            renderedPrompt: "", rawText: "",
            embeddedChatTemplate: nil
        )
        #expect(withLoad.loadDuration == 2.5)

        let withoutLoad = GenerationResult(
            text: "", reasoning: nil, promptTokenCount: 0, generatedTokenCount: 0,
            finishReason: .eos, loadDuration: nil, promptEvalDuration: 0.1,
            generationDuration: 0.1, totalDuration: 0.2,
            renderedPrompt: "", rawText: "",
            embeddedChatTemplate: nil
        )
        #expect(withoutLoad.loadDuration == nil)
    }

    @Test("reasoning field stores thinking content")
    func reasoningField() {
        let withReasoning = GenerationResult(
            text: "The answer is 42.",
            reasoning: "Let me think about this...",
            promptTokenCount: 10,
            generatedTokenCount: 20,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 1.0,
            totalDuration: 1.1,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        #expect(withReasoning.reasoning == "Let me think about this...")
    }
}
