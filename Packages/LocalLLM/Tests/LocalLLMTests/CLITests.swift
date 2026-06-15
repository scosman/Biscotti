import Foundation
import Testing
@testable import LocalLLM

@Suite("Transcript substitution")
struct TranscriptSubstitutionTests {
    @Test("Substitutes transcript into placeholder")
    func basicSubstitution() throws {
        let prompt = "Summarize this:\n\n{{transcript}}"
        let transcript = "Speaker A: Hello\nSpeaker B: Hi"
        let result = try PromptUtils.substituteTranscript(prompt: prompt, transcript: transcript)
        #expect(result == "Summarize this:\n\nSpeaker A: Hello\nSpeaker B: Hi")
    }

    @Test("No placeholder, no transcript -- passes through unchanged")
    func noPlaceholderNoTranscript() throws {
        let prompt = "Just a plain prompt."
        let result = try PromptUtils.substituteTranscript(prompt: prompt, transcript: nil)
        #expect(result == "Just a plain prompt.")
    }

    @Test("Placeholder present but no transcript -- errors")
    func placeholderWithoutTranscript() {
        let prompt = "Here: {{transcript}}"
        #expect(throws: PromptError.placeholderWithoutTranscript) {
            try PromptUtils.substituteTranscript(prompt: prompt, transcript: nil)
        }
    }

    @Test("Transcript provided but no placeholder -- errors")
    func transcriptWithoutPlaceholder() {
        let prompt = "No placeholder here."
        #expect(throws: PromptError.transcriptWithoutPlaceholder) {
            try PromptUtils.substituteTranscript(prompt: prompt, transcript: "some content")
        }
    }

    @Test("Multiple placeholders are all replaced")
    func multiplePlaceholders() throws {
        let prompt = "First: {{transcript}}\nSecond: {{transcript}}"
        let result = try PromptUtils.substituteTranscript(prompt: prompt, transcript: "content")
        #expect(result == "First: content\nSecond: content")
    }

    @Test("Empty transcript substitutes to empty")
    func emptyTranscript() throws {
        let prompt = "Data: {{transcript}}"
        let result = try PromptUtils.substituteTranscript(prompt: prompt, transcript: "")
        #expect(result == "Data: ")
    }
}
