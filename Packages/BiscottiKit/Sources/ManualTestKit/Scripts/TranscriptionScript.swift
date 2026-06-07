/// The Transcription manual test script.
///
/// Steps derived from `experiments/ArgMaxKit/VALIDATION.md`. Action/autoCheck
/// closures are placeholder no-ops — the app target replaces them with real
/// Transcription calls when it builds the runner.
public extension TestScript {
    /// Transcription test script — covers model download, transcription,
    /// diarization output checks, hallucination guard, crash resilience, and custom vocab.
    static let transcription = TestScript(
        id: "transcription",
        title: "Transcription",
        steps: [
            .action(
                id: "tx_model_download",
                label: "Download transcription model (shows progress)",
                run: { /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "tx_model_disk",
                prompt: "Does the model download succeed and report on-disk size?"
            ),
            .action(
                id: "tx_transcribe",
                label: "Transcribe a recorded audio clip",
                run: { /* wired by the app target */ }
            ),
            .autoCheck(
                id: "tx_speakers",
                label: "Diarized output contains >= 2 distinct speakers",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            ),
            .autoCheck(
                id: "tx_no_hallucination",
                label: "No transcript segment extends past audio duration",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            ),
            .instruction(
                id: "tx_crash_setup",
                text: "Start a transcription, then force-kill the app (Activity Monitor or kill -9) mid-run."
            ),
            .humanQuestion(
                id: "tx_crash_host_survives",
                prompt: "After killing the process, did the host app survive without crashing?"
            ),
            .humanQuestion(
                id: "tx_crash_retry",
                prompt: "Retry the transcription — did it succeed on the second attempt?"
            ),
            .humanQuestion(
                id: "tx_custom_vocab",
                prompt: "Transcribe with custom-vocab bias — are the domain-specific terms present in output?"
            )
        ]
    )
}
