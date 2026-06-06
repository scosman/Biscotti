import Foundation
import Testing
@testable import Transcription

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
    func vocabularyTruncation() throws {
        let longTerms = (0 ..< 500).map { "LongCompanyName\($0)" }
        let result = VocabularyFormatter.formatPrompt(from: longTerms)

        #expect(result != nil)
        #expect(try #require(result?.count) <= VocabularyFormatter.maxPromptCharacters)

        let includedCount = try #require(result?.components(separatedBy: ",").count)
        #expect(includedCount < longTerms.count)
        #expect(includedCount > 0)
    }

    @Test("Prompt starts with expected framing")
    func promptFraming() throws {
        let result = try #require(VocabularyFormatter.formatPrompt(from: ["test"]))
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
        let effectiveBudget = VocabularyFormatter.maxPromptCharacters - VocabularyFormatter.framingOverhead

        // A single very long term that fits in the budget
        let longTerm = String(repeating: "a", count: effectiveBudget - 5)
        let result = VocabularyFormatter.formatPrompt(from: [longTerm])
        #expect(result != nil)

        // A single term that exceeds the budget
        let tooLongTerm = String(repeating: "a", count: effectiveBudget + 100)
        let tooLongResult = VocabularyFormatter.formatPrompt(from: [tooLongTerm])
        #expect(tooLongResult == nil)
    }

    @Test("Boundary: single term at exactly budget and budget+1")
    func budgetBoundaryExact() {
        let effectiveBudget = VocabularyFormatter.maxPromptCharacters - VocabularyFormatter.framingOverhead
        // Each term costs term.count + 2 (for the ", " separator accounting).
        // A single term fits when term.count + 2 <= budget.
        let maxFittingLength = effectiveBudget - 2

        // Term at exactly the cutoff: should be included
        let fittingTerm = String(repeating: "x", count: maxFittingLength)
        let fittingResult = VocabularyFormatter.formatPrompt(from: [fittingTerm])
        #expect(fittingResult != nil)

        // Term one character longer: should be rejected (returns nil)
        let overflowTerm = String(repeating: "x", count: maxFittingLength + 1)
        let overflowResult = VocabularyFormatter.formatPrompt(from: [overflowTerm])
        #expect(overflowResult == nil)
    }
}
