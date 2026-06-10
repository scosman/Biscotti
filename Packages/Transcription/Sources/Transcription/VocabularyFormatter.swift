/// Formats a custom vocabulary list into a natural-language prompt string
/// suitable for WhisperKit's `promptTokens` conditioning mechanism.
///
/// The prompt biases Whisper's decoder toward recognizing the listed terms.
/// The Whisper prompt window is ~224 tokens (~100-150 words), so very long
/// lists are truncated to fit within budget.
public enum VocabularyFormatter {
    /// Approximate character budget for the prompt.
    /// Whisper tokenizer averages ~4 chars/token for Latin scripts; 224 tokens * 4 = ~896 chars.
    /// We leave headroom for the framing sentence.
    /// NOTE: This heuristic is English/Latin-oriented. CJK or emoji-heavy vocab
    /// may tokenize to more tokens per character and could exceed the 224-token window.
    static let maxPromptCharacters = 800

    /// Overhead characters for the framing sentence around the terms.
    static let framingOverhead = 60

    /// Formats vocabulary terms into a natural-language prompt, or returns nil
    /// if the list is empty.
    ///
    /// - Parameter terms: Domain-specific words/phrases to boost recognition of.
    /// - Returns: A prompt string, or nil if no terms were provided.
    public static func formatPrompt(from terms: [String]) -> String? {
        // Lowercase defensively: WhisperKit's promptTokens can silently blank
        // the entire transcript for uppercase terms (research/argmax/README.md Gotcha #16).
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return nil }

        let budget = maxPromptCharacters - framingOverhead
        var includedTerms: [String] = []
        var usedCharacters = 0

        for term in cleaned {
            let addition = term.count + 2 // account for ", " separator
            if usedCharacters + addition > budget {
                break
            }
            includedTerms.append(term)
            usedCharacters += addition
        }

        guard !includedTerms.isEmpty else { return nil }

        let termList = includedTerms.joined(separator: ", ")
        return "Transcript mentioning: \(termList)."
    }
}
