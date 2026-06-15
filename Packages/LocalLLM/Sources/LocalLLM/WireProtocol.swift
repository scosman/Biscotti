import Foundation

// MARK: - LLM Error Payload (Codable error payload for XPC boundary)

/// Codable mirror of the error space, transported across the process boundary.
///
/// Maps 1:1 to/from `LocalLLMError` cases. The `.service` case is a catch-all
/// for errors that don't map to a specific `LocalLLMError`. Used by the NSXPC
/// service to encode errors as `Data` for `@objc`-compatible transport.
public enum LLMErrorPayload: Codable, Sendable, Equatable {
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

    /// Convert any error to an `LLMErrorPayload` for transport.
    ///
    /// `LocalLLMError` cases are mapped 1:1. All other errors fall back to `.service`.
    public static func from(_ error: any Error) -> LLMErrorPayload {
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
    /// `LLMServiceError.cancelled`. `.service` maps to
    /// `LLMServiceError.serviceInterrupted`.
    public func toClientError() -> any Error {
        switch self {
        case let .modelFileNotFound(path):
            LocalLLMError.modelFileNotFound(URL(fileURLWithPath: path))
        case let .modelLoadFailed(detail):
            LocalLLMError.modelLoadFailed(detail)
        case let .contextCreationFailed(detail):
            LocalLLMError.contextCreationFailed(detail)
        case let .tokenizationFailed(detail):
            LocalLLMError.tokenizationFailed(detail)
        case let .contextOverflow(promptTokens, contextSize):
            LocalLLMError.contextOverflow(
                promptTokens: promptTokens, contextSize: contextSize
            )
        case let .generationFailed(detail):
            LocalLLMError.generationFailed(detail)
        case let .decodeFailed(code):
            LocalLLMError.decodeFailed(code: code)
        case .cancelled:
            LLMServiceError.cancelled
        case let .downloadFailed(url, underlying):
            LocalLLMError.downloadFailed(
                url: URL(string: url) ?? URL(fileURLWithPath: url),
                underlying: underlying
            )
        case .service:
            LLMServiceError.serviceInterrupted
        }
    }
}

// MARK: - LLM Service Error

/// Transport and lifecycle errors for the service interface.
///
/// Generation-level failures reuse `LocalLLMError`; this enum covers the
/// service layer itself.
public enum LLMServiceError: Error, LocalizedError, Sendable, Equatable {
    /// Service unavailable (failed to connect or spawn).
    case serviceUnavailable(String)

    /// Model load failed in the service (surfaced at open).
    case loadFailed(LocalLLMError)

    /// Service crashed or exited unexpectedly -- retriable with a new connection.
    case serviceInterrupted

    /// Operation attempted on a closed or failed connection.
    case connectionClosed

    /// Protocol-level decode error or unexpected message.
    case protocolError(String)

    /// Request was cancelled via Task cancellation.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .serviceUnavailable(reason):
            "LLM service unavailable: \(reason)"
        case let .loadFailed(error):
            "LLM service load failed: \(error.localizedDescription)"
        case .serviceInterrupted:
            "LLM service interrupted (crashed or exited unexpectedly)"
        case .connectionClosed:
            "LLM connection is closed"
        case let .protocolError(detail):
            "LLM protocol error: \(detail)"
        case .cancelled:
            "LLM request was cancelled"
        }
    }
}
