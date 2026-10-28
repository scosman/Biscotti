# Loudness levelling / AGC, and whether input level matters to WhisperKit and SpeakerKit

**Question:** the raw (non-VPIO) built-in mic records at about −48 dBFS peak during meetings (`specs/research/audio/mic_capture_level_findings.md`). Does that hurt transcription, and what levelling should Biscotti apply after capture?

**Short answer:** yes, it matters, mostly because of how Biscotti **merges** the tracks. Whisper is not scale-invariant. Its log-mel features carry absolute level, and the per-window floor is set by the loudest content in each 30 s window. Biscotti sums the mic and system tracks without per-track normalization, so a quiet mic voice sits 30–40 dB under loud remote speech in the same window. That is the condition where Whisper tends to skip the quieter talker. The cheapest, safest post-processing win is **speech-gated per-track loudness normalization before the merge**: a linear gain, no spectral processing. Researched 2026-10-28.

---

## 1. What Whisper (and WhisperKit) do with level

- **Feature computation** (openai/whisper `audio.py`):
  ```python
  log_spec = torch.clamp(mel_spec, min=1e-10).log10()
  log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
  log_spec = (log_spec + 4.0) / 4.0
  ```
  ([source](https://github.com/openai/whisper/blob/main/whisper/audio.py)). Log-power is shifted by a **fixed** offset, not normalized per input, so a −30 dB gain change moves every feature by −0.75 units. The only adaptive step is the floor at 80 dB below the maximum.
- **WhisperKit computes that maximum per 30 s window.** Its CoreML `MelSpectrogram` model is converted from `WhisperMelSpectrogram` in whisperkittools, which applies `torch.maximum(log_spec, log_spec.max() - 8.0)` over each model call ([audio_encoder.py](https://github.com/argmaxinc/whisperkittools/blob/main/whisperkit/audio_encoder.py)). WhisperKit calls it once per `windowSamples` (480 000 samples = 30 s) ([FeatureExtractor.swift](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/FeatureExtractor.swift)). Reference openai/whisper `transcribe()` instead computes the mel over the whole file once (`transcribe.py` line 139), so its floor is global. The two implementations differ slightly here.
- **OpenAI's statement:** "The model wasn't intended to be scale-invariant ... the log magnitude values in the Mel spectrogram have been manually rescaled to (roughly) [-1, 1] during training ... The model will be somewhat invariant to normal volume changes, but apparently not for a 32768x change." That was jongwook in [openai/whisper discussion #428](https://github.com/openai/whisper/discussions/428), where a 32768× rescale broke the transcription.
- **Loud-vs-quiet speakers in one window.** In a faster-whisper report, guests in interview segments were skipped entirely. The diagnosis was "it has to do with the fact that the audio has sections that are super loud", and per-file standardization "helped a bit" ([SYSTRAN/faster-whisper#254](https://github.com/SYSTRAN/faster-whisper/issues/254)). This is anecdotal, but it matches Biscotti's merged loud-system / quiet-mic case.
- **Gain control measurably helps distant/quiet speech.** On the AMI meeting corpus, per-segment peak normalization ("PQGC") reduced Whisper WER by "up to 2.5%" and outperformed RMS normalization ([P-PQGC paper](https://www.springerprofessional.de/p-pqgc-a-proposed-post-quantization-gain-control-for-offline-and/53061706)).
- **Normalization is the "safe" enhancement.** Practitioner guides rank loudness normalization as the safest preprocessing step "because it is close to a linear gain change", in contrast to denoising ([Multigrid](https://multigrid.ai/learn/audio-preprocessing)).

### WhisperKit settings Biscotti uses today (argmax-oss-swift **v1.1.0**, pinned)

- `DecodingOptions` defaults: `compressionRatioThreshold 2.4`, `logProbThreshold -1.0`, `firstTokenLogProbThreshold -1.5`, `noSpeechThreshold 0.6`, `chunkingStrategy nil` ([Configurations.swift @ v1.1.0](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/Sources/WhisperKit/Core/Configurations.swift)). Biscotti sets only `detectLanguage`, `wordTimestamps` and `promptTokens` (`InProcessTranscriptionEngine.runSTT`), so **VAD chunking is off**.
- **Latent trap.** If VAD chunking (`.vad`) is ever enabled, `EnergyVAD` uses an **absolute** RMS threshold of `0.02` (≈ −34 dBFS RMS) per 100 ms frame (`EnergyVAD.swift`, `AudioProcessor.calculateVoiceActivityInChunks` @ v1.1.0). A raw mic peaking at 0.004 would be classed as silence everywhere. Normalize before any energy VAD.

## 2. SpeakerKit / pyannote

- pyannote's segmentation model (PyanNet/SincNet, the architecture behind community-1) applies `nn.InstanceNorm1d(1, affine=True)` to the raw waveform of each chunk ([sincnet.py](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/models/blocks/sincnet.py)). It is therefore insensitive to the *overall* level of a chunk, but **not** to the relative level of two talkers inside one chunk.
- *Inference:* SpeakerKit's CoreML port of community-1 should keep this op. I did not inspect the CoreML graph.
- A quiet mic voice inside a loud mixed chunk is a weaker signal for both the segmentation and the embedding stage.

## 3. What Biscotti's merge does today

`AudioMerger.mergeTwoStreams` (`Packages/Transcription/Sources/Transcription/AudioMerger.swift`):
1. Sums `mic[i] + system[i]`.
2. Scales only if the result peaks above 1.0.

There is no per-track gain. With VPIO the mic arrives AGC'd and loud (`ch0≈0.54` in the AudioLab notes), so this is fine. With a raw built-in mic during a meeting (peak ≈ 0.004) and a system track at normal playback level, the user's voice is ~30–40 dB below the remote voices in the merged array. Both Whisper and pyannote then see the user as faint background speech. *(The level figures are from the repo; the effect on WER is an inference this research could not measure.)*

## 4. Levelling options

| Option | What | License / availability | Notes |
|---|---|---|---|
| **Speech-gated per-track gain** (recommended first step) | Measure each track's loudness over *speech-active* frames only (energy or WhisperKit/Silero VAD, or BS.1770 gating). Apply one static gain (or a slowly varying one) so both tracks hit the same target, e.g. −23 LUFS / ≈ −20 dBFS RMS speech. Cap max gain (e.g. +30 dB) and add a peak limiter. | trivial Swift / Accelerate | Linear, so it has none of the artifact risk of NS. Must run **after** AEC or echo gating, otherwise it also amplifies bleed. |
| **ITU-R BS.1770 / EBU R128 measurement** | Integrated loudness with absolute and relative gating, which excludes silence | `libebur128` **MIT** ([repo](https://github.com/jiixyj/libebur128)) | Gives a robust "speech loudness" without a separate VAD. Two-pass (measure, then apply) suits offline. |
| **WebRTC AGC2 (adaptive digital)** | RNN-VAD-gated adaptive gain + limiter. Defaults: `headroom_db 5`, `max_gain_db 50`, `initial_gain_db 15`, `max_gain_change_db_per_second 6`, `max_output_noise_level_dbfs -50` | BSD-3; part of APM (comes free if AEC3 is adopted) | Works streaming or offline. Time-varying gain can pump on long meetings. The `max_output_noise_level_dbfs` cap stops it from blowing up the noise floor. ([APM header](https://github.com/webrtc-sdk/webrtc/blob/m125_release/modules/audio_processing/include/audio_processing.h)) |
| **Apple AUs** (`AUDynamicsProcessor` / `kAudioUnitSubType_DynamicsProcessor`, `AUPeakLimiter`) | Compressor/expander and limiter, hostable in AVAudioEngine manual offline rendering | built in | Usable as the limiter stage. No VAD gating; a compressor does not "level" a whole meeting's worth of quiet speech on its own. |
| **Per-segment normalization (PQGC-style)** | Normalize each homogeneous speech segment separately | paper method | Most aggressive. Helps distant speakers on AMI. Needs segmentation, and gain changes between segments are audible (irrelevant for ASR). |

### Ordering (synthesis)

For the merged-transcript pipeline:
1. Align the tracks.
2. Run AEC on the mic, or echo-aware gating.
3. Apply speech-gated per-track normalization.
4. Merge with a limiter.
5. *(Optional, tested)* light NS on a listening copy only.

Normalizing before AEC raises the echo copy with the voice, and the merged mix gets a stronger delayed duplicate of remote speech.

## 5. Gaps

- No published measurement of WhisperKit WER vs input level for a merged two-talker stream. Biscotti should measure: record the same meeting with VPIO (reference) and raw mic, then compare transcripts with and without per-track normalization.
- The CoreML port of pyannote community-1 inside SpeakerKit was not inspected for the input InstanceNorm.
