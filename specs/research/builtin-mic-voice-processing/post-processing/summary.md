# Post-processing: echo cancellation, voice isolation and levelling after capture

## Bottom Line

Yes. Biscotti can clean the mic track after capture, using its own system-audio track as the echo-cancellation reference, without touching the device or the meeting app. Apple has **no** offline or bring-your-own-reference AEC (voice processing is live-only). Two open engines fit, and other macOS meeting recorders already ship both patterns: **WebRTC AEC3** (BSD-3, classical, ~0.1% of a core) and **LocalVQE v1.4-AEC** (Apache-2.0, neural, built-in alignment, already used by Swift recorders). Either can run offline in the Transcription XPC on the decoded tracks, or near-real-time before AAC encoding.

What decides success is **alignment between the tracks**: a 2.5 ms error can wipe out a linear canceller. After that come clock drift, gap-fill jumps, nonlinear MacBook-speaker DSP, double-talk, and an AAC-coded reference that probably caps linear cancellation.

Reference-free tools (Apple `AUSoundIsolation`, DeepFilterNet, RNNoise, Krisp, ai-coustics, Koala) remove noise, not the remote *speech* that bleeds in, and denoising before Whisper usually **raises** WER.

For Biscotti's *current* transcription design, which sums both tracks into one stream, bleed doesn't create duplicate words. The bigger post-capture fix there is **echo-aware per-track loudness normalization**: Whisper is not scale-invariant, and `AudioMerger` sums the tracks with no per-track gain. AEC becomes necessary for clean mic playback, for mic-vs-system "me" attribution or per-track transcription, and for long-delay outputs such as AirPlay.

## Key Findings

- **Apple has no offline echo canceller.** "Voice processing is only available when rendering to an audio device, not a manual rendering mode" ([WWDC19 510](https://developer.apple.com/videos/play/wwdc2019/510/)). VPIO's reference is the device's own playback, so it cannot be fed Biscotti's recorded system track. `AUAudioMix` (macOS 26) needs 4-channel FOA input ([WWDC25 251](https://developer.apple.com/videos/play/wwdc2025/251/)).

- **The repo's "causality" objection to reference AEC is wrong for a recorder.** `mic_capture_level_findings.md` says the tap reference arrives after the echo, which makes AEC impractical. That doesn't hold:
  - Offline, both full tracks exist.
  - Live, a recorder can buffer the mic until the matching reference arrives. Shipping examples: RecordKit's AEC3 on process taps ([guide](https://nonstrict.eu/recordkit/guides/echo-cancellation.html)), Prismical's AEC3 bridge with render holdback, Muesli and MacParakeet's LocalVQE paths ([MacParakeet prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md)).

- **WebRTC AEC3 is mature, cheap and permissive.**
  - BSD-3. Built-in matched-filter delay estimator with a span of roughly 0.6 s (my arithmetic from m125 constants), plus a drift detector and a residual suppressor ([config header](https://raw.githubusercontent.com/webrtc-sdk/webrtc/m125_release/api/audio/echo_canceller3_config.h)).
  - About 10.8 µs per 10 ms frame (48 kHz mono, full APM) on an M4 Max ([Sonora benchmarks](https://github.com/dignifiedquire/sonora/blob/main/BENCHMARKS.md)).
  - Integration means native code: freedesktop meson build, the Sonora Rust/C API, or a vendored GN build.
  - There is no published evaluation on MacBook speaker echo with a tap reference.

- **LocalVQE is the strongest open neural option** ([README](https://github.com/localai-org/LocalVQE)).
  - v1.4-AEC is echo-only: 203K params, 1.29 ms per 16 ms hop single-threaded on Zen4, Apache-2.0, C API.
  - On the real-recording ICASSP 2022 blind set: far-end echo MOS 3.80 vs 2.67 unprocessed, and near-end single-talk is kept (degradation MOS 3.99).
  - MimicScribe dropped DTLN-aec for LocalVQE because LocalVQE "has built-in mic/reference time alignment", "tolerated the clock drift", and runs on CPU rather than ANE-only CoreML ([dtln-aec-coreml](https://github.com/MimicScribe/dtln-aec-coreml)).
  - MacParakeet ships an offline LocalVQE "cleaned mic" artifact that falls back to the raw mic ([plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md)).

- **Alignment is load-bearing.**
  - MacParakeet: "an aligned oracle reaches ~56 dB ERLE; a 2.5 ms (40-sample) misalignment collapses it to ~-3 dB" ([PR #638](https://github.com/moona3k/macparakeet/pull/638)).
  - Stone's offline DTLN-aec "did almost nothing" until it cross-correlated the tracks (±200 ms), then cut bleed by ~14 dB ([blog](https://peritissimus.com/blog/local-meeting-transcription-whisper-cpp)).
  - Biscotti's files share only a host-time t=0, plus gap fills of more than 100 ms, so an offline aligner must re-estimate delay per segment.
  - Consumer clocks drift 50–200 ppm ([Opale](https://www.opalesystems.com/Tech-Blog/66-A-clock-drift-study-in-Speech-Quality-Assessment-world.en.htm)).
  - AirPlay adds ~2 s, beyond AEC3's search span.

- **MacBook speaker echo is likely nonlinear relative to the tap.** macOS applies "psychoacoustic bass enhancement, dynamic range compression, and spatialisation" plus amp thermal protection to the built-in speakers ([asahi-audio](https://github.com/AsahiLinux/asahi-audio), [speakersafetyd](https://github.com/AsahiLinux/speakersafetyd)). Linear AEC "cannot" cancel nonlinear distortion ([Speex manual](https://www.speex.org/docs/manual/speex-manual.pdf)), so a residual suppressor or neural mask is needed. That the tap is pre-DSP is an inference.

- **Double-talk is the hard case for every approach.**
  - RecordKit's aggressive AEC3 preset "attenuates speech by 3-5 dB".
  - The AEC Challenge still lists near-end double-talk degradation as among the largest open gaps ([ICASSP 2023 paper](https://arxiv.org/html/2309.12553)).
  - Text-match dedup "broke as soon as two people talked at once" (Stone).

- **The AAC-coded reference is a likely ceiling (offline only).** Codec nonlinearity on the echo path capped linear ERLE near ~16 dB for low-rate speech codecs ([EUSIPCO 2006](https://www.eurasip.org/Proceedings/Eusipco/Eusipco2006/papers/1568980841.pdf)). The effect of 64 kbps AAC is unmeasured. Fallbacks are capture-time AEC or a PCM reference scratch file.

- **Voice isolation and NS don't remove speech bleed, and they tend to hurt Whisper.**
  - Krisp separates NC from "Background Voice Cancellation" and says to put AEC before NC ([docs](https://sdk-docs.krisp.ai/docs/krisp-rtc-bvc-nc)).
  - Denoising before Whisper raised WER in all 40 configurations of a 2025 study ([arXiv 2512.17562](https://arxiv.org/abs/2512.17562)) and with SAM-Audio in 2026 ([arXiv 2603.04710](https://arxiv.org/html/2603.04710)).
  - Artifacts are the cause, and partial mixing helps ([Iwamoto et al., Interspeech 2022](https://www.isca-archive.org/interspeech_2022/iwamoto22_interspeech.pdf)).
  - `AUSoundIsolation` (macOS 13+, HighQualityVoice macOS 15+) is free and built in, but undocumented beyond its header and has no ASR data.

- **Input level matters to Whisper, and Biscotti's merge makes the mic level worse.**
  - Whisper features are absolute log-mel with a per-window floor 80 dB under the peak. "The model wasn't intended to be scale-invariant" ([openai/whisper #428](https://github.com/openai/whisper/discussions/428)).
  - WhisperKit computes that floor per 30 s window ([whisperkittools](https://github.com/argmaxinc/whisperkittools/blob/main/whisperkit/audio_encoder.py)).
  - Per-segment gain control cut AMI WER by up to 2.5% ([PQGC](https://www.springerprofessional.de/p-pqgc-a-proposed-post-quantization-gain-control-for-offline-and/53061706)).
  - WhisperKit's EnergyVAD uses an absolute 0.02 RMS threshold. It is off in Biscotti today, but it would discard a raw mic.
  - pyannote normalizes level per chunk, but not between talkers within a chunk ([sincnet.py](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/models/blocks/sincnet.py)).

- **Transcript-level dedup is a safety net, not a fix.** Screenpipe, Stone, MacParakeet and OpenWhispr all started with text or energy dedup for per-track transcripts, and all moved to real AEC or kept both layers. The documented failure modes are double-talk and garbled faint-echo words ([screenpipe#4256](https://github.com/screenpipe/screenpipe/issues/4256), [OpenWhispr commit](https://github.com/OpenWhispr/openwhispr/commit/068280ba86d50b99a040f9615ca6fa8cc445e885)).

- **AEC helps ASR when echo is the interferer.** Reported WER cuts are 70%+ from AEC alone ([Interspeech 2025](https://www.isca-archive.org/interspeech_2025/lin25b_interspeech.html)) and 38–53% from adding a neural residual suppressor to linear AEC ([Interspeech 2023](https://www.isca-archive.org/interspeech_2023/panchapagesan23_interspeech.html)). A pattern worth considering: use the AEC output as a *near-end speech detector* (for attribution, gating and level measurement) while feeding Whisper the raw or **linear-only** AEC output (APM `export_linear_aec_output`), keeping suppressor artifacts out of ASR. This is a synthesis; no published system does exactly this.

## Details

- [aec-options.md](./aec-options.md): reference-AEC engines (WebRTC AEC3 and its build paths, LocalVQE, DTLN-aec and ports, SpeexDSP/NLMS, Apple), each with license, Swift/Apple-silicon path, real-time vs offline, CPU and quality evidence, and where AEC would live in Biscotti's pipeline. Read this when choosing an engine.
- [aec-failure-modes.md](./aec-failure-modes.md): alignment and latency (and the causality correction), clock drift, MacBook speaker nonlinearity, double-talk, AAC-coded reference, Biscotti gap-fill and route-change discontinuities, plus a proposed alignment design. Read this before implementing.
- [noise-suppression-voice-isolation.md](./noise-suppression-voice-isolation.md): AUSoundIsolation, AUAudioMix, DeepFilterNet, RNNoise, Krisp, ai-coustics, Koala, and the evidence that denoising hurts Whisper. Read this if considering a "clean voice" step.
- [levelling-and-whisper-input-level.md](./levelling-and-whisper-input-level.md): why level matters to Whisper and WhisperKit, how `AudioMerger` sums without per-track gain, and levelling options (BS.1770/libebur128, WebRTC AGC2, Apple AUs, PQGC) with the recommended ordering.
- [transcript-level-alternatives.md](./transcript-level-alternatives.md): what bleed does in Biscotti's merged pipeline vs a per-track pipeline, prior-art dedup approaches and why they fail, audio-level echo detectors, and AEC-for-ASR evidence.

## Open Questions / Gaps

- **No head-to-head on Mac hardware.** I found no measurement of AEC3 vs LocalVQE on MacBook-speaker → MacBook-mic echo with a process-tap reference. MacParakeet's AEC3 benchmark (U6) and real speaker-mode QA (U9) were still pending at its last update.
- **No Apple-silicon timings for LocalVQE.** The README benchmarks Zen4 and Pi 5 only.
- **Unverified tap behaviour.** I could not confirm whether Core Audio process taps capture **pre- or post-system-volume** audio, or pre- or post- built-in-speaker DSP. Both affect how stationary and how nonlinear the echo path is.
- **AAC reference ceiling unmeasured.** The effect of the **64 kbps AAC-coded reference** on achievable cancellation is not measured anywhere. Biscotti should A/B PCM-reference vs AAC-reference AEC on one recording.
- **AUSoundIsolation unknowns:** support in AVAudioEngine **offline manual rendering**, sample-rate limits, CPU/ANE cost and ASR impact are undocumented. Only anecdotes exist.
- **Merged-stream effect unmeasured.** I found no study of Whisper or pyannote on speech plus its own short-delay echo, or on a merged stream with a quiet second talker. The merged-pipeline conclusions are reasoned, not measured.
- **Conflict for the VPIO subtopic:** a Screenpipe maintainer reports VPIO cancels "0 dB" of other apps' audio when the VPIO output element is idle. Biscotti's own test saw bleed reduction with VPIO + Voice Isolation.
- **Conflict on LocalVQE v1.2:** MacParakeet's synthetic harness says it zeroes near-end voice; LocalVQE's real-recording eval says it preserves it. This is probably a tone-fixture artifact, but unresolved.
- **Tooling limits this session:** webrtc.googlesource.com and gitlab.freedesktop.org were unreachable, so AEC3 source was read from the `webrtc-sdk/webrtc` GitHub mirror (`m125_release`). The GitHub API was blocked, so the DeepFilterNet release date and some repo trees (MacParakeet's NLMS source, Corti) were not read directly.

## Sources

- [WebRTC APM header, webrtc-sdk mirror m125](https://github.com/webrtc-sdk/webrtc/blob/m125_release/modules/audio_processing/include/audio_processing.h): APM API, delay semantics, AGC2 and linear-output config (M125).
- [AEC3 config / aec3_common / clockdrift_detector, m125](https://raw.githubusercontent.com/webrtc-sdk/webrtc/m125_release/api/audio/echo_canceller3_config.h): delay-estimator and filter defaults, drift detection (M125).
- [freedesktop webrtc-audio-processing](https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/): standalone APM packaging (2.1, 2025-01-22; "tested on Linux only").
- [tonarino/webrtc-audio-processing](https://github.com/tonarino/webrtc-audio-processing): Rust wrapper, macOS build requirements (2.x).
- [dignifiedquire/sonora](https://github.com/dignifiedquire/sonora) and [BENCHMARKS.md](https://github.com/dignifiedquire/sonora/blob/main/BENCHMARKS.md): pure-Rust APM port with C API (M145+), M4 Max timings.
- [go-mediatoolkit PR #5](https://github.com/daniel-sullivan/go-mediatoolkit/pull/5): AEC3 Go port, delay range verified 4–500 ms, behavioural ERLE.
- [Nonstrict RecordKit echo cancellation guide](https://nonstrict.eu/recordkit/guides/echo-cancellation.html), [type docs](https://nonstrict.eu/recordkit/api/electron/types/EchoCancellation.html), [changelog](https://nonstrict.eu/recordkit/changelog.html): commercial Swift SDK running AEC3 on process taps (0.77–0.97).
- [amicalhq/prismical](https://github.com/amicalhq/prismical): MIT app with vendored AEC3 bridge (48 kHz, 10 ms frames).
- [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE): neural AEC models, benchmarks, AECMOS on ICASSP 2022 blind set, Apache-2.0 (README fetched 2026-10-28).
- [MimicScribe/dtln-aec-coreml](https://github.com/MimicScribe/dtln-aec-coreml): archived Swift DTLN-aec port and reasons for switching to LocalVQE.
- [breizhn/DTLN-aec](https://github.com/breizhn/DTLN-aec) and [Westhausen & Meyer, ICASSP 2021](https://ar5iv.labs.arxiv.org/html/2010.14337): DTLN-aec model, MIT, challenge results.
- [MacParakeet AEC plans and PRs](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md), [prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md), [PR #638](https://github.com/moona3k/macparakeet/pull/638): alignment harness numbers, LocalVQE model gate, energy gate, cleaned-mic design (Apr–Jul 2026).
- [Stone blog: whisper.cpp meeting transcription](https://peritissimus.com/blog/local-meeting-transcription-whisper-cpp): offline DTLN-aec with envelope alignment (2026-09-17).
- [Muesli README](https://github.com/Muesli-HQ/muesli): MIT Swift recorder crediting LocalVQE.
- [Speex manual](https://www.speex.org/docs/manual/speex-manual.pdf) and [speex_echo.h](https://github.com/xiph/speexdsp/blob/master/include/speex/speex_echo.h): Speex AEC API, drift and nonlinearity limits.
- [WWDC19 What's New in AVAudioEngine](https://developer.apple.com/videos/play/wwdc2019/510/): voice processing not available in manual rendering.
- [WWDC25 session 251](https://developer.apple.com/videos/play/wwdc2025/251/): AUAudioMix requires FOA input.
- [AudioUnitParameters.h / AUComponent.h (iOS 26 SDK mirror)](https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS26.0.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AudioUnitParameters.h): AUSoundIsolation parameters and availability.
- [QuietNow](https://github.com/spotlightishere/QuietNow): reverse-engineered AUSoundIsolation internals (2023).
- [CoreAudio AudioHardwareBase.h](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardwareBase.h): device latency, safety offset, clock domain semantics.
- [asahi-audio](https://github.com/AsahiLinux/asahi-audio), [Asahi userspace audio docs](https://asahilinux.org/docs/sw/audio-userspace/), [speakersafetyd](https://github.com/AsahiLinux/speakersafetyd): macOS speaker DSP and protection on Apple-silicon Macs.
- [MSR nonlinear residual echo suppression](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/diegobenderskyhdres.pdf): laptop nonlinearity degrades linear AEC.
- [EUSIPCO 2006 codec nonlinearity and AEC](https://www.eurasip.org/Proceedings/Eusipco/Eusipco2006/papers/1568980841.pdf): ERLE ceiling with coded echo.
- [ICASSP 2023 AEC Challenge](https://arxiv.org/html/2309.12553): metrics, WAcc, remaining headroom.
- [Wang et al. 2021, wRLS vs AEC3 linear filter](https://ar5iv.labs.arxiv.org/html/2102.08551): AEC3 linear-stage ERLE on the challenge set.
- [Krisp SDK docs](https://sdk-docs.krisp.ai/docs/krisp-rtc-bvc-nc), [ai-coustics docs](https://docs.ai-coustics.com/tutorials/sdk-quickstart) and [pricing](https://ai-coustics.com/pricing), [Picovoice Koala](https://picovoice.ai/docs/koala/) and [pricing](https://picovoice.ai/pricing/): commercial NS SDK capabilities and licensing (fetched 2026-10-28).
- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) and [Schröter et al. 2023](https://doi.org/10.48550/arxiv.2305.08227): 48 kHz NS, RTF 0.19, MIT/Apache, C API.
- [RNNoise](https://github.com/xiph/rnnoise): BSD NS library (dataset updated Jan 2025).
- [When De-noising Hurts (arXiv 2512.17562)](https://arxiv.org/abs/2512.17562), [SAM-Audio + Whisper (arXiv 2603.04710)](https://arxiv.org/html/2603.04710), [Iwamoto et al. Interspeech 2022](https://www.isca-archive.org/interspeech_2022/iwamoto22_interspeech.pdf), [polar projection (arXiv 2607.11157)](https://doi.org/10.48550/arxiv.2607.11157): speech enhancement vs ASR/Whisper (2022–2026).
- [O'Malley et al. ASRU 2021](https://doi.org/10.1109/asru51503.2021.9687942), [Panchapagesan et al. Interspeech 2023](https://www.isca-archive.org/interspeech_2023/panchapagesan23_interspeech.html), [Lin et al. Interspeech 2025](https://www.isca-archive.org/interspeech_2025/lin25b_interspeech.html): AEC improves ASR when echo is the interferer.
- [openai/whisper audio.py](https://github.com/openai/whisper/blob/main/whisper/audio.py), [discussion #428](https://github.com/openai/whisper/discussions/428), [discussion #2125](https://github.com/openai/whisper/discussions/2125): Whisper feature normalization and scale sensitivity.
- [whisperkittools audio_encoder.py](https://github.com/argmaxinc/whisperkittools/blob/main/whisperkit/audio_encoder.py), [argmax-oss-swift v1.1.0 Configurations / EnergyVAD / AudioProcessor](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/Sources/WhisperKit/Core/Configurations.swift): WhisperKit per-window mel, decoding defaults, EnergyVAD threshold (v1.1.0, Biscotti's pinned version).
- [pyannote SincNet](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/models/blocks/sincnet.py): per-chunk waveform InstanceNorm.
- [faster-whisper #254](https://github.com/SYSTRAN/faster-whisper/issues/254), [P-PQGC](https://www.springerprofessional.de/p-pqgc-a-proposed-post-quantization-gain-control-for-offline-and/53061706), [Multigrid preprocessing guide](https://multigrid.ai/learn/audio-preprocessing): level and loudness effects on Whisper.
- [libebur128](https://github.com/jiixyj/libebur128): MIT EBU R128 loudness measurement.
- [screenpipe#4256](https://github.com/screenpipe/screenpipe/issues/4256), [OpenWhispr commits](https://github.com/OpenWhispr/openwhispr/commit/068280ba86d50b99a040f9615ca6fa8cc445e885), [transcribe-md](https://github.com/hrescak/transcribe-md), [Resonant](https://www.onresonant.com/features/meetings), [wispr #65](https://github.com/sebsto/wispr/issues/65): transcript-level dedup prior art (2026).
- [Opale Systems clock drift study](https://www.opalesystems.com/Tech-Blog/66-A-clock-drift-study-in-Speech-Quality-Assessment-world.en.htm): consumer device drift 50–200 ppm.
- [IINA #4540](https://github.com/iina/iina/issues/4540): AirPlay ~2 s output delay (community reports).
- Repo: `specs/research/audio/README.md`, `phase9_validation_findings.md`, `mic_capture_level_findings.md`, `specs/research/argmax/README.md`, `Packages/Transcription/Sources/Transcription/{AudioMerger,AudioLoading,InProcessTranscriptionEngine}.swift`, `Packages/AudioCapture/Sources/AudioCapture/{AudioRecorder,MicCaptureSession,LiveMicCaptureEngine,SystemGapFillWriter}.swift`: the current pipeline facts.
