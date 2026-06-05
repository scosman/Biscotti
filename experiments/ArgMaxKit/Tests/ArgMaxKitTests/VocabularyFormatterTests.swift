import Foundation
import Testing
@testable import ArgMaxKit

@Suite("VocabularyFormatter")
struct VocabularyFormatterTests {

    @Test("Empty vocabulary returns nil")
    func emptyVocabularyReturnsNil() {
        #expect(VocabularyFormatter.formatPrompt(from: []) == nil)
    }

    @Test("Whitespace-only terms return nil")
    func whitespaceOnlyReturnsNil() {
        #expect(VocabularyFormatter.formatPrompt(from: ["", "  ", "\t"]) == nil)
    }

    @Test("Single term formats correctly")
    func singleTerm() {
        let result = VocabularyFormatter.formatPrompt(from: ["Acme Corp"])
        #expect(result == "Transcript mentioning: Acme Corp.")
    }

    @Test("Multiple terms joined with commas")
    func multipleTerms() {
        let result = VocabularyFormatter.formatPrompt(from: ["Biscotti", "Acme Corp", "Jordan"])
        #expect(result == "Transcript mentioning: Biscotti, Acme Corp, Jordan.")
    }

    @Test("Whitespace is trimmed from terms")
    func whitespaceIsTrimmed() {
        let result = VocabularyFormatter.formatPrompt(from: ["  Biscotti  ", " Acme "])
        #expect(result == "Transcript mentioning: Biscotti, Acme.")
    }

    @Test("Very long vocabulary list is truncated to fit budget")
    func vocabularyTruncation() {
        // Generate a list of terms that exceeds the character budget
        let longTerms = (0..<500).map { "LongCompanyName\($0)" }
        let result = VocabularyFormatter.formatPrompt(from: longTerms)

        // Result must exist and be within budget
        #expect(result != nil)
        #expect(result!.count <= VocabularyFormatter.maxPromptCharacters)

        // Not all terms should be included
        let includedCount = result!.components(separatedBy: ",").count
        #expect(includedCount < longTerms.count)
        #expect(includedCount > 0)
    }

    @Test("Prompt starts with expected framing")
    func promptFraming() {
        let result = VocabularyFormatter.formatPrompt(from: ["test"])!
        #expect(result.hasPrefix("Transcript mentioning:"))
        #expect(result.hasSuffix("."))
    }

    @Test("Empty strings are filtered out")
    func emptyStringsFiltered() {
        let result = VocabularyFormatter.formatPrompt(from: ["", "Biscotti", "", "App"])
        #expect(result == "Transcript mentioning: Biscotti, App.")
    }

    @Test("Budget limits are respected")
    func budgetLimits() {
        // The max characters minus framing overhead should be the effective budget
        let effectiveBudget = VocabularyFormatter.maxPromptCharacters - VocabularyFormatter.framingOverhead

        // A single very long term that fits in the budget
        let longTerm = String(repeating: "a", count: effectiveBudget - 5)
        let result = VocabularyFormatter.formatPrompt(from: [longTerm])
        #expect(result != nil)

        // A single term that exceeds the budget should still be nil
        // (because even the first term doesn't fit)
        let tooLongTerm = String(repeating: "a", count: effectiveBudget + 100)
        let tooLongResult = VocabularyFormatter.formatPrompt(from: [tooLongTerm])
        #expect(tooLongResult == nil)
    }
}
