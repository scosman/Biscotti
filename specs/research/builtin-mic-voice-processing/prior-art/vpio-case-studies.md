# VPIO in other macOS recorders: who shipped it, what broke, what they did instead

**Researched:** 2026-10-28. **Scope:** open-source (and a few closed-source with public engineering notes) macOS apps that turned on Apple voice processing (`AVAudioInputNode.setVoiceProcessingEnabled(true)` / `kAudioUnitSubType_VoiceProcessingIO`) for a mic that records *alongside* a call. Code was read from shallow clones at the commits listed; issue and PR text was read from GitHub.

**Short version:** The same bug as Biscotti issue #66 shows up across the field. Every OSS meeting recorder I found that shipped VPIO on by default for the meeting mic turned it off again within days or weeks. Their reported side effects match ours: the call app's outgoing voice goes quiet or muffled, other apps' playback is ducked, and in-process capture breaks. No project found a combination of VPIO knobs that made it safe, and none still ships VPIO on by default for meeting recording. The two that still use VPIO gate it: one by explicit user consent after detecting a quiet mic, one on a narrow device and format condition.

---

## 1. MacParakeet (moona3k/macparakeet): the most fully documented case

Swift 6, GPL-3.0, macOS 14.2+. Read at `590b6c25` (2026-10-23). The project keeps its own research and plan records in the repo, and they are unusually candid.

**Timeline** (from [`docs/research/vpio-process-tap-conflict.md`](https://github.com/moona3k/macparakeet/blob/main/docs/research/vpio-process-tap-conflict.md) and [`plans/completed/2026-05-nab-feedback-asap-bugs.md`](https://github.com/moona3k/macparakeet/blob/main/plans/completed/2026-05-nab-feedback-asap-bugs.md)):

| Date | Change | Outcome |
|---|---|---|
| 2026-04-07 (`118d7e6f`) | "remove VP and add joined dual-stream pipeline" (raw mic, experimental software AEC) | baseline |
| 2026-04-10 (`97134e9b`) | "Refactor meeting recording to VPIO-first pipeline", `.vpioPreferred` default | motivated by speaker bleed creating phantom "Me" text |
| 2026-04-11 | User reports empty `system.m4a` (557 bytes, header only) | **VPIO in the same process silenced their Core Audio process tap.** VPIO dropped |
| 2026-04-29 | System audio moved from a process tap to ScreenCaptureKit so VPIO could stay on the mic | VPIO preferred again |
| 2026-05-14 | Live Zoom report (below) | **default flipped to `.raw`** (`92c3dfdfb`) |
| 2026-05-22 to 2026-07-16 | Software echo suppression (LocalVQE), post-stop "cleaned mic" artifact | shipped; real speaker-mode QA still open (#605) |

**The 2026-05-14 Zoom report** is our symptom, verbatim from the plan:

> "When MacParakeet meeting recording starts, the user's voice heard by the other Zoom participant becomes much quieter/muffled. Pausing or stopping the recording restores the voice. This was observed in both directions during the call: Daniel's voice dropped when Daniel started recording, and Nab's voice dropped when Nab started recording."

Points to note:

- **Disabling ducking did not help.** The plan says `MicrophoneEnginePlatform` "already suppresses VPIO 'other audio' ducking, but this report suggests VPIO/voice processing may still affect the active conferencing app's mic path on real Zoom calls."
- The log showed the VPIO format `sr=48000 ch=9`. That is the same 9-channel duplex layout Biscotti's AudioLab saw.
- Their **unit tests did not catch it**. "These tests do **not** cover the external multi-app interaction where Zoom and MacParakeet use the same physical mic and Zoom participants judge the outgoing voice quality." Their acceptance criterion became "validated with a real two-party call, not only unit tests."
- **Their mechanism hypothesis** (2026-06-10, [`plans/completed/2026-05-meeting-neural-echo-suppression.md`](https://github.com/moona3k/macparakeet/blob/main/plans/completed/2026-05-meeting-neural-echo-suppression.md)): "VPIO AGC can write the shared hardware input gain other apps inherit, the likely mechanism behind the 2026-05-14 'muffled outgoing mic' finding." In response they set `isVoiceProcessingAGCEnabled = false` in the (now opt-in) VPIO path. They did not re-test VPIO with AGC off on a live call, so this fix is **unvalidated**. *(Cross-reference: Biscotti measured the shared input volume scalar at 0.27 during a Meet call against 0.67 idle. See `specs/research/audio/mic_capture_level_findings.md`.)*

**The in-process tap conflict** (2026-04-11, observed on macOS 15, built-in mic and speakers):

- VPIO on, meeting started first: mic fine, system tap silent. VPIO on, dictation started first: both mic and system silent. VPIO off: every ordering works.
- In the failure state, HAL enumeration showed `VPAUAggregateAudioDevice` and `CADefaultDeviceAggregate-<PID>-<N>` virtual devices that "persisted after the `MicrophoneCapture` `AVAudioEngine` was stopped and deallocated" and disappeared only at process exit.
- Starting the tap before enabling VPIO did not fix it; both streams went silent.
- Their wording of the mechanism, after an independent review, is "VPIO activation introduces process-scoped aggregate-device state … that alters HAL device topology or selection behavior in ways that cause Core Audio process taps … to bind to the wrong or unstable device chain." They label this an unproven hypothesis.
- *Relevance to Biscotti:* Biscotti runs a process tap and VPIO in the same process. The internal-evidence subtopic should check whether Biscotti's system track ever goes silent while VPIO is on. Biscotti's AudioLab runs reported a working tap, so this conflict may depend on the version or on the order operations happen in.

**What they replaced VPIO with** ([`plans/active/2026-06-28-meeting-aec-full-close.md`](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md)):

- Raw mic plus system audio from ScreenCaptureKit, both kept as raw source files.
- A software echo suppressor: LocalVQE (GGML, 16 kHz, 256-sample hop) with an **adaptive delay estimator** (normalized cross-correlation). Their harness found that "a 2.5 ms misalignment destroys cancellation", and that a 600-sample bulk delay gave −2.7 dB uncorrected against 56.5 dB once estimated. All of this is synthetic.
- Model choice: they picked echo-only `localvqe-v1.4-aec-200K` because the joint `v1.2` model "zeroes the near-end voice (retain 0.00) while v1.4 preserves it (retain ~1.0) at 35.6 dB ERLE" (synthetic harness).
- After stop, they render a `microphone-cleaned.m4a` and final STT prefers it. Raw remains the fallback when timing or assets fail.
- Transcript-layer safety nets: a live "system RMS dominates mic" chunk gate, and a final reconciler that drops runs of 5 or more mic words that fuzzy-match at least 80% of simultaneous remote words.

---

## 2. Transcripted (r3dbars/transcripted): VPIO for one release, then consent-gated

Swift, macOS. Read at `91463e9a` (2026-10-26). Issue [#500](https://github.com/r3dbars/transcripted/issues/500) (opened 2026-04-24, macOS 26.3.1): *"If I'm in a meeting and the meeting software uses the device microphone, the recording in Transcripted using my internal microphone is a lot quieter."* The reporter saw this with an empty Google Meet and with the native WhatsApp app.

| Version (date) | Change ([CHANGELOG](https://github.com/r3dbars/transcripted/blob/main/CHANGELOG.md)) | Result |
|---|---|---|
| 1.1.24 (2026-04-24) | "VPIO enabled on meeting mic capture to fix Safari/Firefox meeting audio sounding quiet" | Mic level fixed. Reporter: "the system audio is a lot quieter … not just quieter in the recording but also via the sound output." Maintainer: "It messed up a ton of meeting recording with Zoom and other apps so I had to undo this" |
| 1.1.25 | "VPIO is now off by default … real-time software AGC handling levels instead" | linear level drops recovered; voice-mode-gated speech not recovered |
| 1.1.47 (2026-06-08) | downmix fix (#959: a stereo mic with a silent second channel halved speech); AGC cap 12× → 25× (#960) | |
| 1.1.48 (2026-06-13) | [PR #1075](https://github.com/r3dbars/transcripted/pull/1075): live detection of a quiet mic plus an in-meeting **"Boost Mic"** prompt that turns VPIO on for that meeting only | defaults unchanged (VPIO off) |
| ≥1.1.63 | Boost no longer saves as a preference: "before 1.1.63 it did, which left call audio quieter in every later meeting (Matthew) and fought Zoom for the mic (Don)" | |

**Their VPIO knob settings** (`Sources/TranscriptedCore/Audio/Audio+VoiceProcessing.swift`): `isVoiceProcessingAGCEnabled = true`, `voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`. In their words, `.min` "is documented as the lowest level, not zero, and the v1.1.24 attempt audibly dimmed Zoom playback" (PR #1075).

**Their app-specific rule** (`Sources/Support/CallAppMicrophoneSharingMonitor.swift`, `MicrophoneSharingPolicy`):

> "Desktop call apps that run their own voice processing on the mic. Apple voice processing in Transcripted fights them for the shared mic (Zoom lost the user's voice) and makes their call audio quieter, so one open at start, or launched during a meeting, keeps Transcripted on software autogain."

The listed bundle IDs are `us.zoom.xos`, `com.microsoft.teams`, `com.microsoft.teams2`, Webex (3 IDs) and `com.apple.FaceTime`, plus the helper processes `us.zoom.CptHost` and `com.apple.avconferenced`. "Browsers stay out on purpose: a Safari or Firefox call is the case Boost Mic exists for." Slack and Discord are left out because "they are open all day."

**Their explanation of the quiet mic.** This is a claim, not verified here:

> "When Safari or Firefox (WebRTC), the native WhatsApp app, or other call software holds the mic in macOS voice/communication mode, every other client — Transcripted included — receives an echo-cancelled, noise-gated copy of the mic. That processing is lossy and nonlinear. No amount of gain can bring back speech the OS already gated out."

They also report that "chromium based browsers work fine … firefox and safari have the web rtc issue". That is one developer's test, not a matrix. *This conflicts with Biscotti's own measurement* (the raw 3-channel array taps at about −48 dBFS, with no evidence of gating). Both cases could be true at once: a raw array copy for some clients and a processed copy for others. The VPIO subtopic should resolve it.

**Validation status, as they report it themselves** ([`docs/qa-issue-500-meeting-audio.md`](https://github.com/r3dbars/transcripted/blob/main/docs/qa-issue-500-meeting-audio.md), 2026-07-03): "Treat #500 as code-complete-but-not-manually-validated." Their Safari/Firefox/Chrome Meet × Zoom × built-in/Bluetooth/USB matrix is still an unfilled template. [`docs/qa-meeting-cross-app-crossover.md`](https://github.com/r3dbars/transcripted/blob/main/docs/qa-meeting-cross-app-crossover.md) has a good A/B protocol for "does our app change what the other participant hears", one Biscotti could reuse.

---

## 3. OpenOats (yazinsai/OpenOats): VPIO for one day

Swift, macOS. Read at `b27bf015` (2026-10-27).

- [PR #89](https://github.com/yazinsai/OpenOats/pull/89) / commit `f8550a5` (2026-03-20): `setVoiceProcessingEnabled(true)` on by default "to cancel speaker echo that causes duplicate transcription". The PR's own test plan checkboxes were unticked.
- [PR #103](https://github.com/yazinsai/OpenOats/pull/103) / commit `a8fc6a8` (2026-03-21, release 1.14.2): forced off. "Voice processing (`setVoiceProcessingEnabled`) conflicts with system audio capture on macOS, causing CoreAudio aggregate-device reconfiguration that stalls the mic stream." Current code: `let useAEC = false` (`TranscriptionEngine.swift:529`). The Settings toggle remains but is overridden.
- What replaced it is transcript-level dedup only: `AcousticEchoFilter.swift`, which drops a mic utterance if it matches a system utterance within 1.75 s at Jaccard ≥ 0.78, with at least 4 words and 20 characters. System audio comes from a Core Audio process tap.

---

## 4. Vext (muvon.io): removed VPIO because it "poisoned" the mic

Closed source; the vendor's engineering blog, [*Vext 1.2.0*](https://muvon.io/blog/vext-1-2-0-two-pass-diarization-and-five-languages) (2026, exact date not shown on the page):

> "Turn it on in Vext, and every other app reading the same microphone — Zoom, FaceTime, OBS, every recorder — sees AGC and noise suppression applied to their feed too. The user's voice sounds distant and gain-reduced in the call they're actually in. … The correct answer is 'don't use it here at all.' … 1.2.0 removes the call."

This is a vendor statement without measurements, but it describes our exact symptom and names Zoom and FaceTime.

---

## 5. Humla (michaelwilhelmsen/humla): rejected VPIO up front

Tauri + Swift sidecar, MIT. Read at `c2b8aa10` (2026-10-27). In `audio-capture/Sources/audio-capture/main.swift:788`:

> "NOTE: do NOT call `input.setVoiceProcessingEnabled(true)`. It enables hardware AEC, but the voice-processing IO unit takes over the audio device for *both* directions, which ducks the system output (you can't hear the other person on a call). Echo-cancel the mic in a post-stop dedup pass instead"

What they do instead is an **offline reference-based canceller** (`src-tauri/crates/echo-probe/src/aec.rs`): per-window bulk delay from cross-correlation, then a SpeexDSP-style MDF partitioned-block adaptive filter, then residual Wiener suppression, run in two passes. On top of that, a per-voice check drops diarized mic "voices" that are almost never heard while the system stream is silent. Their measured result, on an M1 Max MacBook Pro in a real room ([`docs/research/stream-alignment-and-echo.md`](https://github.com/michaelwilhelmsen/humla/blob/main/docs/research/stream-alignment-and-echo.md), 2026-09-24): "The canceller removes 17–21 dB of echo in a real room (R1) and leaves the user alone untouched." They also found the mic-to-system lag was mostly **capture start offset** (296 ms on R1) and only about 28 ms acoustic and output path, and that it varies per take, so "a fixed correction is wrong".

---

## 6. Screenpipe (screenpipe/screenpipe): VPIO opt-in, isolated in a child process, measured 0 dB

Rust, read at `6e0d922c` (2026-10-28).

- `AecMode` defaults to `Off` (`crates/screenpipe-config/src/recording.rs:964`). The options are `Screenpipe` (software), `Macos` (VPIO, "[experimental] … Ignored on … non-default input devices"), and `Windows`.
- The VPIO mode runs **in a separate child process** (`crates/screenpipe-audio/src/core/vpio_process.rs`): "CoreAudio calls cannot be cancelled by Tokio; process ownership lets teardown kill and reap a wedged unit."
- **VPIO dead streams.** In commit `bfd9809` ([#4519](https://github.com/screenpipe/screenpipe/commit/bfd9809443d485f7dce5491902a1eb586cdef22c), 2026-06-24), VPIO "can create an input stream successfully ('AEC initialized') yet never deliver a single sample". It was "observed with heavy virtual-audio-device setups + AirPods connect/disconnect churn (reproduced live: 10x 'stream dead' in a day, 15h of no audio captured)". The fix demotes a device to plain HAL after 3 deaths within 120 s (`device/vpio_health.rs`).
- **VPIO removed about 0 dB of echo** in their configuration. [Issue #3938](https://github.com/screenpipe/screenpipe/issues/3938) (2026-06-09) reports ERLE of about 0 dB at 96 kHz and 48 kHz, shared or exclusive. Their cpal fork configures VPIO input-only (output element disabled). Turning the output element on "woke up VPIO's noise suppression (ambient floor dropped ~3.8x) but the echo was untouched". Rendering their captured system audio into the VPIO output element with `MuteOutput=1` ([screenpipe/cpal#4](https://github.com/screenpipe/cpal/pull/4)) made correlation go *up* (4.1 → 6.0, "echo went UP, not down"), and they suspect the mute did not take effect. Their conclusion: "Apple VPIO subtracts a reference that *the app must render through the VPIO unit's own output element*. macOS never hands you the system mix." *(This is their inference. It conflicts with MacParakeet's planning assumption that VPIO references "the default output device mix". The VPIO subtopic owns the question.)*
- A home-grown FDAF/NLMS canceller ([PR #4379](https://github.com/screenpipe/screenpipe/pull/4379), closed 2026-06-29) **failed on real echo**. It got 39 dB on synthetic tests but −1.1 to +0.25 dB on real recordings; the author wrote that "the synthetic tests 'lied'". Their hypothesis is that MacBook mic processing makes the echo nonlinear relative to the reference.
- Shipped instead: [PR #4554](https://github.com/screenpipe/screenpipe/pull/4554) (merged 2026-07-01, app v2.5.89), "Screenpipe software AEC" using **Sonora (a Rust port of WebRTC AEC3)** with high-pass filter, NS VeryHigh and AGC2 at 16 kHz mono (`core/aec.rs`). It is opt-in. The PR's CPU/RAM validation box is unticked, and no real-hardware ERLE figure was published for it.
- Duplicate transcripts on speakers are a recurring bug there (#3228, #3432, #3826, [#4256](https://github.com/screenpipe/screenpipe/issues/4256)). The interim mitigation hid them in the display layer: drop a mic block if 60% or more of its words appear in an output block within 6 s.

---

## 7. Smaller and dictation-side data points

| App | What happened | Source |
|---|---|---|
| **TypeWhisper** (dictation/recorder) | Turns VPIO on **only when the default input is built-in AND the input format is 3 channels**, i.e. while FaceTime holds the array. Sets AGC on, `isVoiceProcessingBypassed=false`. Merged 2026-06-19 and still in code at `8560dd4c`. No public report either way on whether it disturbs FaceTime | [PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755); `TypeWhisper/Services/AudioRecorderService.swift:1315` |
| **picrophone** (voice agent) | VPIO switched the input to "3–7 ch, 48kHz" and delivered silence without a pulled output graph. "Side effect: turning on voice processing put the shared audio device into a voice-chat mode that ducked other system audio." Reverted | [issue #13](https://github.com/zenyui/picrophone/issues/13) (2026-07-05) |
| **quill** (CLI recorder) | VPIO **on by default**, ducking `.min`. "The live voice unit makes macOS treat the session like a call and duck all other audio." Explicit mono client format, because "a 9-channel device yielded digital silence". 1-second liveness check falls back to raw. No call-breakage reports found, but no evidence of testing on a call either | [MicRecorder.swift](https://github.com/digimata/quill/blob/8ab6ebb6/Sources/quill/Audio/MicRecorder.swift) |
| **lazy-take-notes** | Open proposal to adopt VPIO for AEC; not implemented | [issue #1](https://github.com/CJHwong/lazy-take-notes/issues/1) (2026-02-22) |
| **eqMac** (system EQ driver) | The reverse direction. When a call app engages voice processing, "Apple … creat[es] hidden aggregate device and does a bunch of voice processing stuff in the background", and with eqMac's driver present it also "'duck[s]' the Microphone volume" | [issue #741](https://github.com/bitgapp/eqMac/issues/741) (2022–2023) |
| **minutes** (silverstein) | Uses a VoiceProcessingIO unit, but only for a **voice-agent** feature that both plays and records ("one VoiceProcessingIO unit for both microphone and speaker"). Not used for meeting capture | `crates/core/src/voice_live/voice_io.rs`; `docs/rfcs/0007-voice-live.md` |

Context that explains why call apps behave the way they do (details belong to the VPIO subtopic):

- WebKit: "On macOS, only one VPIO unit can run at a time. This means that we can capture with echo cancellation only one microphone at a time." When a second echo-cancelled capture starts, Safari migrates the existing capture to a non-VPIO HAL unit ([WebKit bug 301870 / commit f8af49f](https://github.com/philn/WebKit/commit/f8af49f640cc922f066d0e349ff119a5ea6a7eb2), 2025-11-17).
- LiveKit's Swift SDK defaults to `.automatic`, which prefers "platform Voice Processing I/O" ([Docs/audio.md](https://github.com/livekit/client-sdk-swift/blob/main/Docs/audio.md)). So many native call apps are VPIO clients themselves.
- CallLane's write-up measures about 20 dB ducking of all other audio when Zoom engages voice processing: "FaceTime, WhatsApp and Microsoft Teams calls do the same" ([calllane.app](https://calllane.app/zoom-lowers-other-audio-mac), tested on macOS 27.0.1, 2026-10-21).

---

## Pattern across the cases

| App | VPIO default shipped? | Reverted? | Reported side effect | Replacement |
|---|---|---|---|---|
| MacParakeet | yes (2026-04-10, 2026-04-29) | yes (2026-04-11, 2026-05-14) | in-process tap silenced; **Zoom outgoing voice quieter/muffled, both users** | raw + LocalVQE post-stop cleaned mic + transcript reconciler |
| Transcripted | yes (1.1.24) | yes (1.1.25) | **other apps' playback quieter; "Zoom lost the user's voice"** | software AGC (25×) + consent-gated per-meeting VPIO, never when Zoom/Teams/Webex/FaceTime runs |
| OpenOats | yes (PR #89, 2026-03-20) | yes (PR #103 / 1.14.2, next day) | mic stream stalls ("aggregate-device reconfiguration") | transcript text-similarity dedup |
| Vext | yes (before 1.2.0) | yes (1.2.0) | **other apps' mic gets AGC/NS; voice "distant and gain-reduced" in the call** | none needed (separate system tap) |
| Screenpipe | opt-in only | n/a | dead streams; ~0 dB ERLE in their setup | Sonora AEC3 software AEC (opt-in) |
| Humla | never | n/a | (anticipated ducking) | offline MDF AEC + per-voice echo check |
| TypeWhisper | conditional (built-in + 3 ch) | no | none reported | strongest-channel downmix |

*Inference:* VPIO causes three separate harms. The fix each project tried addresses at most one of them. Ducking off and `.min` does not stop the outgoing-voice degradation (MacParakeet, Transcripted). AGC off is unvalidated (MacParakeet). Running VPIO in a separate process avoids in-process tap breakage (Screenpipe) but not the device-level effects. No project reports a VPIO configuration that left a concurrent Zoom, Teams or FaceTime call unaffected.
