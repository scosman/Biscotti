import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

// MARK: - Stub transport

/// A configurable stub transport for testing OpenRouterClient without network.
struct StubTransport: HTTPTransport {
    var handler: @Sendable (URL, [String: String], Data, TimeInterval) async throws
        -> (status: Int, headers: [String: String], body: Data)

    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        try await handler(url, headers, body, timeout)
    }
}

/// An actor that captures headers from HTTP requests for assertion.
actor HeaderCapture {
    var headers: [String: String] = [:]
    func set(_ h: [String: String]) { headers = h }
}

// MARK: - Request builder tests

@Suite("OpenRouterClient request builder")
struct RequestBuilderTests {
    @Test("Request body has expected fields")
    func requestBodyFields() throws {
        let wavData = Data([0x01, 0x02, 0x03])
        let request = TranscriptionRequest(
            model: "test-model",
            wavData: wavData,
            language: "en",
            zdr: true
        )

        let body = try request.jsonBody()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]

        #expect(json["model"] as? String == "test-model")
        #expect(json["response_format"] as? String == "verbose_json")
        #expect(json["language"] as? String == "en")
        #expect(json["timestamp_granularities"] as? [String] == ["word", "segment"])

        let audio = json["input_audio"] as? [String: Any]
        #expect(audio?["format"] as? String == "wav")
        #expect(audio?["data"] as? String == wavData.base64EncodedString())

        let provider = json["provider"] as? [String: Any]
        #expect(provider?["zdr"] as? Bool == true)
    }

    @Test("ZDR flag omitted when disabled")
    func zdrOmittedWhenFalse() throws {
        let request = TranscriptionRequest(
            model: "test-model",
            wavData: Data([0x01]),
            zdr: false
        )

        let body = try request.jsonBody()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]

        #expect(json["provider"] == nil, "provider key should be absent when zdr is false")
    }

    @Test("Language omitted when nil")
    func languageOmittedWhenNil() throws {
        let request = TranscriptionRequest(
            model: "test-model",
            wavData: Data([0x01]),
            language: nil,
            zdr: true
        )

        let body = try request.jsonBody()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]

        #expect(json["language"] == nil, "language key should be absent when nil")
    }

    @Test("Metadata does not contain API key")
    func noKeyInMetadata() {
        let apiKey = "sk-test-secret-key-12345"
        let request = TranscriptionRequest(
            model: "test-model",
            wavData: Data(repeating: 0, count: 1000),
            language: "en",
            zdr: true
        )

        let meta = request.metadata()

        // The metadata should not contain the key anywhere.
        for (_, v) in meta {
            #expect(!v.contains(apiKey))
        }
        for (k, _) in meta {
            #expect(!k.contains(apiKey))
        }

        // Metadata should have expected fields.
        #expect(meta["model"] == "test-model")
        #expect(meta["zdr"] == "true")
        #expect(meta["wavDataSize"] == "1000")
    }
}

// MARK: - Response parsing tests

@Suite("ReferenceResponse parsing")
struct ResponseParsingTests {
    @Test("Parses response with words and segments")
    func parsesWithWords() throws {
        let json = """
        {
            "text": "Hello world",
            "language": "en",
            "duration": 5.0,
            "segments": [
                {"start": 0.0, "end": 5.0, "text": "Hello world"}
            ],
            "words": [
                {"word": "Hello", "start": 0.0, "end": 0.5, "confidence": 0.95},
                {"word": "world", "start": 0.6, "end": 1.0}
            ],
            "usage": {"seconds": 5.0, "cost": 0.001},
            "model": "test-model",
            "provider": "test-provider"
        }
        """

        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(ReferenceResponse.self, from: data)

        #expect(response.text == "Hello world")
        #expect(response.language == "en")
        #expect(response.duration == 5.0)
        #expect(response.segments?.count == 1)
        #expect(response.words?.count == 2)
        #expect(response.words?[0].word == "Hello")
        #expect(response.words?[0].confidence == 0.95)
        #expect(response.words?[1].confidence == nil)
        #expect(response.usage?.seconds == 5.0)
        #expect(response.usage?.cost == 0.001)
        #expect(response.model == "test-model")
        #expect(response.provider == "test-provider")
    }

    @Test("Parses response with no words field")
    func parsesNoWords() throws {
        let json = """
        {
            "text": "Just text"
        }
        """

        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(ReferenceResponse.self, from: data)

        #expect(response.text == "Just text")
        #expect(response.words == nil)
        #expect(response.segments == nil)
        #expect(response.usage == nil)
        #expect(response.model == nil)
    }

    @Test("Parses completely empty response")
    func parsesEmptyResponse() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(ReferenceResponse.self, from: data)

        #expect(response.text == nil)
        #expect(response.words == nil)
    }
}

// MARK: - Client outcome classification

@Suite("OpenRouterClient outcome classification")
struct OutcomeClassificationTests {
    @Test("200 response classified as success")
    func successOutcome() async {
        let transport = StubTransport { _, _, _, _ in
            (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))
        let outcome = await client.transcribe(request)

        if case .success(let status, _, _) = outcome {
            #expect(status == 200)
        } else {
            Issue.record("Expected .success, got \(outcome)")
        }
    }

    @Test("429 classified as retryable")
    func retryableOutcome() async {
        let transport = StubTransport { _, _, _, _ in
            (429, [:], Data("rate limited".utf8))
        }
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))
        let outcome = await client.transcribe(request)

        if case .retryable(let status, _, _) = outcome {
            #expect(status == 429)
        } else {
            Issue.record("Expected .retryable, got \(outcome)")
        }
    }

    @Test("502 classified as timeoutLike")
    func timeoutLikeOutcome() async {
        let transport = StubTransport { _, _, _, _ in
            (502, [:], Data("bad gateway".utf8))
        }
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))
        let outcome = await client.transcribe(request)

        if case .timeoutLike(let status, _) = outcome {
            #expect(status == 502)
        } else {
            Issue.record("Expected .timeoutLike, got \(outcome)")
        }
    }

    @Test("400 classified as fatal")
    func fatalOutcome() async {
        let transport = StubTransport { _, _, _, _ in
            (400, [:], Data("bad request".utf8))
        }
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))
        let outcome = await client.transcribe(request)

        if case .fatal(let status, _) = outcome {
            #expect(status == 400)
        } else {
            Issue.record("Expected .fatal, got \(outcome)")
        }
    }

    @Test("Headers include Authorization and Content-Type")
    func headersPresent() async {
        let capture = HeaderCapture()
        let transport = StubTransport { _, headers, _, _ in
            await capture.set(headers)
            return (200, [:], Data("{}".utf8))
        }
        let client = OpenRouterClient(apiKey: "test-key-123", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))
        _ = await client.transcribe(request)

        let capturedHeaders = await capture.headers
        #expect(capturedHeaders["Authorization"] == "Bearer test-key-123")
        #expect(capturedHeaders["Content-Type"] == "application/json")
        #expect(capturedHeaders["HTTP-Referer"] == "https://github.com/scosman/biscotti")
        #expect(capturedHeaders["X-Title"] == "Biscotti STT experiment")
    }
}
