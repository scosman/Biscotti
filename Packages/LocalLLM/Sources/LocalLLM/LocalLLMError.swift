import Foundation

/// Typed errors for LocalLLM operations.
///
/// No leaked llama.cpp/C types -- all underlying details are wrapped as strings.
public enum LocalLLMError: Error, LocalizedError, Sendable, Equatable {
    /// The specified model file does not exist or is not readable.
    case modelFileNotFound(URL)

    /// Model download failed.
    case downloadFailed(url: URL, underlying: String)

    /// The llama.cpp model load returned null.
    case modelLoadFailed(String)

    /// The llama.cpp context creation returned null.
    case contextCreationFailed(String)

    /// Tokenization of the prompt failed.
    case tokenizationFailed(String)

    /// The tokenized prompt exceeds the context window.
    case contextOverflow(promptTokens: Int, contextSize: Int)

    /// An unrecoverable error during the generation loop.
    case generationFailed(String)

    /// `llama_decode` returned a non-zero error code.
    case decodeFailed(code: Int32)

    /// Generation was cancelled via cooperative Task cancellation.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .modelFileNotFound(url):
            "Model file not found at \(url.path)"
        case let .downloadFailed(url, underlying):
            "Download failed for \(url.absoluteString): \(underlying)"
        case let .modelLoadFailed(detail):
            "Failed to load model: \(detail)"
        case let .contextCreationFailed(detail):
            "Failed to create context: \(detail)"
        case let .tokenizationFailed(detail):
            "Tokenization failed: \(detail)"
        case let .contextOverflow(promptTokens, contextSize):
            "Prompt (\(promptTokens) tokens) exceeds context window (\(contextSize) tokens)"
        case let .generationFailed(detail):
            "Generation failed: \(detail)"
        case let .decodeFailed(code):
            "Decode failed with error code \(code)"
        case .cancelled:
            "Generation was cancelled"
        }
    }
}
