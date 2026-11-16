import DataStore
import Foundation
import LocalLLM
import Testing
@testable import Intelligence

private let isAITestEnabled =
    ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"

/// LLM-backed analysis tests: speaker identification with voiceprint evidence,
/// plus a check that summaries and titles carry no leaked reasoning.
///
/// Every test runs against every model in `LLMModelCatalog.all` (parameterized
/// over `AITestModel.all`, labelled by model) and needs
/// `BISCOTTI_RUN_AI_TESTS=1` in the environment. A bare `swift test` skips them
/// entirely. Run via `make test-ai`. A catalog model that isn't downloaded
/// skips its cases and fails `allCatalogModelsOnDisk` (one failure, naming each
/// missing model and how to download it); `LLM_MODEL_PATH` narrows the run to
/// one GGUF.
///
/// Each speaker case builds the real first user message with
/// `IntelligencePrompts.analysisFirstUser` (most with a handwritten
/// `<voiceprint_matches>` block), runs with `MeetingAnalyzer.speakerOptions`,
/// and parses with `SpeakerMappingParser`. Output varies, so each case runs
/// 3 times and passes when >= 2 runs are correct; cases checked through
/// `expectMostRunsCorrect` list the conditions each failed run broke.
@Suite("Intelligence AI Tests (BISCOTTI_RUN_AI_TESTS=1)", .enabled(if: isAITestEnabled), .serialized)
struct IntelligenceAITests {
    // MARK: - Test cases

    @Test(
        "All catalog models are on disk (download any missing model first)",
        .enabled(if: AITestModel.overridePath == nil, "LLM_MODEL_PATH narrows the run to one model")
    )
    func allCatalogModelsOnDisk() {
        AITestModel.expectAllCatalogModelsOnDisk()
    }

    /// Summary then title, as `MeetingAnalyzer` runs them (summary streamed, title
    /// as a follow-up turn, both thinking off). Neither may contain reasoning.
    @Test("summary-and-title: no leaked reasoning", arguments: AITestModel.all)
    func summaryAndTitleHaveNoLeakedReasoning(model: AITestModel) async throws {
        guard let conn = try await AITestConnection.connection(for: model) else { return }

        let transcript = """
        Alice: Morning. The goal today is to ship the billing fix before Friday.
        Bob: I'll take the migration script, but I need the final schema by Wednesday.
        Alice: I'll send the schema tomorrow. Let's backfill existing invoices too.
        Carol: I'll run the payment regression suite on Thursday once staging is green.
        Bob: Staging is broken by a flaky webhook test. Dave is fixing it today.
        Alice: Great. Let's put the migration behind a feature toggle and sync Friday.
        """
        let detail = MeetingDetailData(
            id: UUID(), title: "Billing Sync", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        var messages: [LLMMessage] = [
            .system(IntelligencePrompts.analysisSystem),
            .user(IntelligencePrompts.summaryOnlyFirstUser(detail: detail, transcriptNamed: transcript))
        ]

        let summary = try await Self.streamSummary(conn: conn, model: model, messages: messages)

        messages.append(.assistant(summary.text))
        messages.append(.user(IntelligencePrompts.titleFollowUpUser))
        let title = try await conn.generate(messages: messages, options: MeetingAnalyzer.titleOptions)
        print("[IntelligenceAITests] [\(model.name)] title raw output:\n\(title.rawText)\n---")
        Self.expectNoLeakedReasoning(title, task: "title", model: model)
        #expect(MeetingAnalyzer.cleanTitle(title.text) != nil, "[\(model.name)] title: expected a usable title")
    }

    /// Known limit (functional spec §7.4): with thinking off, the model takes
    /// the transcript's name ("Samantha") and leaves the email blank instead of
    /// copying `sam@kiln.tech` from the other entry. Thinking on fixes it but is
    /// ~14x slower, and prompt-only changes did not help. So a blank email is
    /// accepted; a different email, or the name on the other speaker, is not.
    @Test("same-human-two-entries: Sam/Samantha, email listed or blank", arguments: AITestModel.all)
    func sameHumanTwoEntries(model: AITestModel) async throws {
        guard let conn = try await AITestConnection.connection(for: model) else { return }

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 5 earlier meetings, 3 with names that the user confirmed.

        Speaker 0: voice is close to more than one known person: \
        Sam <sam@kiln.tech> (3 meetings, 2 confirmed by the user) and \
        Samantha (no email) (2 meetings, 1 confirmed by the user).
        Speaker 1: no voiceprint available for this speaker.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 1: Hi Samantha, shall we start?
        Speaker 0: Sure, let me pull up the notes from last week.
        Speaker 1: Great, I had a few questions about the API changes.
        Speaker 0: Go ahead, I reviewed the PR this morning.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Team Sync", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, model: model, userContent: userContent)
        Self.expectMostRunsCorrect(results, model: model) { parsed in
            var problems: [String] = []
            // Speaker 0 is Sam/Samantha, with the listed email or none.
            if let speaker0 = parsed[0] {
                if !speaker0.name.lowercased().contains("sam") {
                    problems.append("Speaker 0 is \"\(speaker0.name)\", not Sam/Samantha")
                }
                if let email = speaker0.email, email != "sam@kiln.tech" {
                    problems.append("Speaker 0 email is \(email), not sam@kiln.tech or blank")
                }
            } else {
                problems.append("Speaker 0 was not identified (expected Sam/Samantha)")
            }
            // Speaker 1 (the one who says "Hi Samantha") must not get the name.
            if let speaker1 = parsed[1], speaker1.name.lowercased().contains("sam") {
                problems.append("Speaker 1 got \"\(speaker1.name)\", but Speaker 1 says \"Hi Samantha\"")
            }
            return problems
        }
    }

    /// Transcript-only evidence: a self-introduction and a thank-you to the
    /// previous speaker. No voiceprint evidence.
    @Test("self-intro-and-thanks: Steve introduces himself and thanks Daniel", arguments: AITestModel.all)
    func selfIntroAndThanks(model: AITestModel) async throws {
        guard let conn = try await AITestConnection.connection(for: model) else { return }

        let transcript = """
        Speaker 0: Hi, I'm Steve. Thanks for joining. Can someone give me the status of the release?
        Speaker 1: Sure, give me a second to pull it up.
        Speaker 2: The release branch is cut and QA signed off yesterday. We ship on Thursday.
        Speaker 0: Thanks for that, Daniel. Let's plan the announcement next.
        """

        let invitees = CalendarContextData(attendees: [
            PersonData(id: UUID(), name: "Steve", email: "steve@kiln.tech"),
            PersonData(id: UUID(), name: "Daniel", email: "daniel@kiln.tech")
        ])
        let detail = MeetingDetailData(
            id: UUID(), title: "Release Check-in", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil,
            calendar: invitees
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:], transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, model: model, userContent: userContent)
        Self.expectMostRunsCorrect(results, model: model) { parsed in
            var problems: [String] = []
            // Speaker 0 says "Hi, I'm Steve".
            if let speaker0 = parsed[0] {
                if !speaker0.name.lowercased().contains("steve") {
                    problems.append("Speaker 0 is \"\(speaker0.name)\", but says \"Hi, I'm Steve\"")
                }
            } else {
                problems.append("Speaker 0 was not identified (expected Steve)")
            }
            // Speaker 0 thanks Daniel right after Speaker 2 answers.
            if let speaker2 = parsed[2] {
                if !speaker2.name.lowercased().contains("daniel") {
                    problems.append("Speaker 2 is \"\(speaker2.name)\", but Speaker 0 then says \"Thanks for that, Daniel\"")
                }
            } else {
                problems.append("Speaker 2 was not identified (expected Daniel)")
            }
            // Only Speaker 2 is Daniel; Speaker 1 may be omitted.
            let otherDaniels = parsed
                .filter { $0.key != 2 && $0.value.name.lowercased().contains("daniel") }
                .map { "Speaker \($0.key)" }
                .sorted()
            if !otherDaniels.isEmpty {
                problems.append("\(otherDaniels.joined(separator: ", ")) also named Daniel; only Speaker 2 should be")
            }
            return problems
        }
    }

    @Test("different-humans-similar-voices: transcript disambiguates to Amit", arguments: AITestModel.all)
    func differentHumansSimilarVoices(model: AITestModel) async throws {
        guard let conn = try await AITestConnection.connection(for: model) else { return }

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 4 earlier meetings, 2 with names that the user confirmed.

        Speaker 0: voice is close to more than one known person: \
        Dave (no email) (2 meetings, 1 confirmed by the user) and \
        Amit (no email) (2 meetings, 1 confirmed by the user).
        Speaker 1: no voiceprint available for this speaker.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 1: Let's go through the action items from last time.
        Speaker 0: Sure. I finished the database migration yesterday.
        Speaker 1: Nice work. Thanks, Amit. What about the load tests?
        Speaker 0: I'll have those ready by end of week.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Sprint Review", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, model: model, userContent: userContent)
        var successes = 0
        for parsed in results {
            // Speaker 0 should be Amit (transcript says "thanks, Amit")
            if let mapping = parsed[0],
               mapping.name.lowercased().contains("amit")
            {
                successes += 1
            }
        }
        #expect(
            successes >= 2,
            "[\(model.name)] Expected >= 2/3 runs to identify Speaker 0 as Amit"
        )
    }

    @Test("high-confidence-match: Steve identified by voiceprint alone", arguments: AITestModel.all)
    func highConfidenceMatch(model: AITestModel) async throws {
        guard let conn = try await AITestConnection.connection(for: model) else { return }

        let voiceprintBlock = """
        <voiceprint_matches>
        Voiceprint history: 6 earlier meetings, 4 with names that the user confirmed.

        Speaker 0: no voiceprint available for this speaker.
        Speaker 1: High confidence match to Steve <steve@kiln.tech>. \
        Heard in 5 earlier meetings, 3 confirmed by the user.
        </voiceprint_matches>
        """

        let transcript = """
        Speaker 0: Good morning. Let's review the deployment plan.
        Speaker 1: Sounds good. I think we should roll out to staging first.
        Speaker 0: Agreed. Can you handle the staging deploy today?
        Speaker 1: Yes, I'll get that done after this call.
        """

        let detail = MeetingDetailData(
            id: UUID(), title: "Deployment Planning", date: Date(),
            duration: nil, hasAudio: false, preferredTranscript: nil
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: detail, human: [:],
            voiceprintBlock: voiceprintBlock,
            transcriptSpeakerLabeled: transcript
        )

        let results = try await Self.runSpeakerID(conn: conn, model: model, userContent: userContent)
        var successes = 0
        for parsed in results {
            // Speaker 1 should be Steve with the email
            if let mapping = parsed[1],
               mapping.name.lowercased().contains("steve"),
               mapping.email == "steve@kiln.tech"
            {
                successes += 1
            }
        }
        #expect(
            successes >= 2,
            "[\(model.name)] Expected >= 2/3 runs to identify Speaker 1 as Steve with steve@kiln.tech"
        )
    }
}
