import Foundation

/// Errors from prompt preparation (transcript substitution, file reading).
public enum PromptError: Error, LocalizedError, Sendable, Equatable {
    /// The prompt contains a `{{transcript}}` placeholder but no transcript content was provided.
    case placeholderWithoutTranscript
    /// Transcript content was provided but the prompt has no `{{transcript}}` placeholder.
    case transcriptWithoutPlaceholder

    public var errorDescription: String? {
        switch self {
        case .placeholderWithoutTranscript:
            return "Prompt contains {{transcript}} placeholder but no transcript was provided."
        case .transcriptWithoutPlaceholder:
            return "Transcript provided but prompt does not contain a {{transcript}} placeholder."
        }
    }
}

/// Pure helpers for preparing prompts before generation.
public enum PromptUtils {
    /// Substitute `{{transcript}}` in a prompt with the given transcript content.
    ///
    /// Rules:
    /// - If the prompt contains `{{transcript}}` and `transcript` is provided, substitute all occurrences.
    /// - If the prompt contains `{{transcript}}` but `transcript` is nil, throw `.placeholderWithoutTranscript`.
    /// - If `transcript` is non-nil but the prompt has no `{{transcript}}`, throw `.transcriptWithoutPlaceholder`.
    /// - If neither placeholder nor transcript, return the prompt unchanged.
    public static func substituteTranscript(prompt: String, transcript: String?) throws -> String {
        let hasPlaceholder = prompt.contains("{{transcript}}")

        if hasPlaceholder, transcript == nil {
            throw PromptError.placeholderWithoutTranscript
        }
        if !hasPlaceholder, transcript != nil {
            throw PromptError.transcriptWithoutPlaceholder
        }

        guard hasPlaceholder, let transcript else {
            return prompt
        }

        return prompt.replacingOccurrences(of: "{{transcript}}", with: transcript)
    }
}
