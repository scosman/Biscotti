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
            messages: [.system("You are helpful."), .user("Hello world")],
            applyChatTemplate: true,
            thinking: .off
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0] == .system("You are helpful."))
        #expect(decoded.messages[1] == .user("Hello world"))
        #expect(decoded.applyChatTemplate == true)
        #expect(decoded.thinking == .off)
    }

    @Test("Request with user-only message round-trips")
    func userOnlyRoundTrip() throws {
        let request = LLMCountTokensRequest(
            messages: [.user("Test prompt")]
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.messages.count == 1)
    }

    @Test("Request with thinking auto round-trips")
    func thinkingAutoRoundTrip() throws {
        let request = LLMCountTokensRequest(
            messages: [.system("Think carefully."), .user("Analyze this.")],
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
            messages: [.user("Raw prompt text")],
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
            messages: [.user("Summarize this meeting.")],
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0] == .user("Summarize this meeting."))
        #expect(decoded.options == .default)
    }

    @Test("Request with system message round-trips")
    func withSystemRoundTrip() throws {
        let request = LLMGenerateRequest(
            messages: [
                .system("You are a meeting assistant."),
                .user("What are the action items?")
            ],
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.messages[0] == .system("You are a meeting assistant."))
    }

    @Test("Multi-turn request round-trips")
    func multiTurnRoundTrip() throws {
        let request = LLMGenerateRequest(
            messages: [
                .system("Analyst"),
                .user("Identify speakers"),
                .assistant("Speaker 0 is Alice"),
                .user("Now summarize")
            ],
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.messages.count == 4)
        #expect(decoded.messages[2] == .assistant("Speaker 0 is Alice"))
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
            messages: [.user("Test prompt")],
            options: options
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.options.maxTokens == 512)
        #expect(decoded.options.thinking == .auto)
        #expect(decoded.options.stopSequences == ["###", "END"])
    }

    @Test("Request with empty messages round-trips")
    func emptyMessagesRoundTrip() throws {
        let request = LLMGenerateRequest(
            messages: [],
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded.messages.isEmpty)
    }

    @Test("Request with Unicode content round-trips")
    func unicodeRoundTrip() throws {
        let request = LLMGenerateRequest(
            messages: [
                .system("Du bist ein Assistent."),
                .user("Zusammenfassung bitte. \u{1F4DD}")
            ],
            options: .default
        )
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }
}

// MARK: - LLMMessage Codable

@Suite("LLMMessage Codable")
struct LLMMessageCodableTests {
    @Test("System message round-trips")
    func systemRoundTrip() throws {
        let msg = LLMMessage.system("You are helpful.")
        let decoded = try roundTrip(msg)
        #expect(decoded == msg)
        #expect(decoded.role == .system)
        #expect(decoded.content == "You are helpful.")
    }

    @Test("User message round-trips")
    func userRoundTrip() throws {
        let msg = LLMMessage.user("Hello world")
        let decoded = try roundTrip(msg)
        #expect(decoded == msg)
        #expect(decoded.role == .user)
    }

    @Test("Assistant message round-trips")
    func assistantRoundTrip() throws {
        let msg = LLMMessage.assistant("The answer is 42.")
        let decoded = try roundTrip(msg)
        #expect(decoded == msg)
        #expect(decoded.role == .assistant)
    }

    @Test("Message list round-trips")
    func messageListRoundTrip() throws {
        let messages: [LLMMessage] = [
            .system("System"),
            .user("User turn 1"),
            .assistant("Response 1"),
            .user("User turn 2")
        ]
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([LLMMessage].self, from: data)
        #expect(decoded == messages)
    }
}

// MARK: - Negative / Boundary Decode Tests

@Suite("DTO decode failures")
struct DTODecodeFailureTests {
    @Test("LLMGenerateRequest missing required 'messages' field")
    func missingMessagesField() throws {
        let json = Data("""
        {"options": {}}
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
        {"messages": [], "options": {"maxTokens": "not-a-number"}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LLMGenerateRequest.self, from: json)
        }
    }
}
