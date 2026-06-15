/// The Local LLM manual test script.
///
/// Covers model download, XPC-based inference (buffered + streaming), quality
/// judgments on summarization/action-items/speaker-names, thinking mode, streaming
/// channel routing, and reclamation (service process exits on connection close).
/// All inference steps run through the real `BiscottiLLM.xpc` service.
public extension TestScript {
    /// Local LLM test script — covers download, XPC inference, quality, and
    /// resource reclamation.
    static let localLLM = TestScript(
        id: "local_llm",
        title: "Local LLM",
        steps: [
            .action(
                id: "llm_model_download",
                label: "Download LLM model (shows progress)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "llm_model_disk",
                prompt: "While downloading, did the status message show progress "
                    + "(bytes downloaded / total)? If the model was already present, "
                    + "it finishes instantly with no status — that is expected; mark Pass."
            ),
            .humanQuestion(
                id: "llm_ai_tests_passed",
                prompt: "Run `make test-ai` (downloads the model if needed; runs the "
                    + "in-process LLM integration tests). Did all AI tests pass?"
            ),
            .action(
                id: "llm_xpc_inference",
                label: "Run XPC inference (generates a response via BiscottiLLM.xpc)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "llm_summarize_quality",
                prompt: "The summarize prompt ran over the sample transcript via XPC. "
                    + "Is the summary accurate with no hallucinations?"
            ),
            .humanQuestion(
                id: "llm_action_items_quality",
                prompt: "The action-items prompt ran over the sample transcript via XPC. "
                    + "Does the output capture owners and deadlines?"
            ),
            .humanQuestion(
                id: "llm_speaker_names_quality",
                prompt: "The speaker-names prompt ran over the sample transcript via XPC. "
                    + "Are the inferred names correct with supporting quotes?"
            ),
            .humanQuestion(
                id: "llm_thinking_mode",
                prompt: "The thinking-mode prompt ran via XPC. Did the output show a "
                    + "reasoning section followed by a final answer?"
            ),
            .humanQuestion(
                id: "llm_streaming_channels",
                prompt: "The streaming inference ran via XPC. Did tokens render "
                    + "incrementally? Were thinking vs. response sections routed "
                    + "cleanly (no raw channel markers like <think> visible)?"
            ),
            .autoCheck(
                id: "llm_reclamation",
                label: "No BiscottiLLM service process running after connection close",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            )
        ]
    )
}
