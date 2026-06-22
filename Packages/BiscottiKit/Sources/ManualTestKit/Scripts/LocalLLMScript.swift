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
            // 5. System-framed chat (messages API with system + user)
            .action(
                id: "llm_chat_system",
                label: "Run system-framed inference via BiscottiLLM.xpc "
                    + "(system + user messages)",
                run: { _ in /* wired by the app target */ }
            ),
            // 6. System-framed chat observation
            .humanQuestion(
                id: "llm_chat_system_quality",
                prompt: "Did the response follow the system instruction "
                    + "(pirate-speak)? The answer should be in pirate style."
            ),
            // 7. Sample transcript display (non-recordable instruction)
            .instruction(
                id: "llm_sample_transcript",
                text: "The steps below run over this sample transcript:\n\n"
                    + sampleMeetingTranscript
            ),
            // 8. Summarize via XPC
            .action(
                id: "llm_summarize_run",
                label: "Summarize the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 9. Summarize observation
            .humanQuestion(
                id: "llm_summarize_quality",
                prompt: "Did a coherent summary of the transcript appear above "
                    + "(non-empty, on-topic)?"
            ),
            // 10. Action items via XPC
            .action(
                id: "llm_action_items_run",
                label: "Extract action items from the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 11. Action items observation
            .humanQuestion(
                id: "llm_action_items_quality",
                prompt: "Did action items with owners and deadlines appear above?"
            ),
            // 12. Speaker names via XPC
            .action(
                id: "llm_speaker_names_run",
                label: "Identify speakers from the sample transcript via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 13. Speaker names observation
            .humanQuestion(
                id: "llm_speaker_names_quality",
                prompt: "Did speaker names with their responsibilities and "
                    + "supporting quotes appear above?"
            ),
            // 14. Thinking mode via XPC
            .action(
                id: "llm_thinking_run",
                label: "Run thinking-mode inference via BiscottiLLM.xpc",
                run: { _ in /* wired by the app target */ }
            ),
            // 15. Thinking mode observation
            .humanQuestion(
                id: "llm_thinking_mode",
                prompt: "Did a reasoning section followed by a final answer "
                    + "appear above?"
            ),
            // 16. Streaming via XPC
            .action(
                id: "llm_streaming_run",
                label: "Run streaming inference via BiscottiLLM.xpc (tokens render incrementally)",
                run: { _ in /* wired by the app target */ }
            ),
            // 17. Streaming observation
            .humanQuestion(
                id: "llm_streaming_channels",
                prompt: "Did tokens render incrementally, with thinking vs. "
                    + "response cleanly separated (no raw markers like <think>)?"
            ),
            // 18. KV-cache prefix reuse (two extending generates in one connection)
            .instruction(
                id: "llm_kv_reuse_info",
                text: "The next step runs TWO sequential generates in a single connection. "
                    + "The second call extends the first's message list so the KV-cache "
                    + "prefix is reused. Look for:\n"
                    + "• Turn 1: cachedPromptTokenCount ≈ 0 (cold start)\n"
                    + "• Turn 2: cachedPromptTokenCount >> 0 (most of the transcript prefix reused)\n"
                    + "• Turn 2 prompt eval time should be much faster than turn 1\n"
                    + "• Turn 2 output should be coherent (not garbled — validates position continuation)"
            ),
            // 19. KV-cache reuse action
            .action(
                id: "llm_kv_reuse",
                label: "Run KV-cache reuse test (two extending generates in one connection)",
                run: { _ in /* wired by the app target */ }
            ),
            // 20. KV-cache reuse observation
            .humanQuestion(
                id: "llm_kv_reuse_quality",
                prompt: "Did the 2nd call reuse most of the prefix (high cached count, "
                    + "much faster prompt eval) and was the 2nd response coherent?"
            ),
            // 21. Reclamation check
            .autoCheck(
                id: "llm_reclamation",
                label: "No BiscottiLLM service process running after connection close",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            )
        ]
    )
}
