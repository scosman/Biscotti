# Failure modes for echo cancellation on Biscotti's two tracks

This doc covers what breaks reference-based AEC when the reference is Biscotti's system track: latency and alignment, clock drift, nonlinear laptop-speaker echo, double-talk, the lossy AAC reference, and Biscotti-specific discontinuities. Companion to [`aec-options.md`](./aec-options.md). Researched 2026-10-28.

---

## 1. Latency and alignment: the problem that matters most

### 1a. The "causality" objection does not apply to a recorder

`specs/research/audio/mic_capture_level_findings.md` argues that reference-based AEC "**is** impractical for a *passive* recorder, for causality reasons: we obtain the system audio from the tap **after** it has already echoed into the mic". That is wrong on two counts:

1. **Offline there is no causality constraint.** Both complete tracks exist after the meeting. Stone and MacParakeet's cleaned-mic renderer both cancel post-hoc. RecordKit also once had an `aec3Offline` mode, though its changelog doesn't say what that mode did ([Stone blog](https://peritissimus.com/blog/local-meeting-transcription-whisper-cpp), [MacParakeet plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md), [RecordKit changelog 0.85.0](https://nonstrict.eu/recordkit/changelog.html)).
2. **In real time, a recorder can just buffer.** A VoIP app has to keep latency low; a recorder does not. Delay the mic stream by a few tens of milliseconds until the matching reference frames arrive.
   - Prismical's AEC3 bridge has "render holdback / timeout logic so mic frames can wait for the matching render reference".
   - Muesli "keeps pending mic samples plus system history so the processor receives a timestamp-aligned far-end reference frame" (both per [MacParakeet's prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md)).
   - RecordKit does it live from Core Audio process taps ([guide](https://nonstrict.eu/recordkit/guides/echo-cancellation.html)).

Physically, the tap delivers samples as they are mixed for the output device. The speaker emits them later, and the mic hears them later still. *(Inference, not measured.)* The lag of mic-echo behind the system track is roughly: output device latency + output safety offset + acoustic path + input latency + input safety offset, plus whatever start-anchor error the files carry. Core Audio exposes the device parts: `kAudioDevicePropertyLatency` ("the number of frames of latency in the AudioDevice. Note that input and output latency may differ") and `kAudioDevicePropertySafetyOffset` ([AudioHardwareBase.h](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardwareBase.h)). The Stone author puts it at "a few tens of milliseconds" for laptop speakers.

### 1b. Misalignment destroys cancellation

- MacParakeet's harness: "an aligned oracle reaches ~56 dB ERLE; a 2.5 ms (40-sample) misalignment collapses it to ~-3 dB; and the bulk offset between the microphone clock and the ScreenCaptureKit system-audio clock can exceed any practical adaptive-filter span." A 600-sample bulk delay cancelled to −2.7 dB with a static zero delay and 56.5 dB once estimated ([PR #638](https://github.com/moona3k/macparakeet/pull/638), [plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md)). This is for their own NLMS/oracle setup. Engines with internal delay estimation are less sensitive to small offsets, but all of them need the bulk offset to be inside their search span.
- Stone: DTLN-aec "did almost nothing" until envelope cross-correlation alignment was added.

### 1c. How each engine copes

| Engine | Internal delay handling | Span |
|---|---|---|
| WebRTC AEC3 | Matched-filter delay estimator; `set_stream_delay_ms` hint optional | ~0.6 s by my arithmetic from m125 constants (`num_filters = 5`, 32-sub-block window, 3/4 shift, 4× down-sampling). A Go port verified 4–500 ms ([PR](https://github.com/daniel-sullivan/go-mediatoolkit/pull/5)) |
| LocalVQE | "built-in mic/reference time alignment" ([MimicScribe](https://github.com/MimicScribe/dtln-aec-coreml)) | not documented |
| DTLN-aec | none; caller aligns | — |
| SpeexDSP | none; `speex_echo_capture` assumes "delayed by two frames ... (but it could be off!)" | filter length only |

**Edge case: AirPlay output.** AirPlay audio adds a fixed delay of about 2 s on many setups, which community reports (e.g. [IINA #4540](https://github.com/iina/iina/issues/4540)) describe as roughly "(almost) exactly 2 seconds". One commenter there says macOS 27 lowered it to a non-integer value for some HomePod setups. That is far outside AEC3's estimator span, and in the *merged* transcription mix it would put the same sentence twice, ~2 s apart (inference). An offline coarse cross-correlation pre-alignment (±several seconds) before the AEC handles this.

### 1d. Recommended alignment design for Biscotti (synthesis)

- **Offline (home b):** decode both tracks. Run a coarse alignment over speech-active windows: normalized cross-correlation of pre-emphasized signals or 10 ms energy envelopes, searched ±2–3 s and repeated every N seconds to track drift and gap-fill jumps. Shift the reference, then let the engine's fine estimator take over. Reject low-confidence estimates; MacParakeet's estimator "treat[s] silence or weak correlation as no estimate rather than forcing a lag". A low-confidence result usually means headphones (no echo), and then AEC should be skipped.
- **Capture time (home a):** keep each buffer's `hostTime` (both engines already have it) and pair frames by host time, as Prismical and Muesli do.
- **Either way:** consider writing a small timeline sidecar per track (sample index ↔ host time, gap-fill events). It costs nothing and makes offline alignment more deterministic. This is a design suggestion, not a researched fact.

---

## 2. Clock drift

- **Size.** Independent crystal clocks differ by tens to hundreds of ppm. A speech-quality test lab measured "Consumer headsets: 50–200 ppm typical; Professional audio gear: 10–50 ppm" ([Opale Systems](https://www.opalesystems.com/Tech-Blog/66-A-clock-drift-study-in-Speech-Quality-Assessment-world.en.htm)). 100 ppm ≈ 0.36 s per hour.
- **Where Biscotti can drift.**
  - The mic device clock vs the output device clock that the tap's aggregate follows.
  - Core Audio reports a per-device `kAudioDevicePropertyClockDomain`: devices with the same non-zero value "are able to be synchronized in hardware", and 0 means "assumed to be separate from every other device's clock domain" ([AudioHardwareBase.h](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardwareBase.h)).
  - Built-in mic plus built-in speakers *may* share a domain; that is unverified, so the clock-domain property should be logged. Built-in mic plus USB/HDMI/Bluetooth output almost certainly does not.
  - Phase 9 saw the two files ~0.26 s apart after 10 min but attributed that to start/stop edges, not drift (`phase9_validation_findings.md`). That run never measured drift directly.
- **Effect.** A fixed alignment slides by up to ~0.4 s per hour. Linear filters lose convergence as the lag walks (Speex manual: drift "will prevent the echo canceller from adapting").
- **Engine handling.**
  - AEC3 re-estimates delay continuously, and `ClockdriftDetector` flags a probable or verified drift when estimates step by ±1 ([source](https://raw.githubusercontent.com/webrtc-sdk/webrtc/m125_release/modules/audio_processing/aec3/clockdrift_detector.cc)). Config has `echo_removal_control.has_clock_drift`.
  - LocalVQE "tolerated the clock drift that real capture pipelines produce" (MimicScribe).
  - DTLN-aec and Speex do not handle drift.
  - Offline, Biscotti can also measure the drift slope from periodic cross-correlation and resample the reference before AEC. That is cheap, and a known step in any offline two-track aligner (my synthesis).

---

## 3. Nonlinear echo from laptop speakers

- **Why it's worse than usual on a MacBook.** macOS drives the built-in speakers through heavy DSP. Asahi Linux (who reverse-engineered it) say: "macOS makes use of psychoacoustic bass enhancement, dynamic range compression, and spatialisation tricks" and "Apple actually have a _bug_ in their psychoacoustic bass processor that causes audible artefacts" ([asahi-audio README](https://github.com/AsahiLinux/asahi-audio)). Apple implements speaker protection (amp V/I-sense thermal limiting) "as machine-specific plugins to the userspace half of CoreAudio" ([speakersafetyd](https://github.com/AsahiLinux/speakersafetyd)).
  - Psychoacoustic bass synthesizes harmonics, compression and limiting are level-dependent, and thermal protection changes gain over time. All of these are nonlinear or time-varying relative to the digital mix.
  - **Inference, unverified:** a process tap captures the mix *before* this device DSP, so the reference lacks it. The pro-audio rule is "Send to the reference whatever you're sending to the loudspeaker ... any dynamic processing such as compression or limiting employed on the loudspeaker output signal is also applied to the reference signal" ([HARMAN](https://pro.harman.com/insights/enterprise/clarity-on-acoustic-echo-cancellation-operation-brings-clarity-to-audio-calls/)). Biscotti cannot follow it.
- **Effect on linear AEC.** "Although linear adaptive filters have often proved to be adequate solutions to the AEC problem in high quality hardware, they do not perform as well in common, inexpensive laptop computers ... even modest nonlinear distortion can degrade the performance of linear AEC models considerably" ([Microsoft Research, nonlinear residual echo suppression](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/diegobenderskyhdres.pdf)). Speex: nonlinear distortion "cannot be cancelled".
- **Mitigations.**
  - A residual echo suppressor after the linear stage. AEC3 has one, with `echo_model.model_reverb_in_nonlinear_mode = true` and a nonlinear mode it enters when the linear filter isn't converged (config).
  - A neural mask: LocalVQE v1.4-AEC is "a classical adaptive filter followed by a small neural mask". Anarlog adds residual linear cancellation after its neural model.
  - For ASR specifically, Google found linear AEC plus a neural residual echo suppressor cut WER 38–53% vs linear AEC alone on re-recorded data ([Panchapagesan et al., Interspeech 2023](https://www.isca-archive.org/interspeech_2023/panchapagesan23_interspeech.html)).
- **Not measured anywhere I found:** how much of MacBook speaker echo is nonlinear at typical meeting volumes. Biscotti would need its own recordings (speakers at 50/75/100% volume) to know.

---

## 4. Double-talk (user and remote speaking at once)

- **Classical tradeoff.** Aggressive suppression removes more echo but eats near-end speech. RecordKit documents it for AEC3: "'aggressive': Disables near-end speech detection so echo is suppressed even during double-talk; removes ~2 dB more echo but attenuates speech by 3-5 dB" ([docs](https://nonstrict.eu/recordkit/api/electron/types/EchoCancellation.html)). AEC3's default "transparent mode" passes audio through when no echo is detected.
- **Gating and dedup approaches fail here first.** Stone's text-match heuristic "broke as soon as two people talked at once". MacParakeet's energy gate accepts that "some very quiet user utterances during loud remote speech may be dropped" ([plan](https://github.com/moona3k/macparakeet/blob/main/plans/completed/2026-04-meeting-mic-aec.md)).
- **Neural joint models can over-suppress.** On MacParakeet's synthetic harness both LocalVQE models showed negative double-talk improvement (v1.4 −6.1 dB, v1.2 −3.5 dB). The authors attribute this to tone fixtures and say the harness "cannot positively certify double-talk fidelity". LocalVQE's real-recording eval scores v1.4 double-talk echo 4.20 / deg 2.45 vs v1.2 4.72 / 2.37 ([README](https://github.com/localai-org/LocalVQE)). Double-talk "deg" is the weakest number for every model.
- **Field-level evidence.** The ICASSP 2023 AEC Challenge paper lists "double talk other" (near-end degradation during double-talk) as having among the most headroom left for top models: 0.57 MOS after the 2022 challenge (Table 2) and 0.64 after 2023 (Table 10). Only near-end single-talk SIG (0.74) has more. Even state-of-the-art models still damage the near-end voice in double-talk ([challenge paper](https://arxiv.org/html/2309.12553)).
- **Implication for Biscotti.** Meeting double-talk is short and interjection-heavy ("yeah", "right"). That is exactly what suppressors clip. For transcripts, the less suppression the better (see the transcript doc's "use linear output / use AEC as a detector" option).

---

## 5. The reference is AAC-coded (offline home only)

- Biscotti's system track is AAC-LC 24 kHz 64 kbps. A perceptual codec discards masked components, so the decoded reference is not sample-exact to what was played. A linear filter can only cancel the part of the echo that is linearly predictable from the reference.
- **Evidence (adjacent, not identical).**
  - Simulating speech codecs on the echo path, "it is the non-linear speech coding distortion on the acoustic echo signal that ultimately reduces the achievable ERLE ... the highest average ERLE obtained by using popular speech codecs such as GSM AMR and G.728 was around 16 dB" ([EUSIPCO 2006](https://www.eurasip.org/Proceedings/Eusipco/Eusipco2006/papers/1568980841.pdf)). Those are low-bitrate speech codecs; 64 kbps AAC should be much less damaging, but I found no measurement for AAC.
  - A Qualcomm patent covers AEC during playback of encoded audio. It notes decoded-vs-source differences "may cause an acoustic echo cancellation operation ... to produce an echo-cancelled signal that includes artifacts which may interfere with ... automatic speech recognition" ([US 11031026](https://www.patents-review.com/a/20200194019-acoustic-echo-cancellation-playback-encoded-audio.html)).
- **Mitigations.**
  - (a) Do AEC at capture time on PCM.
  - (b) Store the system reference at higher fidelity. Even a lossless or PCM 16 kHz scratch reference would cost ~1.9 MB/min and could be deleted after post-processing.
  - (c) Rely on residual suppression or a neural mask, which isn't limited to linear cancellation.
  - This should be measured, not assumed: the same meeting AEC'd from PCM vs from the decoded AAC.

---

## 6. Biscotti-specific discontinuities

- **Gap fills.** A reconnect on one track inserts silence equal to the measured gap, but only for gaps >100 ms, and jitter below that is absorbed. Each reconnect can therefore shift relative alignment by up to ~100 ms. The AEC must re-converge, and an offline aligner should re-estimate per segment.
- **Route changes mid-meeting** (speakers → headphones) change the echo path completely. AEC3 handles this by re-adaptation, and has `RuntimeSetting::kPlayoutAudioDeviceChange` for the real-time case. Offline, a sudden collapse of the echo correlation tells you the user switched to headphones; skip AEC from there.
- **System volume changes** alter echo-path gain. AEC3 has `RuntimeSetting::kPlayoutVolumeChange` (APM header). I could not determine whether Core Audio process taps capture pre- or post-system-volume audio. If they are pre-volume, every volume change is an echo-path change.
- **Global tap includes non-meeting audio** (notifications, music). This is harmless for AEC, since it is all reference, and in fact helpful: it cancels music bleed from the mic too.
- **VPIO-processed mic.** If Biscotti keeps VPIO for some devices, the mic already has Apple's AEC, NS and AGC. Running a second AEC over it is usually harmless (little residual echo left), but its nonlinear processing makes the echo path non-stationary. Skip post-AEC when the track was VPIO-captured unless a correlation check shows bleed.
