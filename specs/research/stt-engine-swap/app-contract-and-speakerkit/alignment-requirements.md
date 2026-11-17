# What an alternative STT engine must provide for word↔speaker alignment

Derived from the SpeakerKit alignment code ([`DiarizationResult.swift` v1.1.1](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/SpeakerKit/DiarizationResult.swift), unchanged since v1.0.0) and the app contract ([app-contract.md](./app-contract.md)). Items marked **(inference)** are my reasoning from the code, not stated by a source.

## Hard requirements

1. **Word-level timestamps (start and end) for every word.** SpeakerKit's `addSpeakerInfo` silently drops any segment without `words`, under both strategies. Segment-only timestamps are not enough. If the engine emits sub-word tokens (BPE/SentencePiece pieces), glue must merge them into words and take `start = first token start`, `end = last token end`.
2. **Absolute time base.** Seconds from the start of the same merged 16 kHz buffer that is passed to `SpeakerKit.diarize`. Engines that chunk long audio (e.g. fixed windows for a 1-hour meeting) must return offset-corrected times; a constant offset error shifts every word against the speaker timeline.
3. **Word text that joins correctly with `joined()`.** SpeakerKit concatenates `word` strings with no separator. Words must carry a leading space (Whisper convention) or glue must add it.
4. **Monotonic, non-overlapping order.** Matching scans diarization segments in start order and breaks early; the sub-segment splitter computes `curr.start - prev.end`. Out-of-order words produce wrong splits **(inference)**.

## Accuracy / granularity requirements

5. **Timestamp accuracy at speaker turns.** The diarization timeline has ~17 ms frames (589 frames per 10 s window — segmenter metadata on [HF](https://huggingface.co/argmaxinc/speakerkit-coreml/tree/main/speaker_segmenter/pyannote-v3/W8A16)), so diarization is not the limiting factor. Word attribution near a turn is only as good as the word times. Today's bar is Whisper's native word timestamps (cross-attention alignment heads + DTW in WhisperKit's `TranscribeTask`/`SegmentSeeker`), which are not forced-alignment quality — the WhisperX paper notes Whisper "timestamps … are prone to inaccuracies and word-level timestamps are not available out-of-the-box" ([arXiv 2303.00747](https://arxiv.org/abs/2303.00747)). **Parity target: per-word errors no worse than Whisper DTW; anything better (e.g. CTC/TDT frame-level or forced alignment) directly improves boundary attribution (inference).** I found no published number for the error that alignment can tolerate; a practical rule is that errors should stay well under the 0.15 s sub-segment split threshold and typical inter-turn gaps **(inference)**.
6. **Realistic word end times (pauses visible as gaps).** The `.subsegment` strategy only splits a segment where `next.start − prev.end > 0.15 s`. If the engine reports each word's end as the next word's start (contiguous timings, common when durations are derived from token-to-token spacing), no split ever happens and **one speaker is assigned to the whole STT segment**, losing turn changes inside it **(inference from code)**. Mitigations if the engine has this property: (a) pre-split segments at sentence punctuation before calling `addSpeakerInfo`; (b) lower `betweenWordThreshold`; (c) write our own per-word aligner over `DiarizationResult.segments` (option B in [speakerkit-coupling.md](./speakerkit-coupling.md)).
7. **Reasonable segment size.** Segments only bucket words under `.subsegment`, but a segment is also the unit dropped when it lacks words, and the unit for `.segment` IoU matching. One segment per sentence/utterance is ideal; one giant segment works with `.subsegment` only if (6) holds.
8. **Non-degenerate word durations.** A zero-length word (start == end) still matches a diarization segment that contains its frame (the first candidate is taken even with score 0), but in a diarization gap it falls back to the previous speaker. Real durations are better **(inference from `findSpeakerForSegment`)**.

## Soft requirements (quality, not alignment)

9. **Punctuation and casing** — the app displays and sends text to the LLM verbatim; no re-punctuation step exists.
10. **Per-word confidence on a 0–1 scale**, or default 1.0. Only used by the sanitizer's trailing-word filter (`< 0.3` → drop); a default of 0 is harmful.
11. **Language code** — optional; persisted, never read.
12. **Segment confidence / no-speech probability** — not needed; the app has always stored 0 for both (see app-contract §5).

## Checklist for the per-library subtopics

For each candidate engine, answer:
- Word-level or token-level timestamps? If token-level, is there a word-boundary marker to merge on?
- Are word `end` times real (silence gaps visible) or contiguous?
- Timestamp precision (frame size of the model: e.g. encoder stride) and any known bias?
- Absolute times across internal chunking of long audio?
- Leading-space / word-boundary convention in emitted text?
- Confidence per word/token and its scale (probability vs log-prob)?
- Punctuation & casing per model?
