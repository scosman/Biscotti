# The downstream alternative: handle bleed at the transcript level instead of in the audio

**Question:** the echo in the mic is system audio that Biscotti already has on the system track. Can transcript-level de-duplication, or WhisperKit/SpeakerKit robustness, make echo removal unnecessary for transcripts?

**Short answer:** it depends on how Biscotti transcribes.
- **Today Biscotti sums both tracks into one stream** and transcribes and diarizes once. In that design the bleed is the remote speech plus a delayed, filtered copy of itself, so it does not create duplicate *words* (the exception is very large output delays such as AirPlay). Echo removal is therefore *not* required for word content. The real problems are **level imbalance** (see the levelling doc) and a reverb-like smear on remote speech.
- **If Biscotti moves to per-track transcription** (the natural way to label "me" vs "others" for free), bleed becomes phantom "me" text. Every app that took that path found transcript-level dedup a useful safety net that **fails in double-talk**, and then added real AEC.

Researched 2026-10-28.

---

## 1. Biscotti today: the merged-stream pipeline

- `AudioLoading.loadAndMerge` decodes both AAC files to 16 kHz and `AudioMerger.merge` sums them. Then `WhisperKit.transcribe(audioArray:)` and `SpeakerKit.diarize(audioArray:)` run on the single merged array (`InProcessTranscriptionEngine.swift`). `MergeResult.labels` records which tracks overlap, but nothing uses it for attribution. The Argmax research notes that the SDK takes only one `[Float]` and suggests mic-energy "me" detection as future Biscotti post-processing (`specs/research/argmax/README.md` §"two streams").
- **What bleed does in this design** *(inference from signal structure; not measured)*:
  - During remote speech, `merged = sys + h * sys` (+ user). The echo is the same content a few tens of ms later, attenuated and filtered by the room and speaker. To Whisper this looks like early reflections or reverb, not a second utterance. Whisper is trained on varied, reverberant web audio, and a single strong reflection at 10–50 ms mostly colours the sound.
  - Diarization: the echo carries the *same voice*, so it reinforces the remote speaker's cluster rather than creating a new one.
  - **Failure case: large output latency.** With AirPlay outputs (~2 s community-reported delay) or other long-latency sinks, the copy is far enough behind to be transcribed again, producing duplicated sentences. Detect it with a coarse cross-correlation (see the failure-modes doc) and either pre-align and AEC, or drop the mic's contribution in those spans.
  - **The level problem dominates.** A raw built-in mic at ≈ −48 dBFS makes the *user's* speech faint relative to remote speech in the same window. Fixing level (with the echo removed or gated first) matters more for this pipeline than removing the echo itself (levelling doc).
- **Conclusion for the current pipeline:** echo removal is a quality improvement here, not a correctness requirement. The required step is per-track levelling, and that step should be echo-aware.

## 2. If Biscotti goes per-track (mic → "me", system → "others")

Several apps took this path. All hit the same bug, and their fixes form a clear progression:

| App | What happened | What they did | Outcome |
|---|---|---|---|
| **Screenpipe** | 24-min Zoom meeting on laptop speakers: "MacBook Pro Microphone (input) 324 rows, System Audio (output) 250 rows", with the same text on both devices ~0.8 s apart | "display-only dedup"; proposed "near-equal timestamp + fuzzy text match across input/output devices"; and "a clear 'you're on speakers ... use headphones' hint" | Issue regressed repeatedly (#3228, #3432, #3826, #4256) ([issue #4256](https://github.com/screenpipe/screenpipe/issues/4256)) |
| **Stone** | "every remote sentence appears twice in the transcript — once under each speaker" | First a heuristic to "drop mic segments whose text matched the system track. It broke as soon as two people talked at once." Then offline DTLN-aec with delay compensation | "~14 dB" bleed reduction ([blog](https://peritissimus.com/blog/local-meeting-transcription-whisper-cpp)) |
| **MacParakeet** | Parakeet "squeezes a couple of garbled words out of each 5s chunk" of bleed → "phantom 'Me' fragments" | Live energy gate (drop mic chunks when system RMS ≥ 4× mic RMS and system > 0.02); `MeetingTranscriptSourceReconciler` "removes long simultaneous mic runs that match remote/system words"; then a LocalVQE cleaned-mic artifact for final STT | They concluded that "transcript-layer deletion alone cannot satisfy the plan" and that it "risks deleting real local speech during double-talk if pushed too far" ([2026-04 plan](https://github.com/moona3k/macparakeet/blob/main/plans/completed/2026-04-meeting-mic-aec.md), [prior-art note](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-06-meeting-aec-open-issues-prior-art.md), [full-close plan](https://github.com/moona3k/macparakeet/blob/main/plans/active/2026-06-28-meeting-aec-full-close.md)) |
| **OpenWhispr** | duplicate transcription on speakers | First Chromium `echoCancellation: true` on the mic stream, then a native WebRTC APM sidecar **plus** "transcript-level duplicate suppression (transcriptsOverlap, transcriptsLooselyOverlap ...) and retract segment events to drop mic duplicates after system audio confirms", plus a `MeetingEchoLeakDetector` "with a system-VAD gate" | Both layers kept ([commit da1eb52](https://github.com/OpenWhispr/openwhispr/commit/da1eb525daa96cae3f573641b47b615d4e2fbb19), [commit 068280b](https://github.com/OpenWhispr/openwhispr/commit/068280ba86d50b99a040f9615ca6fa8cc445e885)) |
| **transcribe-md**, **Resonant**, **Vexa Desktop** | same | Text-similarity echo dedup only ("Mic echoes are automatically deduplicated"; Resonant: "Text-based echo suppression detects when the same words appear on both channels") | Shipped as-is ([transcribe-md](https://github.com/hrescak/transcribe-md), [Resonant](https://www.onresonant.com/features/meetings); Vexa per MacParakeet note) |
| **wispr** (sebsto) | Parakeet V3: others' utterances "transcribed as me" | User asks for dedup: "if detected an assumption could be made that it was said at the remote end" | open ([issue #65](https://github.com/sebsto/wispr/issues/65)) |

### Why text dedup alone is fragile (synthesis from the above)

1. **Double-talk.** If the user speaks while the remote talks, the mic segment contains both. Whole-segment text matching either keeps the duplicate or deletes the user's words.
2. **Faint bleed transcribes as different words.** Low-level echo comes out as garbled fragments (MacParakeet's "garbled partial words"), which fuzzy matching against the clean system text misses. Those become false "me" text.
3. **Timing.** Echo lags by tens of ms, but per-track ASR segment boundaries and timestamps differ by far more. Screenpipe saw ~0.8 s between duplicate rows, so match windows must be loose, which raises false matches on short common words ("yeah", "okay").
4. **It cleans only the transcript.** The mic audio and any merged playback still contain the bleed.

### Better than text matching: an audio-level "is this mic frame just echo?" detector

These need no new ML and work before ASR:
- **Energy-ratio gate** (MacParakeet): suppress or ignore mic regions where system energy dominates and the mic has no excess energy. It is crude, and it drops quiet user speech during loud remote speech.
- **Echo-path-aware gate** *(my synthesis, standard AEC theory)*: estimate the system→mic echo gain per band during remote-only periods (after alignment). Flag mic frames as near-end speech only when mic energy exceeds the predicted echo by a margin. This is what an AEC's residual-echo estimator or double-talk detector does internally, and it holds up much better in double-talk than the energy ratio.
- **Use an AEC as a detector, not a filter.** Run AEC3 or LocalVQE, then use the *energy of the cleaned output* as the "user is speaking" signal for attribution, gating or level measurement. ASR can still read the raw mic, or the AEC's **linear** output: APM exports one at 16 kHz via `export_linear_aec_output` / `GetLinearAecOutput()`, before the nonlinear suppressor. This keeps suppressor artifacts away from Whisper, given the denoising/ASR evidence in the NS doc. I found no published system doing exactly this; it is a design suggestion.

## 3. Does AEC help or hurt ASR?

- **It helps when the echo is the interferer.** Google's ASR frontend work: "the joint model reduces the word error rate in low signal-to-noise ratio conditions by at least 71% on our echo cancellation dataset" ([O'Malley et al., ASRU 2021](https://doi.org/10.1109/asru51503.2021.9687942)). Another study: "AEC alone eliminates most TTS loopback, dramatically improving the word-error rate (WER) by over 70%" ([Lin et al., Interspeech 2025](https://www.isca-archive.org/interspeech_2025/lin25b_interspeech.html)). Linear AEC plus a neural residual suppressor gave "38-53% WER reduction over the linear AEC alone" on re-recorded tests ([Panchapagesan et al., Interspeech 2023](https://www.isca-archive.org/interspeech_2023/panchapagesan23_interspeech.html)).
- **Caveat:** those models were trained or tuned with ASR losses. The ICASSP 2023 AEC Challenge picks winners on "the average mean opinion score (MOS) achieved across all scenarios and the word accuracy (WAcc) rate", and still lists 0.18 WAcc headroom for the best entries. Listening quality and recognition are scored separately ([challenge paper](https://arxiv.org/html/2309.12553)). An off-the-shelf canceller tuned for human listening (aggressive suppression) can clip near-end words the same way NS does.
- **For Biscotti's merged pipeline**, the "interferer" is a copy of speech that is *also* the remote talker's real speech on the other track. Cancelling it removes redundancy, not information. The ASR benefit there is a cleaner, less smeared mix and a correctly levelled mic, not fewer insertions.

## 4. Robustness of WhisperKit/SpeakerKit alone

- I found **no** study of Whisper or pyannote on "speech + its own short-delay echo". The reasoning in §1 is inference.
- Whisper is known to skip quieter speakers in windows dominated by loud audio (faster-whisper #254, anecdotal) and is not scale-invariant (levelling doc).
- Separately, Whisper's well-known hallucination on near-silence matters more for per-track pipelines. A mic track that is mostly faint bleed is exactly the input that produces invented text; Stone runs Silero VAD first for this reason. Biscotti's current merged pipeline is less exposed, because the system track keeps windows non-silent.

**Bottom line:** for the transcript Biscotti produces today, WhisperKit/SpeakerKit robustness plus echo-aware per-track levelling is probably enough. AEC becomes necessary if Biscotti wants (a) clean mic audio for playback or export, (b) mic/system provenance for "me" attribution, or (c) per-track transcription.
