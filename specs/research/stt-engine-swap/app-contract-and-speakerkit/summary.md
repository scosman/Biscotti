# App contract & SpeakerKit decoupling

## Bottom Line

Yes — WhisperKit can be swapped out cleanly while keeping SpeakerKit. Nothing above `Packages/Transcription` imports either SDK; the app only consumes segment `text`, segment `startTime` (display/seek), and `speakerID`/`speakerLabel` (which come from SpeakerKit) — word timings are needed only *inside* the package to align words to speakers. SpeakerKit diarizes raw audio with no transcript, and its alignment API `DiarizationResult.addSpeakerInfo(to: [TranscriptionResult])` takes WhisperKit types that have **public inits**, so another engine's word timings can be wrapped and the existing `.subsegment` alignment and `SegmentBuilder` reused unchanged. The one catch: the SpeakerKit SPM target depends on the WhisperKit target, so the WhisperKit *module* stays linked (its models and runtime use can be dropped). No deeper hook depends on WhisperKit, and SpeakerKit models stay free (CC-BY-4.0, not gated).

## Key Findings

- **The real downstream contract is `SegmentData {speakerID, speakerLabel, startTime, endTime, text}`.** Words, word probability, segment confidence, noSpeechProbability and language are at most persisted — UI, Intelligence and search never read them (`DataStore+ReadModels.swift` `mapTranscript`).
- **Engine must supply:** word-level start/end in absolute seconds; word text with a leading space (SpeakerKit joins words with `joined()`, no separator); punctuation and casing (quality-critical — text is shown and sent to the LLM verbatim).
- **`confidence` and `noSpeechProbability` have always been 0 in production.** Under `.subsegment`, SpeakerKit creates synthetic `TranscriptionSegment`s with `avgLogprob: 0.0, noSpeechProb: 0.0` (`DiarizationResult.swift` v1.1.1 L241-292; same in v1.0.0). This corrects the repo's "unpopulated in free SDK" explanation. No engine needs to supply them.
- **Default word `probability` to 1.0, not 0** — `TranscriptSanitizer` drops a trailing single-word segment when probability < 0.3.
- **SpeakerKit→WhisperKit coupling is small:** the SPM target dependency; 3 types (`TranscriptionResult`, `TranscriptionSegment`, `WordTiming`); 2 utilities (`WhisperKit.sampleRate`, `AudioProcessor.padOrTrimAudio`). No Whisper model or tokenizer involved.
- **`addSpeakerInfo` algorithm:** reads only segment start/end/words and word text/start/end; drops segments with no words; splits a segment where the inter-word gap > 0.15 s; assigns each sub-segment one speaker by maximum frame overlap, falling back to the previous speaker when nothing overlaps.
- **Two bridge options:** (A) build WhisperKit types and reuse `addSpeakerInfo` — identical behaviour to today, ~30 lines of glue; (B) write our own aligner over the public `DiarizationResult.segments`.
- **Speaker timeline resolution is ~17 ms** (589 frames / 10 s window, from HF model metadata). STT word-timestamp quality limits alignment, not diarization.
- **Centroids need an SDK upgrade.** The repo pins argmax-oss-swift **v1.0.0**; public `speakerCentroidEmbeddings` (256-dim, raw pre-PLDA space) and distance helpers arrived in **v1.1.0** (Aug 2026, PR #463). The app hard-codes `speakerEmbeddings: [:]`; voice-prints are only planned (P2). PLDA-space centroids (PR #540) were closed without merging. There is no API to embed an arbitrary clip.
- **Free tier:** SpeakerKit (Pyannote v4 community-1) is MIT; `argmaxinc/speakerkit-coreml` models are CC-BY-4.0, `gated: false` (attribution required — a legal call for the user). Sortformer and real-time diarization are Pro-only. Dropping WhisperKit changes none of this.
- **Other WhisperKit uses in our package:** `AudioProcessor.loadAudioAsFloatArray` (decode/resample — stays available since SpeakerKit pulls in the module); tokenizer + `promptTokens` for custom vocab; model download and disk-check code; `MethodResolver` fields. A new engine needs a new method id (which marks existing transcripts stale).

## Details

- [app-contract.md](app-contract.md) — data flow; per-field must-have / nice-to-have / unused table with readers; implicit expectations; glue defaults; other WhisperKit touchpoints.
- [speakerkit-coupling.md](speakerkit-coupling.md) — SPM dependency; exact symbols SpeakerKit uses; standalone `diarize` API and `DiarizationResult` surface; `addSpeakerInfo` algorithm; public inits enabling bridging; options A/B; hook status; licensing; v1.0.0 → v1.1.1 version notes.
- [alignment-requirements.md](alignment-requirements.md) — hard / accuracy / soft requirements for a replacement engine, and a checklist for the per-library subtopics.

## Open Questions / Gaps

- No hardware run. Two claims are from source reading only: confidence/no-speech always 0, and contiguous word timings preventing `.subsegment` splits.
- No published tolerance for word-timestamp error found. Guidance is inference: keep errors well under the 0.15 s split threshold; treat Whisper DTW timestamps as the parity bar.
- Binary-size cost of keeping the WhisperKit module linked was not measured.
- Could not verify the earlier repo doc's quote "You lose word-level forced alignment in the open-source path" — not in the two Argmax blog posts checked.
- Whether each engine yields contiguous or gapped word timings belongs to the per-library subtopics.

## Sources

- argmax-oss-swift source at v1.0.0 (pinned, 2026-05-01) and v1.1.1 (latest, 2026-10-07): https://github.com/argmaxinc/argmax-oss-swift
- Release notes v1.1.0, v1.1.1; PR #463 (merged 2026-06-02), issue #457, PR #540 (closed, not merged).
- HF `argmaxinc/speakerkit-coreml` — license, gating, model metadata (last modified 2026-09-13).
- Argmax SDK 2 blog (2026-04-07); Argmax "Open-source vs Pro SDK" docs page.
- WhisperX paper, arXiv 2303.00747.
- Repo: `Packages/Transcription/Sources/Transcription/*`, `Packages/BiscottiKit/Sources/{DataStore,Intelligence,MeetingDetailUI,TranscriptionService}`, `XPCServices/BiscottiTranscriber/main.swift`, `specs/research/argmax/README.md`, `specs/architecture.md`, `specs/implementation_plan.md`.
