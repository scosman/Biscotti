/// The Local LLM manual test script.
///
/// Covers model download, XPC-based inference (buffered + streaming),
/// end-to-end prompt capabilities (summarize, action items, speaker names,
/// thinking mode, streaming channels), and reclamation (service process exits
/// on connection close). All inference steps run through the real
/// `BiscottiLLM.xpc` service; the human observes the output and confirms
/// each capability worked end-to-end.
public extension TestScript {
    /// A realistic short multi-speaker meeting transcript used as the input for
    /// the capability-demonstration steps. Defined here so both the `.instruction`
    /// display step and the wired action closures reference the same text.
    static let sampleMeetingTranscript = """
    [00:01] Alice: Let's ship the billing fix before Friday. I'll own the backend change.
    [00:14] Bob: I can take the migration script, but I need the schema from Alice by Wednesday.
    [00:30] Alice: Done — I'll send it tomorrow morning. Carol, can you QA on Thursday?
    [00:42] Carol: Yes, I'll run the regression suite Thursday and report back by end of day.
    [00:55] Bob: One more thing — the staging deploy is broken. Dave, can you look at it today?
    [01:03] Dave: Already on it. I'll have a fix pushed by noon and ping the channel.
    [01:15] Alice: Great. Let's sync again Friday morning to confirm everything landed.
    """

    /// Local LLM test script — covers download, XPC inference, end-to-end
    /// prompt capabilities, and resource reclamation.
    static let localLLM = TestScript(
        id: "local_llm",
        title: "Local LLM",
        steps: [
            // 1. Model download
            .action(
                id: "llm_model_download",
                label: "Download LLM model (shows progress)",
                run: { _ in /* wired by the app target */ }
            ),
            // 2. Download observation
            .humanQuestion(
                id: "llm_model_disk",
                prompt: "While downloading, did the status message show progress "
                    + "(bytes downloaded / total)? If the model was already present, "
                    + "it finishes instantly with no status — that is expected; mark Pass."
            ),
            // 3. AI test suite
            .humanQuestion(
                id: "llm_ai_tests_passed",
                prompt: "Run `make test-ai` (downloads the model if needed; runs the "
                    + "in-process LLM integration tests). Did all AI tests pass?"
            ),
            // 4. Basic XPC inference
            .action(
                id: "llm_xpc_inference",
                label: "Run XPC inference (generates a response via BiscottiLLM.xpc)",
                run: { _ in /* wired by the app target */ }
            ),
            // 5. Sample transcript display (non-recordable instruction)
            .instruction(
                id: "llm_sample_transcript",
                text: "The steps below run over this sample transcript:\n\n"
                    + sampleMeetingTranscript
            ),
            // 6. Summarize via XPC
            .action(
                id: "llm_summarize_run",
                label: "Summarize the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 7. Summarize observation
            .humanQuestion(
                id: "llm_summarize_quality",
                prompt: "Did a coherent summary of the transcript appear above "
                    + "(non-empty, on-topic)?"
            ),
            // 8. Action items via XPC
            .action(
                id: "llm_action_items_run",
                label: "Extract action items from the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 9. Action items observation
            .humanQuestion(
                id: "llm_action_items_quality",
                prompt: "Did action items with owners and deadlines appear above?"
            ),
            // 10. Speaker names via XPC
            .action(
                id: "llm_speaker_names_run",
                label: "Identify speakers from the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 11. Speaker names observation
            .humanQuestion(
                id: "llm_speaker_names_quality",
                prompt: "Did speaker names with their responsibilities and "
                    + "supporting quotes appear above?"
            ),
            // 12. Thinking mode via XPC
            .action(
                id: "llm_thinking_run",
                label: "Run thinking-mode inference via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 13. Thinking mode observation
            .humanQuestion(
                id: "llm_thinking_mode",
                prompt: "Did a reasoning section followed by a final answer "
                    + "appear above?"
            ),
            // 14. Streaming via XPC
            .action(
                id: "llm_streaming_run",
                label: "Run streaming inference via BiscottiLLM.xpc (tokens render incrementally)",
                run: { _ in /* wired by the app target */ }
            ),
            // 15. Streaming observation
            .humanQuestion(
                id: "llm_streaming_channels",
                prompt: "Did tokens render incrementally, with thinking vs. "
                    + "response cleanly separated (no raw markers like <think>)?"
            ),
            // 16. Reclamation check
            .autoCheck(
                id: "llm_reclamation",
                label: "No BiscottiLLM service process running after connection close",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            )
        ]
    )
}
