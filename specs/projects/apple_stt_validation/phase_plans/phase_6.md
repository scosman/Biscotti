---
status: draft
---

# Phase 6: Speaker alignment, speaker metrics, report, analyze command, NOTES.md

## Overview

The final phase brings together all prior work into a runnable end-to-end pipeline. It adds: speaker alignment (bridging engine transcripts into WhisperKit types so SpeakerKit `addSpeakerInfo` can assign speakers, then converting back to neutral `AlignedTranscript`), `AnalyzeInputs` (loading all saved engine outputs into neutral `EngineTranscript` models), `SpeakerMetrics` (time/word agreement, segment stats, disagreement samples), the report model and markdown renderer, the `sttlab analyze` CLI command, and `NOTES.md` (the full runbook).

## Steps

1. **`STTLabHome/AnalyzeInputs.swift`** -- Load all saved engine data and build `EngineTranscript` per engine per meeting.
   - Whisper: decode `WhisperOutput.results`, iterate segments/words, skip special tokens, build `EngineWord` with timing.
   - Apple: decode `AppleMeetingResult.results`, delegate to `AppleWordGrouper.group(results:audioDuration:)`.
   - Reference: enumerate `home/reference/<mid>/` for chunk files (`chunk_s*_e*.meta.json`), sort by `startSample`, decode each response, build `EngineWord` with offset-adjusted times (or untimed split if no words).
   - Build display text per engine.
   - Struct `MeetingInputs` holding per-engine transcripts, meta, diarization, whisperRaw.

2. **`STTLabHome/SpeakerAlignment.swift`** -- Bridge engine transcripts to WhisperKit types, run `addSpeakerInfo`, copy of `SegmentBuilder`, then `TranscriptSanitizer.sanitize`, then convert to `AlignedTranscript`.
   - `bridge(_:)`: group timed `EngineWord`s by `segmentIndex`, build `TranscriptionResult` with `TranscriptionSegment`s and `WordTiming`s. Drop untimed words (count them).
   - `align(_:whisperRaw:diarization:audioDuration:)`: for Whisper use raw results directly; for Apple/Reference, bridge first. Then `diarization.addSpeakerInfo` -> SegmentBuilder copy -> `TranscriptSanitizer.sanitize` -> map to `AlignedTranscript`.
   - Copy `SegmentBuilder.buildSegment` (internal in Transcription) with a source comment.

3. **`STTLabAnalysis/SpeakerMetrics.swift`** -- Pure metrics on `AlignedTranscript` pairs.
   - Time agreement on 10ms grid: label at each grid point from segments, compute agreement ratio.
   - Word agreement: over matched word pairs (from `opsAW`), share with equal speaker.
   - Segment/turn stats: counts, lengths (median, p90, max), speaker changes.
   - Disagreement sample: contiguous runs of matched word pairs with different speakers, 20 longest, with time, words, speakers, nearest diarization boundary.

4. **`STTLabAnalysis/ReportModel.swift`** -- Codable aggregate of all metrics per meeting and overall.

5. **`STTLabAnalysis/MarkdownRenderer.swift`** -- Render `ReportModel` to `report.md` with all sections from analyze.md section 8.

6. **`STTLabAnalysis/TranscriptWriter.swift`** -- Write `transcripts/<mid>/{engine}.txt` and `{engine}.speakers.md` files.

7. **`sttlab/AnalyzeCommand.swift`** -- The `sttlab analyze` CLI: load, validate, compute, write report.

8. **`experiments/STTLab/NOTES.md`** -- Complete runbook (home Mac -> runner Mac -> home Mac).

## Tests

- `SpeakerMetricsTests`: time agreement on synthetic 10ms grid, word agreement, segment stats, disagreement sample extraction
- `SpeakerAlignmentTests`: bridge produces correct TranscriptionResult structure from hand-built EngineTranscript; align with hand-built DiarizationResult gives expected speakers (no models: addSpeakerInfo is pure)
- `ReportModelTests`: round-trip Codable, smoke test that MarkdownRenderer produces all expected section headings, n/a for missing engines
- `AnalyzeInputsTests`: whisper transcript building from mock WhisperOutput, reference transcript building from mock chunk files
