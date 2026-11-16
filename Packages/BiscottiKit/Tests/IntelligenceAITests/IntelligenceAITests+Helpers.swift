import Foundation
import LocalLLM
import Testing
@testable import Intelligence

/// Shared helpers for `IntelligenceAITests`, kept out of the suite body so it
/// stays within SwiftLint's type-body-length limit.
extension IntelligenceAITests {
    /// Run a speaker-identification prompt 3 times, return parsed results.
    static func runSpeakerID(
        conn: LLMConnection, model: AITestModel, userContent: String
    ) async throws -> [[Int: SpeakerMappingParser.SpeakerMapping]] {
        let messages: [LLMMessage] = [
            .system(IntelligencePrompts.analysisSystem),
            .user(userContent)
        ]
        var results: [[Int: SpeakerMappingParser.SpeakerMapping]] = []
        for run in 1 ... 3 {
            let result = try await conn.generate(
                messages: messages, options: MeetingAnalyzer.speakerOptions
            )
            // Raw output in the test log, for prompt tuning when a case fails.
            print("[IntelligenceAITests] [\(model.name)] run \(run) raw output:\n\(result.rawText)\n---")
            results.append(SpeakerMappingParser.parse(result.text))
        }
        return results
    }

    /// Phrases a leaked chain of thought opens with (seen on E2B/E4B).
    static let reasoningOpeners = [
        "the user wants", "the user is asking", "the user has", "i need to", "let me ", "okay, ", "first, i"
    ]

    /// Expects `result` to be a direct answer: no thought-channel tokens in the raw
    /// output, no reasoning-style opening, and the turn ended before the token budget.
    static func expectNoLeakedReasoning(
        _ result: GenerationResult, task: String, model: AITestModel
    ) {
        let raw = result.rawText
        #expect(
            !raw.contains("<channel|>") && !raw.contains("<|channel>"),
            "[\(model.name)] \(task): thinking off must not use a thought channel; raw output:\n\(raw)"
        )
        let opening = result.text.lowercased()
        let readsLikeReasoning = reasoningOpeners.contains { opening.hasPrefix($0) }
        #expect(
            !readsLikeReasoning,
            "[\(model.name)] \(task): output reads like reasoning:\n\(result.text)"
        )
        #expect(
            result.finishReason != .maxTokens,
            "[\(model.name)] \(task): hit the token budget, likely spent on reasoning; raw output:\n\(raw)"
        )
    }

    /// Streams the summary turn as `MeetingAnalyzer` does and checks both the
    /// streamed tokens and the final result for leaked reasoning.
    static func streamSummary(
        conn: LLMConnection, model: AITestModel, messages: [LLMMessage]
    ) async throws -> GenerationResult {
        var streamedSummary = ""
        var summaryResult: GenerationResult?
        let stream = await conn.generateStreaming(
            messages: messages, options: MeetingAnalyzer.summaryOptions
        )
        for try await event in stream {
            switch event {
            case let .token(text):
                streamedSummary += text
            case let .done(result):
                summaryResult = result
            case .reasoningToken:
                break
            }
        }
        let summary = try #require(summaryResult, "Stream must end with a .done event")
        print("[IntelligenceAITests] [\(model.name)] summary raw output:\n\(summary.rawText)\n---")
        expectNoLeakedReasoning(summary, task: "summary", model: model)
        #expect(
            !streamedSummary.contains("<channel|>"),
            "[\(model.name)] summary: streamed tokens must not carry channel tokens"
        )
        return summary
    }

    /// Expects at least 2 of the runs to be correct. `problems` returns the
    /// conditions a run broke (empty when the run is correct), so a failure says
    /// which condition failed in which run.
    static func expectMostRunsCorrect(
        _ results: [[Int: SpeakerMappingParser.SpeakerMapping]],
        model: AITestModel,
        sourceLocation: SourceLocation = #_sourceLocation,
        problems: ([Int: SpeakerMappingParser.SpeakerMapping]) -> [String]
    ) {
        let runProblems = results.map(problems)
        let successes = runProblems.filter(\.isEmpty).count
        let details = runProblems.enumerated()
            .filter { !$0.element.isEmpty }
            .map { "run \($0.offset + 1): \($0.element.joined(separator: "; "))" }
            .joined(separator: "\n")
        #expect(
            successes >= 2,
            "[\(model.name)] \(successes)/\(results.count) runs correct, need >= 2. Failed conditions:\n\(details)",
            sourceLocation: sourceLocation
        )
    }
}
