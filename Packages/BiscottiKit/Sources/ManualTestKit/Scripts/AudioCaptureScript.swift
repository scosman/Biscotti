/// The Audio Capture manual test script.
///
/// Steps derived from `experiments/AudioLab/VALIDATION.md`. The action/autoCheck
/// closures are placeholder no-ops here — the app target replaces them with real
/// AudioCapture calls when it builds the runner.
public extension TestScript {
    /// Audio Capture test script — covers permissions, dual-stream recording,
    /// file validation, playback quality, route-change resilience, meeting
    /// open/close mid-capture, mega experiment, and crash safety.
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
                    + "(e.g. start a Google Meet instant meeting at meet.google.com → New meeting "
                    + "→ Start an instant meeting) for 15+ seconds, then press 'Run' on Stop Recording."
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
                prompt: "Mid-recording, connect AirPods, speak, then disconnect and keep speaking. "
                    + "In playback you should hear the mic source change (built-in → AirPods → built-in); "
                    + "capture survives the transitions without crash or silence."
            ),
            .humanQuestion(
                id: "ac_device_sample_rate",
                prompt: "Mid-recording: (1) connect AirPods/Bluetooth headphones (triggers a sample-rate "
                    + "change); (2) switch output to a 44.1 kHz device (e.g. some USB DACs); (3) switch "
                    + "output back. On stop, verify the system audio file plays back correctly — audio "
                    + "captured before each transition is preserved. A -66565 stop-track (system audio "
                    + "ends early but mic continues) is acceptable; total silence or a crash is not."
            ),
            .humanQuestion(
                id: "ac_meet_close_midcapture",
                prompt: "Start capture with a Google Meet instant meeting already running; speak; "
                    + "after a few seconds close Meet and keep speaking. Verify (mic playback) your "
                    + "voice was captured both before and after Meet closed."
            ),
            .humanQuestion(
                id: "ac_meet_open_midcapture",
                prompt: "Start capture with no meeting running; speak; after a few seconds start "
                    + "a Google Meet instant meeting and keep speaking. Verify your voice was captured "
                    + "both before and after Meet started."
            ),
            .instruction(
                id: "ac_mega_setup",
                text: "Run the mega experiment sequence: (1) start capture; (2) start a Google Meet "
                    + "instant meeting; (3) open Music and play a track, saying \"starting music now\" "
                    + "exactly as it begins; (4) insert AirPods; (5) remove AirPods; (6) stop the Meet; "
                    + "(7) stop capture."
            ),
            .humanQuestion(
                id: "ac_mega_voice",
                prompt: "In the mic playback, is your voice clear and continuous across all mode "
                    + "changes (built-in → AirPods → built-in, Meet on/off)?"
            ),
            .humanQuestion(
                id: "ac_mega_timing",
                prompt: "In the system playback, does the music begin exactly when you said "
                    + "\"starting music now\" — i.e. system audio is time-aligned to the mic "
                    + "with no offset?"
            ),
            .instruction(
                id: "ac_crash_safety_setup",
                text: "Start a new recording, then force-kill the ManualTestApp process: "
                    + "in Activity Monitor, select ManualTestApp and Force Quit; or run "
                    + "`kill -9 $(pgrep -x ManualTestApp)`."
            ),
            .humanQuestion(
                id: "ac_crash_safety_check",
                prompt: "Relaunch and check: does the partial .aac from the killed session still decode and play?"
            )
        ]
    )
}
