import Foundation
import Testing

@testable import LocalLLM

// MARK: - Codable Round-Trip Helpers

/// Encode then decode a value, returning the decoded copy.
private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - Existing Type Codable Round-Trips

@Suite("ThinkingMode Codable")
struct ThinkingModeCodableTests {
    @Test("off round-trips")
    func offRoundTrip() throws {
        #expect(try roundTrip(ThinkingMode.off) == .off)
    }

    @Test("auto round-trips")
    func autoRoundTrip() throws {
        #expect(try roundTrip(ThinkingMode.auto) == .auto)
    }
}

@Suite("FinishReason Codable")
struct FinishReasonCodableTests {
    @Test("All cases round-trip")
    func allCases() throws {
        let cases: [FinishReason] = [.endOfTurn, .eos, .maxTokens, .stopSequence]
        for reason in cases {
            #expect(try roundTrip(reason) == reason)
        }
    }
}

@Suite("GenerationOptions Codable")
struct GenerationOptionsCodableTests {
    @Test("Default options round-trip")
    func defaultRoundTrip() throws {
        let opts = GenerationOptions.default
        #expect(try roundTrip(opts) == opts)
    }

    @Test("Fully customized options round-trip")
    func customRoundTrip() throws {
        let opts = GenerationOptions(
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
            thinking: .auto,
            useBuiltinTemplate: true
        )
        #expect(try roundTrip(opts) == opts)
    }

    @Test("Options with nil seed round-trip")
    func nilSeedRoundTrip() throws {
        let opts = GenerationOptions(seed: nil)
        let decoded = try roundTrip(opts)
        #expect(decoded.seed == nil)
    }
}

@Suite("EngineConfig Codable")
struct EngineConfigCodableTests {
    @Test("Default config round-trips")
    func defaultRoundTrip() throws {
        let config = EngineConfig.default
        #expect(try roundTrip(config) == config)
    }

    @Test("Custom config round-trips")
    func customRoundTrip() throws {
        let config = EngineConfig(contextSize: 8192, nGpuLayers: 32, threadCount: 4, seed: 999)
        #expect(try roundTrip(config) == config)
    }

    @Test("Config with nil threadCount round-trips")
    func nilThreadCountRoundTrip() throws {
        let config = EngineConfig(threadCount: nil)
        let decoded = try roundTrip(config)
        #expect(decoded.threadCount == nil)
    }
}

@Suite("GenerationResult Codable")
struct GenerationResultCodableTests {
    @Test("Full result round-trips")
    func fullRoundTrip() throws {
        let result = GenerationResult(
            text: "The answer is 42.",
            reasoning: "Let me think about this...",
            promptTokenCount: 100,
            generatedTokenCount: 50,
            finishReason: .endOfTurn,
            loadDuration: 2.5,
            promptEvalDuration: 0.3,
            generationDuration: 1.5,
            totalDuration: 4.3,
            renderedPrompt: "<prompt>What is the answer?</prompt>",
            rawText: "<think>Let me think</think>The answer is 42.",
            embeddedChatTemplate: "{{ template }}"
        )
        #expect(try roundTrip(result) == result)
    }

    @Test("Result with nil optionals round-trips")
    func nilOptionalsRoundTrip() throws {
        let result = GenerationResult(
            text: "Hello",
            reasoning: nil,
            promptTokenCount: 10,
            generatedTokenCount: 5,
            finishReason: .eos,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 0.2,
            totalDuration: 0.3,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        let decoded = try roundTrip(result)
        #expect(decoded == result)
        #expect(decoded.reasoning == nil)
        #expect(decoded.loadDuration == nil)
        #expect(decoded.embeddedChatTemplate == nil)
    }

    @Test("All finish reasons survive round-trip through GenerationResult")
    func finishReasonsInResult() throws {
        for reason in [FinishReason.endOfTurn, .eos, .maxTokens, .stopSequence] {
            let result = GenerationResult(
                text: "", reasoning: nil, promptTokenCount: 0, generatedTokenCount: 0,
                finishReason: reason, loadDuration: nil, promptEvalDuration: 0,
                generationDuration: 0, totalDuration: 0,
                renderedPrompt: "", rawText: "", embeddedChatTemplate: nil
            )
            #expect(try roundTrip(result).finishReason == reason)
        }
    }
}

// MARK: - ServiceRequest Codable Round-Trips

@Suite("ServiceRequest Codable")
struct ServiceRequestCodableTests {
    @Test("generate round-trips with full options")
    func generateRoundTrip() throws {
        let opts = GenerationOptions(
            maxTokens: 1024, temperature: 0.8, seed: 42,
            stopSequences: ["STOP"], thinking: .auto
        )
        let request = ServiceRequest.generate(
            id: 7, prompt: "Hello", system: "You are helpful.", options: opts, streaming: true
        )
        #expect(try roundTrip(request) == request)
    }

    @Test("generate with nil system round-trips")
    func generateNilSystemRoundTrip() throws {
        let request = ServiceRequest.generate(
            id: 1, prompt: "Hi", system: nil, options: .default, streaming: false
        )
        #expect(try roundTrip(request) == request)
    }

    @Test("cancel round-trips")
    func cancelRoundTrip() throws {
        let request = ServiceRequest.cancel(id: 42)
        #expect(try roundTrip(request) == request)
    }

    @Test("shutdown round-trips")
    func shutdownRoundTrip() throws {
        let request = ServiceRequest.shutdown
        #expect(try roundTrip(request) == request)
    }
}

// MARK: - ServiceEvent Codable Round-Trips

@Suite("ServiceEvent Codable")
struct ServiceEventCodableTests {
    @Test("ready round-trips")
    func readyRoundTrip() throws {
        #expect(try roundTrip(ServiceEvent.ready) == .ready)
    }

    @Test("loadError round-trips")
    func loadErrorRoundTrip() throws {
        let event = ServiceEvent.loadError(.modelLoadFailed("corrupt file"))
        #expect(try roundTrip(event) == event)
    }

    @Test("token round-trips")
    func tokenRoundTrip() throws {
        let event = ServiceEvent.token(id: 3, piece: "Hello")
        #expect(try roundTrip(event) == event)
    }

    @Test("reasoningToken round-trips")
    func reasoningTokenRoundTrip() throws {
        let event = ServiceEvent.reasoningToken(id: 5, piece: "Let me think...")
        #expect(try roundTrip(event) == event)
    }

    @Test("done round-trips with full result")
    func doneRoundTrip() throws {
        let result = GenerationResult(
            text: "42", reasoning: "thinking", promptTokenCount: 10, generatedTokenCount: 5,
            finishReason: .endOfTurn, loadDuration: 1.0, promptEvalDuration: 0.2,
            generationDuration: 0.5, totalDuration: 1.7,
            renderedPrompt: "prompt", rawText: "raw", embeddedChatTemplate: nil
        )
        let event = ServiceEvent.done(id: 1, result: result)
        #expect(try roundTrip(event) == event)
    }

    @Test("requestError round-trips")
    func requestErrorRoundTrip() throws {
        let event = ServiceEvent.requestError(
            id: 2, error: .contextOverflow(promptTokens: 5000, contextSize: 4096)
        )
        #expect(try roundTrip(event) == event)
    }

    @Test("fatal round-trips")
    func fatalRoundTrip() throws {
        let event = ServiceEvent.fatal(.service("out of memory"))
        #expect(try roundTrip(event) == event)
    }
}

// MARK: - WireError Codable Round-Trips

@Suite("WireError Codable")
struct WireErrorCodableTests {
    @Test("All WireError cases round-trip")
    func allCasesRoundTrip() throws {
        let cases: [WireError] = [
            .modelFileNotFound(path: "/path/to/model.gguf"),
            .modelLoadFailed("bad header"),
            .contextCreationFailed("OOM"),
            .tokenizationFailed("unknown token"),
            .contextOverflow(promptTokens: 5000, contextSize: 4096),
            .generationFailed("Metal error"),
            .decodeFailed(code: -1),
            .cancelled,
            .downloadFailed(url: "https://example.com/model.gguf", underlying: "timeout"),
            .service("generic failure"),
        ]
        for wireError in cases {
            #expect(try roundTrip(wireError) == wireError)
        }
    }
}

// MARK: - WireError Mapping

@Suite("WireError Mapping")
struct WireErrorMappingTests {
    @Test("modelFileNotFound maps both directions")
    func modelFileNotFound() {
        let original = LocalLLMError.modelFileNotFound(URL(fileURLWithPath: "/tmp/model.gguf"))
        let wire = WireError.from(original)
        #expect(wire == .modelFileNotFound(path: "/tmp/model.gguf"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == .modelFileNotFound(URL(fileURLWithPath: "/tmp/model.gguf")))
    }

    @Test("modelLoadFailed maps both directions")
    func modelLoadFailed() {
        let original = LocalLLMError.modelLoadFailed("corrupt")
        let wire = WireError.from(original)
        #expect(wire == .modelLoadFailed("corrupt"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("contextCreationFailed maps both directions")
    func contextCreationFailed() {
        let original = LocalLLMError.contextCreationFailed("OOM")
        let wire = WireError.from(original)
        #expect(wire == .contextCreationFailed("OOM"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("tokenizationFailed maps both directions")
    func tokenizationFailed() {
        let original = LocalLLMError.tokenizationFailed("bad token")
        let wire = WireError.from(original)
        #expect(wire == .tokenizationFailed("bad token"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("contextOverflow maps both directions")
    func contextOverflow() {
        let original = LocalLLMError.contextOverflow(promptTokens: 5000, contextSize: 4096)
        let wire = WireError.from(original)
        #expect(wire == .contextOverflow(promptTokens: 5000, contextSize: 4096))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("generationFailed maps both directions")
    func generationFailed() {
        let original = LocalLLMError.generationFailed("Metal crashed")
        let wire = WireError.from(original)
        #expect(wire == .generationFailed("Metal crashed"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("decodeFailed maps both directions")
    func decodeFailed() {
        let original = LocalLLMError.decodeFailed(code: -42)
        let wire = WireError.from(original)
        #expect(wire == .decodeFailed(code: -42))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == original)
    }

    @Test("cancelled maps to LLMServiceError.cancelled")
    func cancelledMapping() {
        let original = LocalLLMError.cancelled
        let wire = WireError.from(original)
        #expect(wire == .cancelled)
        guard let reconstructed = wire.toClientError() as? LLMServiceError else {
            Issue.record("Expected LLMServiceError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == .cancelled)
    }

    @Test("downloadFailed maps both directions")
    func downloadFailed() {
        let url = URL(string: "https://example.com/model.gguf")!
        let original = LocalLLMError.downloadFailed(url: url, underlying: "timeout")
        let wire = WireError.from(original)
        #expect(wire == .downloadFailed(url: "https://example.com/model.gguf", underlying: "timeout"))
        guard let reconstructed = wire.toClientError() as? LocalLLMError else {
            Issue.record("Expected LocalLLMError, got \(type(of: wire.toClientError()))")
            return
        }
        if case let .downloadFailed(rURL, rUnderlying) = reconstructed {
            #expect(rURL.absoluteString == "https://example.com/model.gguf")
            #expect(rUnderlying == "timeout")
        } else {
            Issue.record("Expected downloadFailed, got \(reconstructed)")
        }
    }

    @Test("service fallback for non-LocalLLMError")
    func serviceFallback() {
        struct CustomError: Error, CustomStringConvertible {
            let description: String
        }
        let original = CustomError(description: "something weird")
        let wire = WireError.from(original)
        if case let .service(msg) = wire {
            #expect(msg.contains("something weird"))
        } else {
            Issue.record("Expected .service, got \(wire)")
        }
        guard let reconstructed = wire.toClientError() as? LLMServiceError else {
            Issue.record("Expected LLMServiceError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(reconstructed == .serviceInterrupted)
    }

    @Test("WireError.service maps to LLMServiceError.serviceInterrupted")
    func serviceToServiceInterrupted() {
        let wire = WireError.service("internal failure")
        guard let error = wire.toClientError() as? LLMServiceError else {
            Issue.record("Expected LLMServiceError, got \(type(of: wire.toClientError()))")
            return
        }
        #expect(error == .serviceInterrupted)
    }
}

// MARK: - LLMServiceError

@Suite("LLMServiceError")
struct LLMServiceErrorTests {
    @Test("All cases have error descriptions")
    func errorDescriptions() {
        let cases: [LLMServiceError] = [
            .serviceUnavailable("not found"),
            .loadFailed(.modelLoadFailed("bad")),
            .serviceInterrupted,
            .connectionClosed,
            .protocolError("bad frame"),
            .cancelled,
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("Equatable works correctly")
    func equatable() {
        #expect(LLMServiceError.serviceInterrupted == LLMServiceError.serviceInterrupted)
        #expect(LLMServiceError.cancelled == LLMServiceError.cancelled)
        #expect(LLMServiceError.connectionClosed != LLMServiceError.cancelled)
        #expect(LLMServiceError.protocolError("a") == LLMServiceError.protocolError("a"))
        #expect(LLMServiceError.protocolError("a") != LLMServiceError.protocolError("b"))
    }
}
