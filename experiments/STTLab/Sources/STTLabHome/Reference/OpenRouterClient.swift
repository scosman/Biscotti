import Foundation
import STTLabCore

// MARK: - Transport protocol

/// Abstraction for HTTP POST requests, allowing test stubs.
public protocol HTTPTransport: Sendable {
    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, headers: [String: String], body: Data)
}

/// Default transport using URLSession.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                responseHeaders[k] = v
            }
        }
        return (httpResponse.statusCode, responseHeaders, data)
    }
}

// MARK: - Request

/// A transcription request for the OpenRouter audio API.
public struct TranscriptionRequest: Sendable {
    public var model: String
    public var wavData: Data
    public var language: String?
    public var zdr: Bool

    public init(model: String, wavData: Data, language: String? = nil, zdr: Bool = true) {
        self.model = model
        self.wavData = wavData
        self.language = language
        self.zdr = zdr
    }

    /// Build the JSON body for the OpenRouter API. The audio is base64-encoded inline.
    public func jsonBody() throws -> Data {
        var dict: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": wavData.base64EncodedString(),
                "format": "wav"
            ],
            "response_format": "verbose_json",
            "timestamp_granularities": ["word", "segment"]
        ]
        if let language {
            dict["language"] = language
        }
        if zdr {
            dict["provider"] = ["zdr": true]
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// Request metadata for saving (excludes audio data and headers with secrets).
    public func metadata() -> [String: String] {
        var meta: [String: String] = [
            "model": model,
            "response_format": "verbose_json",
            "timestamp_granularities": "word,segment",
            "zdr": String(zdr)
        ]
        if let language {
            meta["language"] = language
        }
        meta["wavDataSize"] = String(wavData.count)
        return meta
    }
}

// MARK: - Outcome

/// The result of a single transcription attempt, classified for retry logic.
public enum AttemptOutcome: Sendable {
    /// The server returned a 2xx response.
    case success(status: Int, headers: [String: String], body: Data)
    /// A retryable error (network, 429, 5xx except timeout-like).
    case retryable(status: Int?, headers: [String: String], message: String)
    /// A timeout-like error that may benefit from chunk splitting.
    case timeoutLike(status: Int?, message: String)
    /// A non-retryable error (4xx other than 429, 408, 413).
    case fatal(status: Int, body: Data)
}

// MARK: - Client

/// Sends audio transcription requests to the OpenRouter API.
public struct OpenRouterClient: Sendable {
    private let apiKey: String
    private let transport: any HTTPTransport
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!,
        timeout: TimeInterval = 180
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// Send a single transcription request and classify the outcome.
    public func transcribe(_ request: TranscriptionRequest) async -> AttemptOutcome {
        let body: Data
        do {
            body = try request.jsonBody()
        } catch {
            return .fatal(status: 0, body: Data("JSON encoding failed: \(error)".utf8))
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/scosman/biscotti",
            "X-Title": "Biscotti STT experiment"
        ]

        do {
            let (status, respHeaders, respBody) = try await transport.post(
                url: endpoint,
                headers: headers,
                body: body,
                timeout: timeout
            )

            if (200 ..< 300).contains(status) {
                return .success(status: status, headers: respHeaders, body: respBody)
            }

            // Timeout-like: 408, 502, 504, 413 (split-worthy).
            if [408, 502, 504, 413].contains(status) {
                return .timeoutLike(status: status, message: "HTTP \(status)")
            }

            // Retryable: 429, other 5xx.
            if status == 429 || (500 ..< 600).contains(status) {
                return .retryable(status: status, headers: respHeaders, message: "HTTP \(status)")
            }

            // All other 4xx: fatal.
            return .fatal(status: status, body: respBody)

        } catch {
            let nsError = error as NSError
            // URLError.timedOut
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                return .timeoutLike(status: nil, message: "URLError.timedOut")
            }
            // Other network errors are retryable.
            return .retryable(status: nil, headers: [:], message: error.localizedDescription)
        }
    }
}
