# Research Plan: Built-in Mic Quality vs. Voice Processing (VPIO) Side Effects

## Goal

Find a mic-capture strategy that produces clean, well-levelled, echo-free mic audio **without** disrupting the user's meeting app. Today we have two options and both fall short: VPIO gives clean audio but degrades or kills other apps' mic input (Teams, Chrome/WebRTC, Slack huddles; issue [#66](https://github.com/scosman/Biscotti/issues/66)), and a plain tap gives badly levelled, oddly mixed, echo-heavy audio, worst on the MacBook built-in mic array. The research feeds a ranked **options list** and a **proposed plan**, written after this research completes. The owner's questions:

1. Are all reports on the built-in mic? Is there a clean "if built-in, do X; else do Y" rule?
2. Why do Teams (and Slack huddles, Chrome) seem most affected? Or is it every app?
3. Can Apple's built-in-mic processing (beamforming/levelling/AEC) be had without disrupting other apps?
4. How do other apps in this space solve it?
5. Is there a post-processing voice-isolation / echo-cancellation option (Apple or OSS) we can use?
6. Related: how to handle multi-channel input devices (built-in arrays, audio interfaces where the mic isn't on channel 1).

## Run

- Model: same as the current session (inherited; not the frontier tier, so no step-down)

## Subtopics

- [ ] Internal evidence — what the repo, experiments, issue #66 and the related PRs already establish
- [ ] VPIO behaviour and side effects — why VPIO disrupts other apps, which apps, and which knobs exist
- [ ] Built-in mic array and multi-channel input — getting good built-in mic audio without VPIO; channel handling in general
- [ ] Prior art — how other meeting recorders and voice apps on macOS capture the mic
- [ ] Post-processing — offline/near-real-time AEC, voice isolation and levelling, using our separate system-audio track as the echo reference

## Focus Details

### Internal evidence

**Primarily a repo + GitHub investigation, not a web one.** Read `specs/research/audio/README.md`, `phase9_validation_findings.md`, `mic_capture_level_findings.md`, `hardware_debugging_workflow.md`, `experiments/AudioLab/` (`NOTES.md`, `VALIDATION.md`, `Sources/MicCapture.swift`, `Sources/VPIOMicCapture.swift`), and the production mic path in `Packages/AudioCapture/Sources/AudioCapture/` (`LiveMicCaptureEngine.swift`, `MicCaptureSession.swift`, `VPIOFileHelper.swift`/`VPIOBufferHelper`, `AudioRecorder.swift`). Then GitHub: issue #66 and every comment, PRs #115 and #118 (description, approach, review discussion, and what they trade away), and any other open/closed PRs or issues on the same problem (the owner mentions "about 5 PRs"; also check #116 and #129). Produce: (a) the current production behaviour precisely (when VPIO is on, `ensureOutputRateMatchesInput()`, channel-0 extraction, ducking settings if any); (b) a table of every user report — mic hardware, meeting app/browser, macOS version, symptom — to answer "is it only the built-in mic?"; (c) what each PR changes and its tradeoff; (d) what earlier experiments already tried and found (e.g. the 3-channel array finding). Use the web only to clarify an API you meet in the code. Do not research external fixes — that belongs to the other subtopics.

### VPIO behaviour and side effects

How Apple's voice processing (VoiceProcessingIO / `AUVoiceIO`, `AVAudioInputNode.setVoiceProcessingEnabled`) works on macOS 15–27, and exactly why it affects other apps: the AUVP aggregate device, tap streams being enabled on every device, "chat flavors" and HAL Voice Isolation, Control Center Microphone Modes, the "other audio ducking" behaviour and its knobs (`voiceProcessingOtherAudioDuckingConfiguration`, `kAUVoiceIOProperty_OtherAudioDuckingConfiguration`, advanced ducking, ducking level), `isVoiceProcessingBypassed`, `isVoiceProcessingAGCEnabled`, muting APIs, and forced output sample-rate changes. Answer: does the disruption come from ducking, from the shared HAL input-processing mode, from the aggregate/reclock, or from all of these? Can two VPIO clients coexist, and how do Zoom, FaceTime, Teams (native and web), Slack huddles and Chrome/WebRTC each capture the mic on macOS — which explains why some apps break and others don't? Include Apple developer forum threads, WWDC sessions and release notes; note version-specific changes (macOS 14 ducking API, 15, 26, 27). Out of scope: raw built-in array access without VPIO (next subtopic), and post-processing.

### Built-in mic array and multi-channel input

How the MacBook built-in mic is exposed to Core Audio and AVFoundation without voice processing: channel count by model and mode (users report 3 channels in some modes and a "7-channel" array mix in others), whether a non-VP path can get Apple's beamformed, levelled mono (data sources, `AVCaptureDevice` microphone modes, `AVCaptureSession` vs. AVAudioEngine vs. HAL/AUHAL, aggregate devices, "Voice Isolation"/"Wide Spectrum" modes, any macOS 26/27 API), and how to down-mix a raw array sensibly (pick one capsule vs. sum vs. simple delay-and-sum beamforming; the phase and level issues). Also general multi-channel device handling: audio interfaces with 12+ inputs where the mic is not on channel 1, letting the user pick a device/channel, auto-detecting the live channel, and detecting the built-in mic reliably (transport type, UID, model) so a "built-in → strategy X" rule is robust. Out of scope: VPIO's effect on other apps (previous subtopic) and DSP-based echo removal (post-processing subtopic).

### Prior art

How other macOS apps that record meetings or capture voice alongside a call handle the mic, and whether they hit the same bug. **Weight the effort toward open-source apps, where we can read the actual source code and expect real detail:** Hyprnote/Char, Meetily, Screenpipe, OBS, and any other OSS Mac meeting recorder or voice app found (search GitHub for Swift/Rust/Electron projects using `setVoiceProcessingEnabled`, `kAudioUnitSubType_VoiceProcessingIO`, or Core Audio process taps). For commercial apps (Granola, Otter, Fathom, Krisp, Notion AI meeting notes, Jamie, MacWhisper, Superwhisper, Rewind/Limitless, Bluedot, Audio Hijack, Loom, Recall.ai's desktop SDK) spend less effort: a web search for what people have already worked out (teardowns, support docs, forum and HN threads, changelogs) is enough; don't try to reverse-engineer them. For each app, establish: do they use VPIO, a plain tap, ScreenCaptureKit mic capture, or something else; do they do their own AEC/noise suppression; do they record mic and system separately; what do their issue trackers and support docs say about echo, quiet built-in mic, or breaking the other app's mic; and any documented workaround (e.g. "use headphones"). Out of scope: evaluating DSP libraries in depth (post-processing subtopic) — just note which ones each app uses.

### Post-processing

Options for cleaning the mic track after capture, or in near-real time, without touching the device: acoustic echo cancellation using Biscotti's separately recorded system-audio track as the far-end reference (WebRTC AEC3 / Audio Processing Module, SpeexDSP, DTLN-aec and other neural AEC models, any Apple API), voice isolation / noise suppression (Apple `AUSoundIsolation` and any other Apple audio units, DeepFilterNet, RNNoise, commercial SDKs such as Krisp, ai-coustics, Picovoice Koala), and loudness levelling/AGC. For each: license, Swift/Apple-silicon integration path, real-time vs. offline, CPU cost, quality evidence, and failure modes (clock drift and latency between the mic and system tracks, non-linear echo from laptop speakers, double-talk). Also cover the downstream alternative: if the echo is system audio already captured on the system track, can transcript-level de-duplication (drop mic-track speech that matches system-track speech at the same time) or WhisperKit/SpeakerKit robustness make echo removal unnecessary for transcripts, and does input level matter for Whisper accuracy? Out of scope: capture-side APIs (other subtopics).
