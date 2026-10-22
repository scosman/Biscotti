import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

// MARK: - Helpers

/// A transport that returns a sequence of outcomes, cycling through them.
/// Uses an actor for async-safe state.
actor SequenceTransport: HTTPTransport {
    private var responses: [(Int, [String: String], Data)]
    private var callCount = 0

    init(responses: [(Int, [String: String], Data)]) {
        self.responses = responses
    }

    nonisolated func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        await nextResponse()
    }

    private func nextResponse() -> (status: Int, headers: [String: String], body: Data) {
        let idx = min(callCount, responses.count - 1)
        callCount += 1
        return responses[idx]
    }

    var totalCalls: Int { callCount }
}

/// A transport that can return errors or successes.
actor ErrorTransport: HTTPTransport {
    private var responses: [Result<(Int, [String: String], Data), Error>]
    private var callCount = 0

    init(responses: [Result<(Int, [String: String], Data), Error>]) {
        self.responses = responses
    }

    nonisolated func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        try await nextResponse()
    }

    private func nextResponse() throws -> (status: Int, headers: [String: String], body: Data) {
        let idx = min(callCount, responses.count - 1)
        callCount += 1
        switch responses[idx] {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    var totalCalls: Int { callCount }
}

// MARK: - Tests

@Suite("Retry policy via OpenRouterClient")
struct RetryPolicyTests {
    @Test("429 is retryable")
    func retryOn429() async {
        // Return 429 twice, then 200.
        let transport = SequenceTransport(responses: [
            (429, [:], Data("rate limited".utf8)),
            (429, [:], Data("rate limited".utf8)),
            (200, [:], Data("{\"text\":\"ok\"}".utf8))
        ])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        // The client itself does not retry -- it classifies the outcome.
        let outcome1 = await client.transcribe(request)
        if case .retryable(let status, _, _) = outcome1 {
            #expect(status == 429)
        } else {
            Issue.record("Expected .retryable for 429")
        }

        // After the caller retries, the third call returns success.
        _ = await client.transcribe(request) // second 429
        let outcome3 = await client.transcribe(request) // 200
        if case .success(let status, _, _) = outcome3 {
            #expect(status == 200)
        } else {
            Issue.record("Expected .success on third attempt")
        }

        let calls = await transport.totalCalls
        #expect(calls == 3)
    }

    @Test("400 is fatal (no retry)")
    func fatalOn400() async {
        let transport = SequenceTransport(responses: [
            (400, [:], Data("bad request".utf8))
        ])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .fatal(let status, _) = outcome {
            #expect(status == 400)
        } else {
            Issue.record("Expected .fatal for 400")
        }

        let calls = await transport.totalCalls
        #expect(calls == 1)
    }

    @Test("URLError.timedOut classified as timeoutLike")
    func timeoutClassification() async {
        let error = URLError(.timedOut)
        let transport = ErrorTransport(responses: [.failure(error)])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .timeoutLike(let status, let msg) = outcome {
            #expect(status == nil)
            #expect(msg.contains("timedOut"))
        } else {
            Issue.record("Expected .timeoutLike for URLError.timedOut")
        }
    }

    @Test("413 classified as timeoutLike (split-worthy)")
    func payloadTooLargeIsSplitWorthy() async {
        let transport = SequenceTransport(responses: [
            (413, [:], Data("payload too large".utf8))
        ])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .timeoutLike(let status, _) = outcome {
            #expect(status == 413)
        } else {
            Issue.record("Expected .timeoutLike for 413")
        }
    }

    @Test("Network error classified as retryable")
    func networkErrorRetryable() async {
        let error = URLError(.notConnectedToInternet)
        let transport = ErrorTransport(responses: [.failure(error)])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .retryable(let status, _, _) = outcome {
            #expect(status == nil)
        } else {
            Issue.record("Expected .retryable for network error")
        }
    }

    @Test("429 response headers forwarded in retryable outcome")
    func retryAfterHeaderForwarded() async {
        let transport = SequenceTransport(responses: [
            (429, ["Retry-After": "30"], Data("rate limited".utf8))
        ])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .retryable(_, let headers, _) = outcome {
            #expect(headers["Retry-After"] == "30")
        } else {
            Issue.record("Expected .retryable with headers")
        }
    }

    @Test("Network error retryable has empty headers")
    func networkErrorEmptyHeaders() async {
        let error = URLError(.notConnectedToInternet)
        let transport = ErrorTransport(responses: [.failure(error)])
        let client = OpenRouterClient(apiKey: "test", transport: transport)
        let request = TranscriptionRequest(model: "m", wavData: Data([0x01]))

        let outcome = await client.transcribe(request)
        if case .retryable(_, let headers, _) = outcome {
            #expect(headers.isEmpty)
        } else {
            Issue.record("Expected .retryable with empty headers")
        }
    }
}

// MARK: - Chunk file prefix tests

@Suite("Chunk file prefix uniqueness")
struct ChunkFilePrefixTests {
    @Test("Plan chunk and sub-chunk produce different prefixes")
    func planVsSubChunk() {
        // Plan chunk covers full range 0..<4800000
        let planPrefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 4_800_000)
        // Sub-chunk from split covers first half 0..<2400000
        let subPrefix = ReferenceRunner.chunkFilePrefix(start: 0, end: 2_400_000)

        #expect(planPrefix != subPrefix)
    }

    @Test("Adjacent sub-chunks produce different prefixes")
    func adjacentSubChunks() {
        let sub1 = ReferenceRunner.chunkFilePrefix(start: 0, end: 2_400_000)
        let sub2 = ReferenceRunner.chunkFilePrefix(start: 2_400_000, end: 4_800_000)

        #expect(sub1 != sub2)
    }

    @Test("Prefix format is deterministic and contains sample range")
    func prefixFormat() {
        let prefix = ReferenceRunner.chunkFilePrefix(start: 16000, end: 4_800_000)
        #expect(prefix.contains("16000"))
        #expect(prefix.contains("4800000"))
        #expect(prefix == "chunk_s16000_e4800000")
    }
}
