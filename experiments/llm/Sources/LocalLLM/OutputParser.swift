import Foundation

/// Pure string operations for cleaning model output.
///
/// Handles stop-token stripping and thinking-channel extraction. All operations are
/// string-in/string-out and testable without a model.
public struct OutputParser: Sendable {
    // Gemma 4 thinking channel markers.
    // Table-driven so updating for a different model is a one-line change.
    static let thinkingOpenTag = "<|channel>thought\n"
    static let thinkingCloseTag = "<channel|>"

    // Turn/stop tokens to strip from the end of output.
    static let turnTokens = ["<end_of_turn>", "<eos>"]

    /// Parse raw model output, returning cleaned text and optional reasoning.
    ///
    /// - Parameters:
    ///   - rawText: The raw decoded text from the model.
    ///   - stopSequences: Additional caller-provided stop sequences.
    ///   - stripThinking: Whether to remove the thinking channel (ThinkingMode.off).
    /// - Returns: A tuple of (cleanText, reasoning, matchedStopSequence).
    public static func parse(
        rawText: String,
        stopSequences: [String] = [],
        stripThinking: Bool = true
    ) -> (text: String, reasoning: String?, matchedStopSequence: Bool) {
        var text = rawText
        var reasoning: String?
        var matchedStop = false

        // Extract thinking channel
        let thinkingResult = extractThinkingChannel(from: text)
        if thinkingResult.found {
            text = thinkingResult.text
            if let thought = thinkingResult.reasoning {
                reasoning = stripThinking ? nil : thought
            }
        }

        // Strip turn tokens from the end
        text = stripTrailingTurnTokens(text)

        // Check and strip custom stop sequences
        for seq in stopSequences {
            if text.hasSuffix(seq) {
                text = String(text.dropLast(seq.count))
                matchedStop = true
                break
            }
        }

        // Final trim
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return (text: text, reasoning: reasoning, matchedStopSequence: matchedStop)
    }

    /// Extract a `<|channel>thought\n...<channel|>` block from the text.
    ///
    /// Returns the text with the block removed and the thought content (if found).
    /// Indicates whether a thinking-channel block was found and removed from the text,
    /// even if the thought content was empty.
    public struct ThinkingResult {
        /// The text with the thinking block removed (if found).
        public let text: String
        /// The thought content (nil if no block was found or if block was empty).
        public let reasoning: String?
        /// True if a thinking block was found and removed.
        public let found: Bool
    }

    public static func extractThinkingChannel(
        from text: String
    ) -> ThinkingResult {
        guard let openRange = text.range(of: thinkingOpenTag, options: .literal) else {
            return ThinkingResult(text: text, reasoning: nil, found: false)
        }

        let afterOpen = openRange.upperBound
        if let closeRange = text.range(of: thinkingCloseTag, options: .literal, range: afterOpen ..< text.endIndex) {
            let thought = String(text[afterOpen ..< closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var cleaned = text
            cleaned.removeSubrange(openRange.lowerBound ..< closeRange.upperBound)
            let reasoning = thought.isEmpty ? nil : thought
            return ThinkingResult(text: cleaned, reasoning: reasoning, found: true)
        }

        // Open tag found but no close -- treat entire remainder as thought
        let thought = String(text[afterOpen...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(text[..<openRange.lowerBound])
        let reasoning = thought.isEmpty ? nil : thought
        return ThinkingResult(text: cleaned, reasoning: reasoning, found: true)
    }

    /// Remove trailing turn/stop tokens from text.
    public static func stripTrailingTurnTokens(_ text: String) -> String {
        var result = text
        // Iteratively strip -- a token might appear multiple times or after whitespace
        var changed = true
        while changed {
            changed = false
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            for token in turnTokens {
                if trimmed.hasSuffix(token) {
                    result = String(trimmed.dropLast(token.count))
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// Check if the rolling output buffer ends with any stop sequence.
    /// Returns the matched sequence or nil.
    public static func matchesStopSequence(
        _ buffer: String,
        stopSequences: [String]
    ) -> String? {
        for seq in stopSequences where buffer.hasSuffix(seq) {
            return seq
        }
        return nil
    }
}
