/// The Audio Capture manual test script.
///
/// Steps derived from `experiments/AudioLab/VALIDATION.md`. The action/autoCheck
/// closures are placeholder no-ops here — the app target replaces them with real
/// AudioCapture calls when it builds the runner.
public extension TestScript {
    /// Audio Capture test script — covers permissions, dual-stream recording,
    /// file validation, playback quality, route-change resilience, crash safety,
    /// and meeting-detection monitoring.
    static let audioCapture = TestScript(
        id: "audio_capture",
        title: "Audio Capture",
        steps: [
            .action(
                id: "ac_request_permissions",
                label: "Request audio permissions (mic + system)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "ac_two_dialogs",
                prompt: "Did you see TWO permission dialogs (microphone and system audio)?"
            ),
            .instruction(
                id: "ac_timed_capture",
                text: "Press 'Run' on Start Recording, speak into the mic and play system audio "
                    + "(e.g. a video) for 15+ seconds, then press 'Run' on Stop Recording."
            ),
            .action(
                id: "ac_start_recording",
                label: "Start Recording (stop manually when done)",
                run: { _ in /* wired by the app target */ }
            ),
            .action(
                id: "ac_stop_recording",
                label: "Stop Recording",
                run: { _ in /* wired by the app target */ }
            ),
            .autoCheck(
                id: "ac_files_exist",
                label: "Two .aac files exist with sane sizes",
                check: { CheckOutcome(passed: false, detail: "Not wired — run from the test app") }
            ),
            .humanQuestion(
                id: "ac_playback_mic",
                prompt: "Play the mic recording — is your voice audible and clear?"
            ),
            .humanQuestion(
                id: "ac_playback_system",
                prompt: "Play the system recording — is the system audio audible and clear?"
            ),
            .humanQuestion(
                id: "ac_route_change",
                prompt: "Disconnect/reconnect AirPods mid-recording — did capture survive without crash or silence?"
            ),
            .instruction(
                id: "ac_crash_safety_setup",
                text: "Start a new recording, then force-kill the app (Activity Monitor or kill -9) mid-record."
            ),
            .humanQuestion(
                id: "ac_crash_safety_check",
                prompt: "Relaunch and check: does the partial .aac from the killed session still decode and play?"
            ),
            .humanQuestion(
                id: "ac_monitoring",
                prompt: "With a meeting app running (Zoom/Meet/Teams), does monitoring list the active app?"
            )
        ]
    )
}
