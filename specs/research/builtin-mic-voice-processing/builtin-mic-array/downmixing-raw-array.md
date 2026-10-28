# Down-mixing the raw built-in array: pick one, sum, or beamform?

Research date: 2026-10-28. This doc applies only when Biscotti receives the **raw
multichannel array** from the built-in mic. That happens when another app's voice
processing has switched the device into raw mode
([channel-modes-by-model.md](./channel-modes-by-model.md)). With a 1-channel built-in
stream there is nothing to down-mix. With a VPIO client format, take channel 0.

Labels: **[source]** cited, **[repo]** measured in this repo, **[inference]** my
reasoning or arithmetic.

## Bottom line

For transcription, the raw array's problem is mostly **level**: the capsules have no
preamp, so speech peaks sit around −48 dBFS **[repo]**. Directivity is a much smaller
problem. With capsules only ~2 cm apart, no simple beamformer gains meaningful
directivity at speech frequencies, and none can remove echo from speakers a few
centimetres away. The sensible down-mix is:

1. Check polarity and lag-align the channels.
2. Combine them with equal or SNR weights. This gains ~3–5 dB of self-noise SNR and
   avoids comb filtering.
3. Fall back to the single best channel when the channels don't correlate.
4. Then high-pass filter, add make-up gain or AGC, and limit.

Do **not** pick the strongest channel per buffer, do not average blindly, and do not
attempt delay-and-sum steering or MVDR.

---

## 1. The physics that constrains every option

- **Spacing ≈ 2 cm** ("the mics are only about 2cm apart",
  [Asahi 6.14 report](https://asahilinux.org/2025/03/progress-report-6-14/)). The
  geometry is a triangle or a line depending on model ([Triforce](https://github.com/chadmed/triforce)).
  Apple doesn't label channels, so the exact positions are unknown
  ([forum 748749](https://developer.apple.com/forums/thread/748749)).
- **Maximum inter-capsule delay [inference, arithmetic]:** 0.02 m ÷ 343 m/s ≈ **58 µs**.
  That is 2.8 samples at 48 kHz, 2.6 at 44.1 kHz, 1.4 at 24 kHz and 0.9 at 16 kHz.
- **Comb filtering if you sum unaligned channels [inference, arithmetic].** Two equal
  channels offset by Δ sum to |H(f)| = |cos(π f Δ)|. Worst case, the talker sits on the
  line through two capsules ("endfire"), so Δ = 58 µs:
  - −1 dB at ≈ 2.6 kHz
  - −3 dB at ≈ 4.3 kHz
  - −6 dB at ≈ 5.7 kHz
  - a null at 1/(2Δ) ≈ **8.6 kHz**

  For a talker broadside to the pair, Δ ≈ 0 and there is no comb. AN-1140 says the same
  about summing arrays: "A broadside beamformer has a flat frequency response on-axis";
  off-axis "the nulls in the response" appear
  ([InvenSense AN-1140](https://admin-uat.invensense.com/sites/default/files/2026-01/Microphone-Array-Beamforming_0.pdf)).

  The 3–8 kHz band carries consonant (fricative) energy that ASR uses. Whisper resamples
  to 16 kHz (`SAMPLE_RATE = 16000`,
  [openai/whisper audio.py](https://github.com/openai/whisper/blob/main/whisper/audio.py)),
  so content above 8 kHz is irrelevant to transcription, but 3–8 kHz is not.
- **Residual misalignment after integer-sample alignment [inference, arithmetic]:** at
  48 kHz the residual is ≤ 0.5 sample (10.4 µs). At 8 kHz that costs |cos(π·8000·10.4 µs)|
  ≈ 0.966, about −0.3 dB. **Integer-lag alignment at 48 kHz is enough for loss-free
  summation below 8 kHz.** Asahi's "temporal resolution" complaint was about *steering a
  beam* for directivity, which needs much finer control.
- **SNR from summing [source].** "In a broadside summing array, the self noise from
  multiple microphones is added together in power terms, resulting in a 3 dB increase in
  noise per doubling of the number of microphones … the signal level doubles for a 6 dB
  increase … This results in a 3 dB improvement of SNR" (AN-1140).
  - **[inference]** For 3 coherent capsules that is +4.8 dB over one capsule; for 2
    capsules (MacBook Neo) +3.0 dB.
  - This applies only to *uncorrelated* noise (capsule self-noise). Room noise and echo
    at low frequency arrive nearly identically at capsules 2 cm apart, so summing does
    not reduce them. AN-1140: "Spacing microphones closer together … reduces the
    attenuation at lower frequencies."
- **Mismatch [source].** "Good performance from a microphone beamformer requires that the
  sensitivity and frequency response of the different elements of the array be closely
  matched" (AN-1140). Real capsules differ: one T2 MacBook Pro capsule is about 10–12 dB
  below the other two
  ([omarchy #8526](https://github.com/omacom/omarchy/discussions/8526)). On an M-series
  MBP the three were within ~3 dB **[repo]**.
- **Level [source].** The capsules come "with no preamplification"
  ([Asahi](https://asahilinux.org/docs/sw/audio-userspace/)). Measured raw speech peaks
  are ≈ −48 dBFS on an M-series MBP during a call **[repo]** and −37 to −49 dBFS on a T2
  MBP 16" ([omarchy #8526](https://github.com/omacom/omarchy/discussions/8526)). Gain
  doesn't change SNR, but a quiet track is unpleasant to listen to and AAC-encodes
  poorly. Some form of make-up gain is required whichever combining method is used.
- **Echo [inference].** The speakers are centimetres from the mics. Speaker echo arrives
  as a near-field, broadband source that is coherent across all capsules. A 2 cm array
  cannot null it at speech frequencies without also hurting the talker. Removing echo
  needs AEC or ML isolation (post-processing subtopic, or Apple's Voice Isolation in
  [processed-audio-without-vpio.md](./processed-audio-without-vpio.md)).

## 2. The options compared

| Option | Level vs one capsule | SNR (self-noise) | Comb / cancellation risk | Effort | Verdict |
|---|---|---|---|---|---|
| **Channel 0 only** | 0 dB | 0 dB | None | Trivial | Fine as a fallback. Risk: ch0 could be the occluded or weak capsule (~10 dB down on the T2 example). |
| **Strongest channel per buffer** (TypeWhisper [PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755): `strongestChannelIndex`, "energy sum per channel") | 0 dB | 0 dB | None, but **switching discontinuities**: each buffer can jump between capsules with different level and timing | Low | Avoid per-buffer switching. If choosing one channel, choose per session or with hysteresis and a cross-fade. |
| **Equal-weight average** (what the repo's AVCaptureSession path does now) | 0 dB if in phase; −9.5 dB if one of three is inverted; deep cancellation if two equal channels are inverted | +4.8 dB (3 ch) | Comb above ~4 kHz for an endfire talker (§1); cancellation if any channel is polarity-inverted | Trivial | Acceptable only after a polarity check. Worked on the repo's M-series MBP (average peak ≈ channel peaks). |
| **Polarity-checked, lag-aligned, weighted sum** (recommended) | 0 dB | ≈ +3 to +4.8 dB | Minimal (−0.3 dB at 8 kHz after integer alignment) | Medium (cross-correlation on voiced frames) | **Recommended** for raw-array mode. |
| **Steered delay-and-sum** (needs geometry and a look direction) | 0 dB | Same as above | — | Medium–high; needs per-model geometry Apple doesn't publish | Little directivity at 2 cm. Asahi tried and gave up. Not worth it. |
| **MVDR adaptive beamformer** ([Triforce](https://github.com/chadmed/triforce)) | — | Adaptive | — | High. Triforce is narrowband (`freq_curr: 1000f32`), uses a pseudo-inverse "because our samples are shit", and needs per-model geometry from the host ([src/lib.rs](https://raw.githubusercontent.com/chadmed/triforce/main/src/lib.rs)) | Its own author warns "Do not expect it to outperform Apple's implementation". Not worth it. |
| **Differential / endfire (subtract-and-delay)** | Low-frequency loss: "rises with frequency at 6 dB/octave" and needs EQ (AN-1140) | Worse at low frequency | — | Medium | Wrong tool: it boosts self-noise and needs known geometry. |

### About the OpenOats claim

[OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561) (merged 2026-05-01)
switched from averaging to "channel 0 directly". It describes channel 0 as "the
front-facing primary beam" and channels 1+ as "anti-phase or uncorrelated" beams. Its
before/after numbers (−70 dB → −7 dB peak) are far beyond what averaging could cause, and
OpenOats can enable VPIO, which makes channel 0 the processed output. Treat it as
unverified ([channel-modes-by-model.md](./channel-modes-by-model.md) §4). The safe
conclusion: **measure polarity and correlation at runtime instead of hard-coding either
"average" or "channel 0".**

## 3. A concrete, low-risk algorithm for raw-array mode [inference: design proposal]

Run everything at the source rate, before any resampling. The repo has already learned to
"downmix at the source rate, then mono→mono resample" and to never let `AVAudioConverter`
do channel reduction (mic_capture_level_findings, "Prior fixes").

1. **Classify channels** over a rolling window of roughly 0.5–2 s of voiced frames, using
   an energy-based VAD or the HAL VAD state:
   - *dead*: digital silence, every sample 0 or < −100 dBFS;
   - *live*: everything else.
   Ignore dead channels.
2. **Estimate lag and polarity** of each live channel against a reference: the channel
   with the highest voiced-frame energy, chosen once and kept sticky.
   - Search lags of ±4 samples at 48 kHz (±3 at 44.1 kHz). Physical lags are ≤ 2.8
     samples.
   - Use plain normalised cross-correlation, or GCC-PHAT. MathWorks' `gccphat` "finds
     the location of the peak of the cross-correlation … using the generalized
     cross-correlation phase transform (GCC-PHAT) algorithm"
     ([MathWorks gccphat](https://www.mathworks.com/help/phased/ref/gccphat.html)).
   - Take the sign of the peak as polarity.
   - Re-estimate only occasionally (every few seconds), with smoothing.
3. **Decide the mode:**
   - If every live channel's |peak correlation| is ≥ ~0.6, use an aligned, sign-corrected
     sum.
   - Otherwise use the reference channel alone. Low correlation means the channels carry
     different content, which is the OpenOats scenario or a non-array device.
4. **Weights:** normalise each channel's RMS to the reference, then average. Optionally
   weight by estimated SNR (energy in voiced frames ÷ energy in unvoiced frames). With
   the T2's 12 dB-weak capsule, equal-weight averaging still beats a single capsule by
   about 2.5 dB in self-noise SNR. Maximal-ratio weights would give about 3.2 dB.
5. **Post-chain:**
   - High-pass at ~80–100 Hz. The T2 Linux DSP graph also "applies the model-specific
     gain and high-pass filter" ([omarchy #8526](https://github.com/omacom/omarchy/discussions/8526)).
   - Slow AGC toward a speech target (e.g. −20 dBFS RMS on voiced frames).
   - A peak limiter before the AAC encoder.

   Build the AGC as a *stateful* processor, not per-buffer normalisation. TypeWhisper
   learned this the hard way: "Whisper Mode previously normalized every audio buffer
   independently", which "could boost quiet pauses and cause pumping or clipping". Their
   fix is a "stateful gain processor" with "a low-energy activation threshold, smoothed
   attack and release, peak protection, and soft limiting"
   ([TypeWhisper PR #1114, merged 2026-08-15](https://github.com/TypeWhisper/typewhisper-mac/pull/1114)).
6. **Handle mode transitions.** When the device returns to the 1-ch processed format
   (call ends), switch to pass-through and let the AGC settle back toward ~0 dB gain.
   Expect a 20–30 dB level step at each transition. Either reset the AGC with a known
   per-mode starting gain, or make the attack fast enough to settle within about a
   second.

Cost: for 3 channels at 48 kHz, the cross-correlation over ±4 lags is a few hundred
thousand multiply-adds per second, which is negligible.

## 4. Testing the down-mix (repo rules apply)

The repo's audio test rules
([hardware_debugging_workflow.md](../../audio/hardware_debugging_workflow.md)) call for
tests that write real AAC through the real 48 → 24 kHz path. For the down-mix, add
synthetic multichannel fixtures that cover:

- in-phase equal channels;
- one channel 10 dB down;
- one channel polarity-inverted;
- one channel delayed 3 samples;
- one dead channel;
- uncorrelated channels.

Assert output level and that there is no notch in 3–8 kHz. OpenOats added similar
anti-phase regression tests (PR #561: `testNonInterleavedMultiChannelMicPreservesSignal`,
2-channel anti-phase).
