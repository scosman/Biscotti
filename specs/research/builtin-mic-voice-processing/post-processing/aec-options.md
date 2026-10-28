# Reference-based echo cancellation using the system-audio track

**Question:** can Biscotti remove speaker bleed from the mic track by using its own, separately captured system-audio track as the far-end reference, without touching the device or the meeting app? Which engines exist, what do they cost, and how would each fit Biscotti's pipeline?

**Short answer:** yes. Several shipping macOS meeting recorders already do it with Core Audio process taps or ScreenCaptureKit as the reference. The serious candidates are **WebRTC AEC3** (BSD-3, classical, mature, very cheap) and **LocalVQE** (Apache-2.0, neural, has its own alignment, and is now the engine two Swift recorders chose). Apple offers **no** API that runs its echo canceller offline or on a reference you supply. SpeexDSP and hand-rolled NLMS work as baselines only. DTLN-aec has been dropped by the teams that tried it in production.

Researched 2026-10-28. Failure modes (alignment, drift, nonlinear echo, double-talk, lossy reference) are covered in [`aec-failure-modes.md`](./aec-failure-modes.md).

---

## 1. Biscotti pipeline facts that constrain the choice

These come from the repo, not the web:

- **Tracks on disk.** Mic and system are written as two ADTS AAC-LC files, **24 kHz mono, 64 kbps** (`specs/research/audio/phase9_validation_findings.md` finding #5).
- **Alignment.** Both tracks share a host-clock t=0. The system engine prepends leading silence up to the mic's first-buffer anchor (`Packages/AudioCapture/Sources/AudioCapture/AudioRecorder.swift`). Either track writes silence for any gap over **100 ms** after a reconnect (`MicCaptureSession.swift`, `SystemGapFillWriter.swift`; `specs/research/audio/README.md` "Reconnect gap silence fill"). No per-buffer timestamp sidecar is written, so after decoding, the alignment is "same t=0, plus whatever the devices did since".
- **Current mic path.** Production captures the mic through VPIO (`LiveMicCaptureEngine.swift`: `setVoiceProcessingEnabled(true)`). Post-processing AEC matters for the **non-VPIO** path that issue #66 pushes towards.
- **Transcription.** `Packages/Transcription` decodes both files to 16 kHz mono and **sums** them in `AudioMerger.merge` (scaled down only if the peak exceeds 1.0). It then runs WhisperKit and SpeakerKit once on the merged array (`InProcessTranscriptionEngine.swift`). Mic-vs-system provenance is not used for speaker attribution today.

So post-processing has two possible homes:

| Home | What it sees | Pros | Cons |
|---|---|---|---|
| **(a) Capture time / near-real-time**, in `AudioCapture` before AAC encoding | 48 kHz float PCM from both engines, with host timestamps per buffer | No codec damage to the reference. Exact host times. Output can be a third `_mic_clean` track. | Touches the "rock-solid recorder" path, adds CPU during the meeting, and triggers the `ac_*` manual-test staleness rule. |
| **(b) Post-stop / offline**, in the Transcription XPC before `AudioMerger` | Decoded 24 kHz AAC of both tracks | Zero capture risk. Re-runnable with better engines later, because the raw files are kept. Fits "derived artifact" designs (MacParakeet, Anarlog). | The reference has been AAC-coded (limits linear cancellation, see failure-modes doc). Delay must be re-estimated from the audio. |

Recording latency costs a recorder nothing. That is why real-time is possible as well as offline, and why the "causality" objection in `mic_capture_level_findings.md` does not hold (see the failure-modes doc, §1).

---

## 2. Apple APIs: none usable for this

- **VoiceProcessingIO / AVAudioEngine voice processing is live-only.** The WWDC19 slides say voice processing is "Not supported in manual rendering mode", and the session states: "Voice processing is only available when rendering to an audio device, not a manual rendering mode." ([WWDC19 session 510](https://developer.apple.com/videos/play/wwdc2019/510/), [slides PDF](https://devstreaming-cdn.apple.com/videos/wwdc/2019/510v8txdlekug3npw2m/510/510_whats_new_in_avaudioengine.pdf?dl=1)). The `AVAudioIONode.setVoiceProcessingEnabled` header doc repeats this: "Voice processing is only supported when the engine is rendering to the audio device and not in the manual rendering mode" (quoted in the [objc2-avf-audio docs](https://docs.rs/objc2-avf-audio/latest/objc2_avf_audio/struct.AVAudioIONode.html)). VPIO's reference is whatever the device plays, so you cannot hand it Biscotti's recorded system track after the fact.
- **No other Apple AU does reference-based AEC.** `AUSoundIsolation` is a voice/background separator with no reference input (see [`noise-suppression-voice-isolation.md`](./noise-suppression-voice-isolation.md)). `AUAudioMix` (macOS 26) needs 4-channel FOA spatial input (WWDC25 session 251). The Apple SDK headers list no other echo unit.
- **Out of my lane, one line:** a Screenpipe maintainer reports that their VPIO path "cancels 0 dB because the VPIO output element is disabled and no far-end reference is rendered" ([screenpipe#4256 comment](https://github.com/screenpipe/screenpipe/issues/4256)). This conflicts with Biscotti's own hardware observation that VPIO with Voice Isolation reduced bleed. The VPIO subtopic should settle it.

---

## 3. WebRTC AEC3 (Audio Processing Module)

**What it is.** Google's current echo canceller, part of WebRTC's APM. Its parts are a matched-filter delay estimator, refined and coarse partitioned-block adaptive filters, an echo-path/ERLE model, a residual echo suppressor, comfort noise and a clock-drift detector. The APM also includes noise suppression, AGC2 and a high-pass filter.

**API shape** (quoted from `modules/audio_processing/include/audio_processing.h`, webrtc-sdk `m125_release` mirror):
- "APM operates on two audio streams on a frame-by-frame basis. Frames of the primary stream ... are passed to `ProcessStream()`. Frames of the reverse direction stream are passed to `ProcessReverseStream()`."
- "APM accepts only linear PCM audio data in chunks of ~10 ms ... and sample rates ranging from 8000 Hz to 384000 Hz." Internally AEC3 runs at full-band rates of 16, 32 or 48 kHz (`ValidFullBandRate` in `aec3_common.h`).
- `set_stream_delay_ms`: "Sets the `delay` in ms between ProcessReverseStream() receiving a far-end frame and ProcessStream() receiving a near-end frame containing the corresponding echo ... delay = (t_render - t_analyze) + (t_process - t_capture)".
- `Config::EchoCanceller` has `export_linear_aec_output`, and APM exposes "the most recently produced ~10 ms of the linear AEC output at a rate of 16 kHz". That linear output is useful when the result feeds an ASR rather than a listener (see the transcript doc).

**Delay and drift handling (from source, m125).** `EchoCanceller3Config::Delay` defaults: `default_delay = 5`, `down_sampling_factor = 4`, `num_filters = 5`, `delay_headroom_samples = 32`, `detect_pre_echo = true`, `use_external_delay_estimator = false`. With `kBlockSize = 64`, `kMatchedFilterWindowSizeSubBlocks = 32` and an alignment shift of 3/4 of the window, my arithmetic gives an estimator search span of about **2432 samples at 4 kHz ≈ 0.6 s** of reference-to-echo lag. This is a derived figure, not a documented one; a pure-Go 1:1 port verified detected delays from 4 ms to 500 ms against the C++ oracle ([go-mediatoolkit PR #5](https://github.com/daniel-sullivan/go-mediatoolkit/pull/5)). The linear filter spans `refined.length_blocks = 13` blocks (13 × 4 ms ≈ 52 ms of echo tail at 16 kHz band rate). `ClockdriftDetector` marks drift as probable or verified when consecutive delay estimates step by ±1 ([`clockdrift_detector.cc`](https://raw.githubusercontent.com/webrtc-sdk/webrtc/m125_release/modules/audio_processing/aec3/clockdrift_detector.cc)). It **detects** drift and re-estimates delay; it does not resample.

**License.** BSD-3-Clause, with WebRTC's additional patent grant (file headers).

**Integration paths on Apple silicon** (all native code bridged into Swift; none is a maintained first-party Swift package):

| Path | Notes | Source |
|---|---|---|
| freedesktop `webrtc-audio-processing` 2.x (PulseAudio's standalone repackaging of APM; **2.1 released 2025-01-22**; meson + abseil) | The upstream page says it is tested on Linux only. A 2021 commit added macOS/iOS framework deps. A fork exists that builds a macOS/iOS `xcframework` via meson cross-files. | [freedesktop page](https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/), [helloooideeeeea/webrtc-audio-processing](https://github.com/helloooideeeeea/webrtc-audio-processing) |
| `tonarino/webrtc-audio-processing` Rust crate | Wraps the freedesktop package. The `bundled` feature builds from source and needs meson, ninja and pkg-config (Homebrew instructions given). `experimental-aec3-config` exposes the full AEC3 config. | [README](https://github.com/tonarino/webrtc-audio-processing) |
| **Sonora**: pure-Rust port of APM (M145 plus 15 later upstream fixes) with a cbindgen C API (`sonora-ffi`), NEON SIMD, BSD-3 | Upstream's experimental neural residual echo estimator is not ported. The C++ suite (2400+ tests) passes against it. AI-assisted port, so judge maturity accordingly. | [dignifiedquire/sonora](https://github.com/dignifiedquire/sonora) |
| Vendored WebRTC checkout built with GN into a static lib plus a small C bridge | **Prismical** (MIT, Electron + native helper) does this. Contract: 48 kHz mono, 480-sample (10 ms) frames; render is ingested before capture; render holdback/timeout. | [amicalhq/prismical](https://github.com/amicalhq/prismical), [aec3 builder README](https://github.com/amicalhq/prismical/blob/main/packages/webrtc-aec3-builder/README.md) |
| Commercial: **Nonstrict RecordKit** (Swift SDK) | `.aec3(AEC3Config)`: "Captures system audio via Core Audio process taps and removes it from the microphone signal in real time" (macOS 14.2+). Presets: `.balanced` (48 kHz, no residual gate) and `.aggressive` (16 kHz, gate on). Vendor claim: "'aggressive': Disables near-end speech detection ... removes ~2 dB more echo but attenuates speech by 3-5 dB." Changelog 0.85.0 replaced `aec3Online/aec3Offline/aec3Both` with one case. | [guide](https://nonstrict.eu/recordkit/guides/echo-cancellation.html), [Electron type docs](https://nonstrict.eu/recordkit/api/electron/types/EchoCancellation.html), [changelog](https://nonstrict.eu/recordkit/changelog.html) |
| OpenWhispr (Electron) | Ships a "native WebRTC APM sidecar (meeting-aec-helper) built from webrtc-apm + abseil-cpp" plus transcript-level dedupe (commit 2026-04-14). | [commit 068280b](https://github.com/OpenWhispr/openwhispr/commit/068280ba86d50b99a040f9615ca6fa8cc445e885) |
| Standalone extraction | `Enaium/webrtc-aec3` builds `libwebrtc_aec3.dylib`. Its test runs 16 kHz far/near WAVs through AEC3 offline. | [Enaium/webrtc-aec3](https://github.com/Enaium/webrtc-aec3) |

**Real-time vs offline.** AEC3 is causal and frame-based. Offline use means calling `ProcessReverseStream(sys[i])` then `ProcessStream(mic[i])` for each 10 ms frame. The Enaium standalone test does exactly this on 16 kHz WAV files. RecordKit once had separate `aec3Online` and `aec3Offline` modes, but its changelog doesn't describe them.

**CPU.** Negligible on Apple silicon:
- Sonora's benchmark on an **Apple M4 Max**: C++ APM full pipeline at 48 kHz mono = **10.8 µs per 10 ms frame**; EC-only at 16 kHz = 1.2 µs. That is about 0.1% of one core or less ([BENCHMARKS.md](https://github.com/dignifiedquire/sonora/blob/main/BENCHMARKS.md)). The benchmark input content isn't stated, so treat these as lower bounds.
- The scalar pure-Go port runs ~306 µs per 10 ms at 48 kHz stereo (~32× real time).
- WebRTC added NEON paths for AEC3 with an "8 times complexity reduction" on ARM ([codereview 2834073005](https://codereview.webrtc.org/2834073005/)).

**Quality evidence (thin for this exact use).**
- On the AEC-Challenge synthetic validation set, AEC3's **linear filter alone** scored PESQ 1.28 (vs 1.24 unprocessed) and **6.29 dB ERLE** on single-talk far-end. That isolates the linear stage, without AEC3's suppressor ([Wang et al. 2021, arXiv 2102.08551](https://ar5iv.labs.arxiv.org/html/2102.08551)).
- The Go port's behavioural suite reports "26–32 dB echo removal with near-end speech preserved in double-talk" on synthetic scenarios.
- I found **no** published evaluation of AEC3 on MacBook-speaker → MacBook-mic echo with a process-tap reference. Vendor and project claims are the only evidence there.
- MacParakeet's plan lists AEC3 as the benchmark/fallback but had not run it as of its last update (U6 "REMAINING") ([plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md)).

**Verdict.** This is the most mature and cheapest option, with a permissive license and the right API shape. Its echo model is linear plus a heuristic residual suppressor, and its weak spots are nonlinear laptop-speaker echo and suppressor behaviour in double-talk. Shipping it means maintaining a native C++ (or Rust) build in the SPM graph.

---

## 4. LocalVQE (neural, GGML, Apache-2.0)

**What it is.** "Compact neural models for acoustic echo cancellation (AEC), noise suppression (NS), and dereverberation of 16 kHz speech, running on commodity CPUs in real time. Causal and streaming (256-sample hop, 16 ms latency)." It is a CPU-tuned derivative of Microsoft's DeepVQE (Interspeech 2023), run in C++ through GGML ([README](https://github.com/localai-org/LocalVQE), fetched 2026-10-28).

**Models** (README table; speed per 16 ms hop on a Ryzen 9 7900, 4 threads):

| Model | Does | Params | Speed | Notes |
|---|---|---:|---|---|
| v1.3 | AEC + NS + dereverb | 4.8 M | 3.2 ms, 5.0× RT | current joint model |
| v1.2 | AEC + NS + dereverb | 1.3 M | 1.7 ms, 8.9× RT | joint; 1 thread = 4.28 ms (3.7× RT) |
| **v1.4-AEC** | **echo only (keeps voice, noise, room)** | 203 K | 0.83 ms, 19× RT (1 thread: 1.29 ms, 12× RT) | "a classical adaptive filter followed by a small neural mask" |
| v1.4-AEC 2.7K | adaptive filter only, no mask | 2.7 K | 0.36 ms, 44× RT | "can't remove heavily reverberant echo" |

Peak RSS is ~17 MiB for v1.4-AEC. "Every model needs a far-end **reference** signal (a loopback of what your speakers play) in addition to the mic."

**Quality** (README, full 800-clip ICASSP 2022 AEC Challenge **blind test, real recordings**; AECMOS 1–5). Unprocessed echo MOS is 2.67 / 2.56 / 1.90 / 2.13 / 5.00 across the five scenarios.
- v1.4-AEC: double-talk echo 4.20, deg 2.45. Far-end single-talk echo 3.80, ERLE 14.6 dB. Near-end single-talk echo 4.99, deg **3.99** (near-end preserved).
- v1.2 joint: double-talk echo 4.72. Far-end single-talk ERLE 45.7 dB. Near-end single-talk deg 4.16.

**API.** `localvqe_new(path)`, `localvqe_process_f32(ctx, mic, ref, n, out)` for a whole clip, or `localvqe_process_frame_f32` per 256-sample hop. Builds as `liblocalvqe` (shared lib). Model hashes are checked at load against a built-in SHA256 allowlist. The CPU build produces several `libggml-cpu-*` variants selected at runtime, and the macOS OBS plugin is "expected to work" but only tested on Linux.

**Production evidence on macOS:**
- **MimicScribe** archived its DTLN-aec CoreML package and moved to LocalVQE, citing three reasons: "LocalVQE has built-in mic/reference time alignment, where DTLN-aec depends on the caller pairing the two streams exactly; it tolerated the clock drift that real capture pipelines produce between the mic and the system-audio reference; and it runs on CPU via ggml" ([dtln-aec-coreml README](https://github.com/MimicScribe/dtln-aec-coreml)).
- **Muesli** (MIT Swift macOS recorder) credits LocalVQE for "on-device acoustic echo cancellation for meeting transcription" and builds it with `scripts/build_localvqe.sh` ([README](https://github.com/Muesli-HQ/muesli)).
- **MacParakeet** (MIT Swift app) shipped a post-stop "cleaned mic" renderer around LocalVQE: decode both tracks → 16 kHz → align by recorded start offsets plus an adaptive cross-correlation delay estimator → LocalVQE → AAC `microphone-cleaned.m4a`. Raw tracks are kept as truth, and final STT falls back to raw mic on any failure ([plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md), [commit f5340c4](https://github.com/moona3k/macparakeet/commit/f5340c4d2f9cf3e3c62014a916e45cce15f3d0d4)). On their **synthetic** harness: v1.4-AEC got 35.6 dB far-end ERLE with near-end "retain ~1.0". The joint v1.2 "zeroes the near-end voice (retain 0.00)". Their own caveat: the harness's near-end is "decorrelated formant tones, not speech", so it "cannot positively certify double-talk fidelity for either model".
  - *Conflict worth noting:* LocalVQE's real-recording eval shows v1.2 preserving near-end single-talk (deg 4.16). That suggests MacParakeet's "v1.2 zeroes the voice" result is a tone-fixture artifact, not real behaviour. Neither source settles it for MacBook-speaker echo.
  - MacParakeet's issue #605 (speaker-mode bleed) was still open pending real speaker-mode QA (U9) at the plan's last update (2026-07-16).

**Gaps.** No Apple silicon timings in the README; the M-series would need a measurement. No standalone LocalVQE-vs-AEC3 comparison on the same data was found.

**Verdict.** This is the strongest open neural option today. It is permissively licensed, has a C API, runs on CPU (so it works in a headless XPC), has built-in alignment and drift tolerance (per MimicScribe), and is already shipped in Swift meeting recorders. v1.4-AEC (echo-only) is the right family for an ASR pipeline, because the joint models also denoise, and denoising tends to hurt Whisper (see the NS doc).

---

## 5. DTLN-aec (neural, MIT) and its ports

- **Model.** A dual-signal transformation LSTM, **3rd place in the ICASSP 2021 AEC Challenge**, at 16 kHz. Three sizes (128/256/512 LSTM units; 1.8M/3.9M/10.4M params). TF-Lite weights, MIT license ([breizhn/DTLN-aec](https://github.com/breizhn/DTLN-aec)). On the challenge's blind test it beat the baseline by about 0.3 MOS: far-end single-talk echo MOS 4.46 vs 4.09 clean, double-talk echo 4.34 vs 3.89. Near-end single-talk was unchanged (3.98 vs 3.99) ([Westhausen & Meyer, ICASSP 2021](https://ar5iv.labs.arxiv.org/html/2010.14337)).
- **Swift/CoreML port** `MimicScribe/dtln-aec-coreml` (macOS 13+, SPM, async API, `feedFarEnd` / `processNearEnd` at 16 kHz). Claims ~32 ms latency and 0.07 ms average per 8 ms frame on M1 (256-unit). **Archived.** The authors replaced it with LocalVQE (reasons quoted above) and note the CoreML models "would only run on the Neural Engine, which blocks headless use".
- **Anarlog/Hyprnote** ships DTLN-style ONNX AEC models (`crates/aec`, features `128` / `256` / `512`) with a reference aligner and "residual linear echo cancellation after the neural processor" ([anarlog crates/aec Cargo.toml](https://github.com/fastrepl/anarlog/blob/main/crates/aec/Cargo.toml); architecture summary from [MacParakeet's prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md)).
- **Stone** (Electron note-taker) runs DTLN-aec through ONNX Runtime **offline after the meeting**. "The first version of the canceller did almost nothing" until they added envelope cross-correlation alignment (±200 ms at 10 ms resolution). After that: "real speaker bleed is reduced by about 14 dB, and clean speech passes through unchanged" ([blog, 2026-09-17](https://peritissimus.com/blog/local-meeting-transcription-whisper-cpp)).

**Verdict.** It works, but only with exact alignment that the caller has to provide. It has been superseded in the Swift ecosystem by LocalVQE.

---

## 6. Classical baselines: SpeexDSP MDF and hand-rolled NLMS/FDAF

- **SpeexDSP echo canceller** (BSD, `speex_echo_state_init(frame_size, filter_length)`). Its header says the frame "should correspond to 10-20 ms" and the filter length "should generally correspond to 100-500 ms" ([speex_echo.h](https://github.com/xiph/speexdsp/blob/master/include/speex/speex_echo.h)). The Speex manual is blunt:
  - "Using a different soundcard to do the capture and playback will not work ... The only exception to that is if the two cards can be made to have their sampling clock 'locked' on the same clock source. If not, the clocks will always have a small amount of drift, which will prevent the echo canceller from adapting."
  - "Non-linear distortion cannot (by definition) be modeled by the linear adaptive filter used in the echo canceller and thus cannot be cancelled." ([Speex manual](https://www.speex.org/docs/manual/speex-manual.pdf))
  
  Biscotti's tracks come from different devices (mic vs output tap aggregate) in the general case, so Speex would need external drift correction.
- **NLMS/FDAF.** MacParakeet's first shipped software AEC was an NLMS (`MeetingSoftwareAEC`). Their measurement harness found that "an aligned oracle reaches ~56 dB ERLE; a 2.5 ms (40-sample) misalignment collapses it to ~-3 dB" ([PR #638](https://github.com/moona3k/macparakeet/pull/638)). The `corti-aec` Rust crate implements FDAF/NLMS with double-talk gating, delay search and residual suppression (per [MacParakeet's prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md); I did not read Corti's source).

**Verdict.** Useful as a test baseline and to sanity-check alignment. Not worth shipping over AEC3 or LocalVQE.

---

## 7. Comparison

| Engine | License | Swift / Apple-silicon path | RT / offline | CPU (best evidence) | Alignment & drift | Echo model | Main risk |
|---|---|---|---|---|---|---|---|
| **WebRTC AEC3** | BSD-3 (+ patent grant) | C++ via freedesktop meson build, Sonora Rust/C API, or vendored GN build → SPM C target / xcframework | Both (frame-locked) | ~0.1% core on M4 Max (Sonora bench) | Built-in delay estimator (~0.6 s span, derived); drift detection, no resampling | Linear + residual suppressor | Nonlinear laptop echo; double-talk suppressor tuning; native build upkeep |
| **LocalVQE v1.4-AEC** | Apache-2.0 (weights trained on CC BY 4.0 challenge data) | C API `liblocalvqe.dylib` + GGUF; Swift prior art (Muesli, MacParakeet) | Both (256-sample hop) | 1.29 ms / 16 ms hop single-thread on Zen4 (~12× RT); no Apple numbers | Built-in alignment; tolerated drift (MimicScribe) | Adaptive filter + neural mask | Newer and less proven; GGUF/dylib packaging and notarization |
| LocalVQE v1.2/v1.3 joint | Apache-2.0 | same | Both | 1.7–3.2 ms / hop (4 threads) | same | AEC + NS + dereverb | Denoising may hurt Whisper; MacParakeet saw near-end loss (synthetic) |
| DTLN-aec | MIT | CoreML (archived, ANE-only) or ONNX | Both | <2 ms / 8 ms frame (M1, ANE) | **None**: caller must align exactly | Neural mask | Alignment and drift fragility |
| SpeexDSP | BSD | trivial C target | Both | very low | None; drift breaks it | Linear | Drift, nonlinearity, double-talk |
| Apple VPIO | system | — | **Live only, own playback reference** | — | — | — | Not applicable to post-processing |
