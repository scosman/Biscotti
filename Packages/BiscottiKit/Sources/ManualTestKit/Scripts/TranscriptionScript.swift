/// The Transcription manual test script.
///
/// Reduced to model download/cache steps plus an AI-test tracker. Quality and
/// crash-isolation checks are covered by `make test-ai` (the automated AI test
/// set) and are no longer duplicated here.
public extension TestScript {
    /// Transcription test script — covers model download and cache verification,
    /// plus a tracker for the automated AI test outcome.
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
            )
        ]
    )
}
