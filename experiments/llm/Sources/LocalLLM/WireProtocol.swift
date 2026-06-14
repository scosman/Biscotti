import Foundation

// MARK: - Service Request (client -> service)

/// Messages sent from the client to the service process over the request pipe.
public enum ServiceRequest: Codable, Sendable, Equatable {
    /// Start a generation. `streaming` controls whether the service emits
    /// per-token events or a single buffered result.
    case generate(id: UInt64, prompt: String, system: String?, options: GenerationOptions, streaming: Bool)

    /// Cancel an in-flight generation.
    case cancel(id: UInt64)

    /// Orderly shutdown -- service should finish cleanup and exit.
    case shutdown
}

// MARK: - Service Event (service -> client)

/// Messages sent from the service process to the client over the response pipe.
public enum ServiceEvent: Codable, Sendable, Equatable {
    /// Model loaded successfully; service is accepting requests.
    case ready

    /// Model load failed; service will exit after sending this.
    case loadError(WireError)

    /// A content token piece during streaming generation.
    case token(id: UInt64, piece: String)

    /// A reasoning/thinking token piece during streaming generation.
    case reasoningToken(id: UInt64, piece: String)

    /// Generation completed with the full result.
    case done(id: UInt64, result: GenerationResult)

    /// A per-request error; the connection remains healthy for subsequent requests.
    case requestError(id: UInt64, error: WireError)

    /// An unrecoverable service-level failure; the connection should be considered failed.
    case fatal(WireError)
}

// MARK: - Wire Error

/// Codable mirror of the error space, transported across the process boundary.
///
/// Maps 1:1 to/from `LocalLLMError` cases. The `.service` case is a catch-all
/// for errors that don't map to a specific `LocalLLMError`.
public enum WireError: Codable, Sendable, Equatable {
    case modelFileNotFound(path: String)
    case modelLoadFailed(String)
    case contextCreationFailed(String)
    case tokenizationFailed(String)
    case contextOverflow(promptTokens: Int, contextSize: Int)
    case generationFailed(String)
    case decodeFailed(code: Int32)
    case cancelled
    case downloadFailed(url: String, underlying: String)
    /// Catch-all for errors without a specific LocalLLMError mapping.
    case service(String)

    /// Convert any error to a `WireError` for transport.
    ///
    /// `LocalLLMError` cases are mapped 1:1. All other errors fall back to `.service`.
    public static func from(_ error: any Error) -> WireError {
        if let llmError = error as? LocalLLMError {
            switch llmError {
            case let .modelFileNotFound(url):
                return .modelFileNotFound(path: url.path)
            case let .modelLoadFailed(detail):
                return .modelLoadFailed(detail)
            case let .contextCreationFailed(detail):
                return .contextCreationFailed(detail)
            case let .tokenizationFailed(detail):
                return .tokenizationFailed(detail)
            case let .contextOverflow(promptTokens, contextSize):
                return .contextOverflow(promptTokens: promptTokens, contextSize: contextSize)
            case let .generationFailed(detail):
                return .generationFailed(detail)
            case let .decodeFailed(code):
                return .decodeFailed(code: code)
            case .cancelled:
                return .cancelled
            case let .downloadFailed(url, underlying):
                return .downloadFailed(url: url.absoluteString, underlying: underlying)
            }
        }
        return .service(String(describing: error))
    }

    /// Reconstruct the client-side error from a wire error.
    ///
    /// `LocalLLMError` cases are reconstructed faithfully. `.cancelled` maps to
    /// `LLMServiceError.cancelled`. `.service` (a generic server-side failure that
    /// was properly encoded/transmitted) maps to `LLMServiceError.serviceInterrupted`
    /// -- the service hit an unexpected error, and the caller should treat the
    /// connection as failed and open a fresh one if needed.
    public func toClientError() -> any Error {
        switch self {
        case let .modelFileNotFound(path):
            return LocalLLMError.modelFileNotFound(URL(fileURLWithPath: path))
        case let .modelLoadFailed(detail):
            return LocalLLMError.modelLoadFailed(detail)
        case let .contextCreationFailed(detail):
            return LocalLLMError.contextCreationFailed(detail)
        case let .tokenizationFailed(detail):
            return LocalLLMError.tokenizationFailed(detail)
        case let .contextOverflow(promptTokens, contextSize):
            return LocalLLMError.contextOverflow(promptTokens: promptTokens, contextSize: contextSize)
        case let .generationFailed(detail):
            return LocalLLMError.generationFailed(detail)
        case let .decodeFailed(code):
            return LocalLLMError.decodeFailed(code: code)
        case .cancelled:
            return LLMServiceError.cancelled
        case let .downloadFailed(url, underlying):
            return LocalLLMError.downloadFailed(
                url: URL(string: url) ?? URL(fileURLWithPath: url),
                underlying: underlying
            )
        case .service:
            return LLMServiceError.serviceInterrupted
        }
    }
}

// MARK: - LLM Service Error

/// Transport and lifecycle errors for the service interface.
///
/// Generation-level failures reuse `LocalLLMError`; this enum covers the
/// service layer itself.
public enum LLMServiceError: Error, LocalizedError, Sendable, Equatable {
    /// Service binary not found or failed to spawn.
    case serviceUnavailable(String)

    /// Model load failed in the service process (surfaced at open).
    case loadFailed(LocalLLMError)

    /// Service process crashed or exited unexpectedly -- retriable with a new connection.
    case serviceInterrupted

    /// Operation attempted on a closed or failed connection.
    case connectionClosed

    /// Wire protocol decode error or unexpected message.
    case protocolError(String)

    /// Request was cancelled via Task cancellation.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .serviceUnavailable(reason):
            return "LLM service unavailable: \(reason)"
        case let .loadFailed(error):
            return "LLM service load failed: \(error.localizedDescription)"
        case .serviceInterrupted:
            return "LLM service interrupted (process crashed or exited unexpectedly)"
        case .connectionClosed:
            return "LLM connection is closed"
        case let .protocolError(detail):
            return "LLM protocol error: \(detail)"
        case .cancelled:
            return "LLM request was cancelled"
        }
    }
}
