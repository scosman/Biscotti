import Testing
@testable import LocalLLM

@Suite("GenerationOptions")
struct GenerationOptionsTests {
    @Test("Default values match Gemma-team recommendations")
    func defaultValues() {
        let opts = GenerationOptions.default
        #expect(opts.maxTokens == 2048)
        #expect(opts.temperature == 1.0)
        #expect(opts.topK == 64)
        #expect(opts.topP == 0.95)
        #expect(opts.minP == 0.0)
        #expect(opts.repeatPenalty == 1.0)
        #expect(opts.repeatLastN == 64)
        #expect(opts.seed == nil)
        #expect(opts.stopSequences.isEmpty)
        #expect(opts.applyChatTemplate == true)
    }

    @Test("Default thinking mode is off")
    func defaultThinkingOff() {
        let opts = GenerationOptions.default
        switch opts.thinking {
        case .off: break // expected
        case .auto: Issue.record("Expected .off, got .auto")
        }
    }

    @Test("Custom values override defaults")
    func customOverrides() {
        let opts = GenerationOptions(
            maxTokens: 512,
            temperature: 0.7,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repeatPenalty: 1.1,
            repeatLastN: 32,
            seed: 123,
            stopSequences: ["###"],
            applyChatTemplate: false,
            thinking: .auto
        )
        #expect(opts.maxTokens == 512)
        #expect(opts.temperature == 0.7)
        #expect(opts.topK == 40)
        #expect(opts.topP == 0.9)
        #expect(opts.minP == 0.05)
        #expect(opts.repeatPenalty == 1.1)
        #expect(opts.repeatLastN == 32)
        #expect(opts.seed == 123)
        #expect(opts.stopSequences == ["###"])
        #expect(opts.applyChatTemplate == false)
    }

    @Test("clampedMaxTokens respects remaining context")
    func clampedMaxTokensBasic() {
        let opts = GenerationOptions(maxTokens: 2048)
        // Context = 4096, prompt = 3000 -> remaining = 1096 -> clamp to 1096
        #expect(opts.clampedMaxTokens(promptTokenCount: 3000, contextSize: 4096) == 1096)
    }

    @Test("clampedMaxTokens returns maxTokens when plenty of room")
    func clampedMaxTokensNoClamp() {
        let opts = GenerationOptions(maxTokens: 512)
        #expect(opts.clampedMaxTokens(promptTokenCount: 100, contextSize: 4096) == 512)
    }

    @Test("clampedMaxTokens returns 0 when prompt fills context")
    func clampedMaxTokensZero() {
        let opts = GenerationOptions(maxTokens: 2048)
        #expect(opts.clampedMaxTokens(promptTokenCount: 4096, contextSize: 4096) == 0)
    }

    @Test("clampedMaxTokens handles prompt larger than context")
    func clampedMaxTokensOverflow() {
        let opts = GenerationOptions(maxTokens: 2048)
        #expect(opts.clampedMaxTokens(promptTokenCount: 5000, contextSize: 4096) == 0)
    }
}

@Suite("EngineConfig")
struct EngineConfigTests {
    @Test("Default values")
    func defaultValues() {
        let config = EngineConfig.default
        #expect(config.contextSize == 32768)
        #expect(config.nGpuLayers == 99)
        #expect(config.threadCount == nil)
        #expect(config.seed == 42)
    }

    @Test("Custom values")
    func customValues() {
        let config = EngineConfig(
            contextSize: 8192,
            nGpuLayers: 32,
            threadCount: 4,
            seed: 999
        )
        #expect(config.contextSize == 8192)
        #expect(config.nGpuLayers == 32)
        #expect(config.threadCount == 4)
        #expect(config.seed == 999)
    }
}
