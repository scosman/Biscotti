# Internal Evidence: repo, experiments, issue #66 and the related PRs

## Bottom Line

**What production does.** Biscotti runs VoiceProcessingIO on **every** input device, with no exceptions. At each engine build it also forces the default **output** device's sample rate to the input's rate. It drives a silent output node, sets ducking to `.min`, and records only **channel 0** of the post-VP tap.

**Who is affected.** Every report that names the failing mic names a **built-in** mic (MacBook *and* iMac), apart from one well-documented exception. Reporters and the owner say AirPods, USB mics and headsets work. The exception is an Audient iD24 USB interface on macOS 15, which broke Chrome/WebRTC the same way. So "built-in → no VPIO" would cover almost all reports, but not all of them. A second clause ("multichannel interface → no VPIO, pick the live channel") is needed for the iD24 case.

**Which apps.** Teams (desktop and Chrome), Zoom desktop, Slack Huddle, Chrome/WebRTC, and an Electron app, across macOS 15 through 27.0.1. So it is not Teams-specific.

**What the reclock and ducking contribute.** The output reclock is **not required** to trigger the bug: one full-mute report had input and output both at 48 kHz. Even at `.min`, VPIO still ducks other audio about −4 dB for the whole recording, and −15 dB for about 1 s each time a VP unit is created (measured in #129).

**The PR tradeoff.** #115 and #118 both fix the other app by dropping VPIO. A tester measured the cost on a built-in mic: voice about 11–15 dB quieter, and speaker echo louder than the voice. Through `AudioMerger`'s global-peak normalisation, that echo shrinks the whole meeting about ×0.2 and feeds remote speech in twice. #129 keeps VPIO and only fixes route-change reliability.

## Key Findings

- **Production VPIO is unconditional.** `LiveMicCaptureEngine.buildAndStartEngineOrThrow()` always runs, in order:
  1. `ensureOutputRateMatchesInput()`
  2. `setVoiceProcessingEnabled(true)`
  3. `voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`
  4. a silent `AVAudioSourceNode` → `outputNode` at the input rate
  5. a tap at the post-VP format

  `MicCaptureSession` copies `floatChannelData[0]` only. No setting, transport check or channel check exists. The mic level is unmonitored (`micLevel: 0`). — [production-behaviour.md](./production-behaviour.md); `Packages/AudioCapture/Sources/AudioCapture/LiveMicCaptureEngine.swift:169-214, 251-300`; `MicCaptureSession.swift:224`
- **The reclock changes a shared device and exists only for VPIO.** It sets `kAudioDevicePropertyNominalSampleRate` on the default output, polls for up to 1 s, ignores failure, and restores only at stop. AudioLab added it so the VPIO duplex unit avoids `-10875` and a choppy downlink. `NOTES.md` flagged it in June as "revisit for production"; it was never revisited. #123 lists it as one cause of `system.aac` ending early (`-66565`). — [prior-experiments.md](./prior-experiments.md), [PR #123](https://github.com/scosman/Biscotti/pull/123)
- **The reclock is not the root cause of the other-app breakage.** thomasvvugt's Slack Huddle full mute happened with built-in mic and speakers both at 48 kHz, where the reclock does nothing. — [#115 comment](https://github.com/scosman/Biscotti/pull/115#issuecomment-6359122965)
- **`.min` ducking is not "off".** The API has only `default`, `min`, `mid` and `max`. #129 measured −4 dB (0.630957) for the whole recording, plus −15 dB (0.177828) for 0.6–1.3 s at each new VP unit. This matches the #91 reports of output volume dropping. — [Apple docs](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/level), [PR #129](https://github.com/scosman/Biscotti/pull/129)
- **There are 20 user reports.** 6 name a built-in mic as failing (MOccam, timbowicz, gphr74 on an iMac, thomasvvugt, javimoya, and the owner). 1 names a non-built-in device as failing (alserevs, Audient iD24). 13 don't say. 3 say a headset, USB mic or AirPods was fine. — [user-reports.md](./user-reports.md)
- **The symptoms vary.** Some reports describe a full mute in the other app (Teams, Zoom, Slack, Teams echo bot). Others describe a quieter mic, a "hollow/tinny" mic (Chrome), or ducked output. The owner's own Slack case was level loss, never a full mute. — [user-reports.md](./user-reports.md)
- **Logs show VPIO reaching beyond Biscotti's own device.** They show it "enabled tap stream on" **every** device. They also show `Disabling HAL Voice Isolation support due to app's use of existing chat flavors`. One reporter fixed the other app by giving it a **different macOS Mic Mode** (Voice Isolation for Chrome, Standard for Biscotti). — [alserevs on #66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)
- **Channel 0 is wrong on multichannel interfaces.** On the iD24, with the mic on input 2, VPIO's channel 0 was the unconnected input 1. Every `mic.aac` came out at −91 dB, with no warning. — same comment
- **PR #115 makes VPIO an opt-out setting.** The default stays on. Plain mode averages all channels and skips the reclock and ducking. It **still attaches the silent output node**. The author tested Slack Huddle on a built-in mic: fixed, but "clearly less crisp, more room noise". — [pull-requests.md](./pull-requests.md)
- **PR #118 removes VPIO, the reclock, ducking and the silent output.** It records channel 0 of the native format. Measured cost on a built-in mic in a Teams test call: voice at −30 to −40 dBFS (vs −19 to −25 with VPIO). The echo bot leaked into the mic track louder than the voice, "+14 dBFS". The merged transcript audio was scaled down about ×0.2 and remote speech was duplicated. — [javimoya on #118](https://github.com/scosman/Biscotti/pull/118#issuecomment-6446547910)
- **PR #129 keeps VPIO and restarts the engine in place after route changes.** This cut AirPods mic gaps from 3–7.5 s to 0.3–2.5 s. It also avoids the #124 crash and deadlock that `setVoiceProcessingEnabled(false)` can cause when it races VP's own device-following. — [PR #129](https://github.com/scosman/Biscotti/pull/129), [#124](https://github.com/scosman/Biscotti/issues/124)
- **Earlier experiments already established these points:**
  - The built-in MBP mic is a **3-channel** array at 48 kHz (plain AVAudioEngine) or 44.1 kHz (AVCaptureSession during a meeting).
  - The raw array is **near-silent** (≈ −48 dBFS peak) on the AVCaptureSession path while a VP meeting app holds it. All 3 channels are equally low. Forcing the HAL input volume back to 1.0 did not help.
  - VPIO presents **9 channels**, with processed voice on ch0 (ch0 ≈ 0.54 vs 0.004).
  - The macOS **Mic Mode** audibly changes VPIO output, and Voice Isolation removes system-audio bleed.
  - `AVAudioConverter` silently zeroes discrete-layout multichannel input.

  Phase 9 had **rejected** VPIO, and the `stage_a_foundations` spec still says "NOT VPIO". The decision was reversed in June 2026. — [prior-experiments.md](./prior-experiments.md)

## Details

- [production-behaviour.md](./production-behaviour.md) — exact current mic path with line references: start order, reclock, ducking, silent output, channel-0 copy, teardown, route-change handling, what is not done, and the `AudioMerger` consequence. Read before changing `LiveMicCaptureEngine`.
- [user-reports.md](./user-reports.md) — table of all 20 reports (mic, output, app, macOS, version, symptom, link), plus related reports. Analyses "is it only built-in?", which apps, the symptom spectrum, and the data points that narrow the mechanism.
- [pull-requests.md](./pull-requests.md) — PRs #115, #118 and #129 in detail: diff contents, claims, review discussion, measurements, tradeoffs. Also the context PRs #94/#101, #109, #123, #127 and #130.
- [prior-experiments.md](./prior-experiments.md) — timeline from R1 to production; the 3-channel finding; observed channel counts (3 / 9 / 28; no 7 found); VPIO runs 1–4; Mic Mode and Voice Isolation; gotchas already learned; the fallback plan that was never executed.

## Open Questions / Gaps

- **No repo measurement exists of a plain (non-VP) AVAudioEngine tap's level on the built-in mic, idle vs. during a meeting.** The −48 dBFS "near-silent" result is from the **AVCaptureSession** path. The only non-VP AVAudioEngine number is javimoya's (−30 to −40 dBFS, metric unstated), and it is not directly comparable. Searched all `specs/research/audio/*` and `experiments/AudioLab/*`.
- **I found no 7-channel observation**, though the owner mentions a "7 channel array mix". The repo and threads show 3 (raw), 9 (VP tap; also a non-VP tap per #115) and 28 (VP on the iD24). Why #115 saw a **non-VP** 9-channel tap is unexplained. My inference is that it is 3 mics + 6 reference channels exposed by another VP client's tap streams; that is unverified.
- **Mechanism not established in-repo.** The evidence points away from the reclock as the root cause. It is consistent with the shared HAL input-processing mode ("chat flavors", Voice Isolation) and with VPIO touching every device's tap stream. It does not separate those from ducking or the aggregate device. This is for the VPIO-behaviour subtopic.
- **Non-built-in devices are thinly covered.** "AirPods/USB/headset are fine" comes from 3 anecdotes. The one detailed non-built-in report (iD24) **did** break. 13 of 20 reports don't name the mic. No report covers FaceTime or Safari/WebKit as the other app.
- **"About 5 PRs":** I found only 3 open PRs that change the VPIO mic path (#115, #118, #129), searching all PRs for "voice processing", "VPIO" and "microphone". The other two may be #94/#101 (merged VPIO startup fixes) or forks without PRs.
- **History before 2026-07-07 is squashed** (`2225fd1`). I could not date when production switched to VPIO, or when AudioLab's plain path became AVCaptureSession.
- No code was run and no hardware was tested in this subtopic. Everything is from reading the repo and the GitHub threads.

## Sources

Repo files at commit `1c0b182` (main, 2026-10-28):
- `Packages/AudioCapture/Sources/AudioCapture/LiveMicCaptureEngine.swift` — production VPIO engine (authoritative for current behaviour)
- `Packages/AudioCapture/Sources/AudioCapture/MicCaptureSession.swift` — channel-0 copy, ring, writer
- `Packages/AudioCapture/Sources/AudioCapture/AudioRecorder.swift` — start order, retries, `micLevel: 0`
- `Packages/AudioCapture/Sources/AudioCapture/VPIOFileHelper.swift`, `EncoderSettings.swift`, `CoreAudioHelpers.swift`
- `Packages/Transcription/Sources/Transcription/AudioMerger.swift` — sum and global-peak normalisation
- `specs/research/audio/README.md`, `phase9_validation_findings.md`, `mic_capture_level_findings.md` (2026-06-08/09), `hardware_debugging_workflow.md`, `display_audio_startup_failure.md`
- `experiments/AudioLab/NOTES.md`, `VALIDATION.md`, `Sources/MicCapture.swift`, `Sources/VPIOMicCapture.swift`, `Sources/RecordingCoordinator.swift`
- `specs/projects/stage_a_foundations/components/audio_capture.md:196-202` — stale "NOT VPIO" decision

GitHub (scosman/Biscotti, read 2026-10-28):
- [Issue #66](https://github.com/scosman/Biscotti/issues/66) — main bug and 9 comments (2026-08-27 → 2026-10-28)
- [Issue #91](https://github.com/scosman/Biscotti/issues/91) — duplicate with 9 comments of reports
- [PR #115](https://github.com/scosman/Biscotti/pull/115) — VPIO opt-out setting
- [PR #118](https://github.com/scosman/Biscotti/pull/118) — passive capture, plus javimoya's measurements
- [PR #129](https://github.com/scosman/Biscotti/pull/129) — restart in place; ducking and timing measurements
- [Issue #124](https://github.com/scosman/Biscotti/issues/124) — VP teardown crash and deadlock
- [Issue #116](https://github.com/scosman/Biscotti/issues/116) — input device picker request
- [PR #94](https://github.com/scosman/Biscotti/pull/94), [PR #101](https://github.com/scosman/Biscotti/pull/101) — VPIO startup recovery
- [PR #123](https://github.com/scosman/Biscotti/pull/123), [PR #109](https://github.com/scosman/Biscotti/pull/109) — system-track effects of output-rate changes
- [PR #127](https://github.com/scosman/Biscotti/pull/127) — VPIO AEC observed working; AirPods rate 'nope'
- [Issue #88](https://github.com/scosman/Biscotti/issues/88) — AirPods HFP output-rate change kills the system tap (context)

Apple docs (fetched 2026-10-28, used only to clarify the ducking API in the code):
- [AVAudioInputNode.voiceProcessingOtherAudioDuckingConfiguration](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration) — macOS 14+; the default is advanced ducking off, level `default`
- [AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/level) — cases `default`, `max`, `mid`, `min` (no "off")
