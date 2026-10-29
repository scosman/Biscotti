/// The Transcription manual test script.
///
/// Covers Whisper model download/cache steps, AI-test tracker, and the Apple
/// Speech engine hardware spike steps.
public extension TestScript {
    /// Transcription test script — covers model download and cache verification,
    /// the automated AI test outcome, and Apple Speech engine validation.
    static let transcription = TestScript(
        id: "transcription",
        title: "Transcription",
        steps: [
            .action(
                id: "tx_clear_cache",
                label: "Clear model cache (delete downloaded models)",
                run: { _ in /* wired by the app target */ }
            ),
            .action(
                id: "tx_model_download",
                label: "Download transcription model (shows status)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "tx_model_disk",
                prompt: "While downloading, did the status message update through the "
                    + "stages (\"Downloading speech-to-text model\", then \"Downloading "
                    + "speaker ID model\")? If you skipped Clear cache and the models "
                    + "were already cached, it finishes instantly with no status — that "
                    + "is expected; mark Pass."
            ),
            .humanQuestion(
                id: "tx_ai_test_passed",
                prompt: "Run `make test-ai` (downloads models; runs the automated "
                    + "transcription / diarization / custom-vocab quality tests). "
                    + "Did all AI tests pass?"
            ),

            // MARK: - Apple Speech engine steps (Phase 2 hardware spike)

            .action(
                id: "tx_apple_status",
                label: "Apple Speech: check availability and asset status",
                run: { _ in /* wired by the app target */ }
            ),
            .action(
                id: "tx_apple_install",
                label: "Apple Speech: install assets for en_US",
                run: { _ in /* wired by the app target */ }
            ),
            .action(
                id: "tx_apple_transcribe",
                label: "Apple Speech: transcribe 3-speaker fixture via XPC",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "tx_apple_no_prompt",
                prompt: "Did the Apple Speech steps above (status, install, transcribe) "
                    + "run with no permission prompt?"
            ),
            .humanQuestion(
                id: "tx_apple_output_ok",
                prompt: "In the Biscotti app, with Apple Speech as the model, transcribe "
                    + "a recording. Is the transcript readable with plausible speaker turns?"
            )
        ]
    )
}
