import Foundation
import Testing
@testable import LocalLLM

// MARK: - Codable Round-Trip Helpers

/// Encode then decode a value, returning the decoded copy.
private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - LLMLoadRequest

@Suite("LLMLoadRequest Codable")
struct LLMLoadRequestTests {
    @Test("Default config round-trips")
    func defaultConfigRoundTrip() throws {
        let request = LLMLoadRequest(
            modelPath: "/path/to/model.gguf",
            config: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.modelPath == "/path/to/model.gguf")
        #expect(decoded.config == .default)
    }

    @Test("Custom config round-trips")
    func customConfigRoundTrip() throws {
        let config = EngineConfig(
            contextSize: 8192, nGpuLayers: 32, threadCount: 4, seed: 999
        )
        let request = LLMLoadRequest(
            modelPath: "/models/gemma-4-12b.gguf",
            config: config
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.config.contextSize == 8192)
        #expect(decoded.config.nGpuLayers == 32)
        #expect(decoded.config.threadCount == 4)
        #expect(decoded.config.seed == 999)
    }

    @Test("Config with nil threadCount round-trips")
    func nilThreadCountRoundTrip() throws {
        let config = EngineConfig(threadCount: nil)
        let request = LLMLoadRequest(modelPath: "/model.gguf", config: config)
        let decoded = try roundTrip(request)
        #expect(decoded.config.threadCount == nil)
    }
}

// MARK: - LLMCountTokensRequest

@Suite("LLMCountTokensRequest Codable")
struct LLMCountTokensRequestTests {
    @Test("Default request round-trips")
    func defaultRoundTrip() throws {
        let request = LLMCountTokensRequest(
            user: "Hello world",
            system: "You are helpful.",
            applyChatTemplate: true,
            thinking: .off
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.user == "Hello world")
        #expect(decoded.system == "You are helpful.")
        #expect(decoded.applyChatTemplate == true)
        #expect(decoded.thinking == .off)
    }

    @Test("Request with nil system round-trips")
    func nilSystemRoundTrip() throws {
        let request = LLMCountTokensRequest(
            user: "Test prompt",
            system: nil
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.system == nil)
    }

    @Test("Request with thinking auto round-trips")
    func thinkingAutoRoundTrip() throws {
        let request = LLMCountTokensRequest(
            user: "Analyze this.",
            system: "Think carefully.",
            applyChatTemplate: true,
            thinking: .auto
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.thinking == .auto)
    }

    @Test("Request with raw mode (no template) round-trips")
    func rawModeRoundTrip() throws {
        let request = LLMCountTokensRequest(
            user: "Raw prompt text",
            system: nil,
            applyChatTemplate: false,
            thinking: .off
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.applyChatTemplate == false)
    }
}

// MARK: - LLMGenerateRequest

@Suite("LLMGenerateRequest Codable")
struct LLMGenerateRequestTests {
    @Test("Basic request round-trips")
    func basicRoundTrip() throws {
        let request = LLMGenerateRequest(
            prompt: "Summarize this meeting.",
            system: nil,
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.prompt == "Summarize this meeting.")
        #expect(decoded.system == nil)
        #expect(decoded.options == .default)
    }

    @Test("Request with system message round-trips")
    func withSystemRoundTrip() throws {
        let request = LLMGenerateRequest(
            prompt: "What are the action items?",
            system: "You are a meeting assistant.",
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.system == "You are a meeting assistant.")
    }

    @Test("Request with custom options round-trips")
    func customOptionsRoundTrip() throws {
        let options = GenerationOptions(
            maxTokens: 512,
            temperature: 0.7,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repeatPenalty: 1.1,
            repeatLastN: 32,
            seed: 123_456,
            stopSequences: ["###", "END"],
            applyChatTemplate: false,
            thinking: .auto
        )
        let request = LLMGenerateRequest(
            prompt: "Test prompt",
            system: "Test system",
            options: options
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.options.maxTokens == 512)
        #expect(decoded.options.thinking == .auto)
        #expect(decoded.options.stopSequences == ["###", "END"])
    }

    @Test("Request with empty prompt round-trips")
    func emptyPromptRoundTrip() throws {
        let request = LLMGenerateRequest(
            prompt: "",
            system: nil,
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded.prompt == "")
    }

    @Test("Request with Unicode content round-trips")
    func unicodeRoundTrip() throws {
        let request = LLMGenerateRequest(
            prompt: "Zusammenfassung bitte. \u{1F4DD}",
            system: "Du bist ein Assistent.",
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }
}

// MARK: - Negative / Boundary Decode Tests

@Suite("DTO decode failures")
struct DTODecodeFailureTests {
    @Test("LLMGenerateRequest missing required 'prompt' field")
    func missingPromptField() throws {
        // JSON has options but no prompt — decoder should throw.
        let json = Data("""
        {"system": "hello", "options": {}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LLMGenerateRequest.self, from: json)
        }
    }

    @Test("LLMLoadRequest missing required 'modelPath' field")
    func missingModelPathField() throws {
        let json = Data("""
        {"config": {}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LLMLoadRequest.self, from: json)
        }
    }

    @Test("Malformed JSON data rejects cleanly")
    func malformedJSON() throws {
        let garbage = Data("not json at all".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LLMGenerateRequest.self, from: garbage)
        }
    }

    @Test("Wrong value type for field rejects cleanly")
    func wrongFieldType() throws {
        // maxTokens should be Int, not String.
        let json = Data("""
        {"prompt": "test", "options": {"maxTokens": "not-a-number"}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LLMGenerateRequest.self, from: json)
        }
    }
}
