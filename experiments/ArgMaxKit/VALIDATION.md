# ArgMaxKit Validation Script (V3)

Run this on a Mac with Apple Silicon running macOS 15+. You need an internet connection for the first run (model download). You also need an audio file with at least two speakers -- a recording from AudioLab (V1) works well.

## Prerequisites

- ArgMaxKit built successfully (`cd experiments/ArgMaxKit && swift build`)
- An audio file with speech from at least two people (WAV, CAF, M4A, or MP3)
  - Ideally a meeting recording from AudioLab with both mic and system audio merged, or any podcast/interview clip
  - A short clip (1-5 minutes) is best for initial testing; longer files take more time to process
- Internet connection (first run downloads ~3.1 GB STT model + ~33 MB diarization model)
- At least 8 GB RAM (16 GB recommended for full-precision model)

## Test Steps

### 1. CLI Help & Basic Invocation

1. Build the CLI:
   ```
   cd experiments/ArgMaxKit && swift build
   ```
2. Run with `--help`:
   ```
   swift run argmaxkit-cli --help
   ```
3. Verify:
   - [ ] Help text shows the audio file argument, `--model`, `--vocab`, `--json`, and `--sequential` options.
   - [ ] Description mentions WhisperKit and SpeakerKit.

**Result:** **PASS** (run by agent, M4/macOS 15). Build clean (~3.4s). Help shows the `<audio-file>` argument and all of `--model` (default `large-v3_turbo`), `--vocab`, `--json`, `--sequential`; overview mentions WhisperKit STT + SpeakerKit Pyannote diarization.

### 2. Model Download & First Transcription

1. Run the CLI on your audio file:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav
   ```
2. On first run, models will be downloaded from HuggingFace. This may take several minutes.
3. After download, CoreML will compile the models on-device (15-90 seconds on first run).
4. Verify:
   - [ ] Model download completes without errors.
   - [ ] CoreML compilation completes (subsequent runs skip this step).
   - [ ] A formatted transcript is printed showing speaker labels and timestamps.
   - [ ] Processing duration is reported at the top.

**Result:** **PASS** (run by agent, M4/macOS 15, models already cached from a prior run so no download needed; CoreML compile was already cached too). Test audio: `~/Downloads/voice_test.mp3`, 25.1s, 3 speakers. Output: Model `large-v3_turbo`, Language `en`, Speakers 3, Segments 11, ~10.7s processing. Formatted transcript printed with speaker labels and timestamps.

### 3. Transcript Output Shape (Formatted)

1. Examine the formatted output from step 2.
2. Verify:
   - [ ] Header shows: Model version (`large-v3_turbo`), Language (e.g. `en`), Speaker count, Segment count, Processing duration.
   - [ ] Each segment shows a time range (e.g. `[00:05.2 -> 00:08.7]`) and speaker label (e.g. `Speaker 0:`).
   - [ ] Segment text is present and generally makes sense for the audio content.
   - [ ] Word-level detail is shown with per-word confidence percentages.
   - [ ] Multiple speakers are detected (if the audio has multiple speakers).

**Result:** **PASS, with one anomaly noted.** Header showed model/language/speaker count/segment count/processing duration. Each segment had a `[mm:ss.s -> mm:ss.s]` range + `Speaker N:` label; text matched the audio; per-word confidences present; 3 speakers detected. **Anomaly:** the final segment was `[00:52.5 -> 00:52.5] "Thank you"` with low confidence on "Thank" (39%) — a timestamp **past the 25.1s audio length**. This is a classic Whisper end-of-audio hallucination. Production should drop/clamp segments whose timestamps exceed the audio duration and/or filter very-low-confidence trailing single-word segments. See research doc.

### 4. JSON Output

1. Run with `--json` flag:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --json
   ```
2. Pipe to a file for inspection:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --json > transcript.json
   ```
3. Verify the JSON structure:
   - [ ] Top-level fields: `id`, `createdAt`, `modelVersion`, `language`, `speakerCount`, `segments`, `speakerEmbeddings`, `processingDuration`.
   - [ ] Each segment has: `id`, `speakerID`, `speakerLabel`, `startTime`, `endTime`, `text`, `confidence`, `noSpeechProbability`, `words`.
   - [ ] Each word has: `word`, `startTime`, `endTime`, `probability`, `speakerID`.
   - [ ] `speakerEmbeddings` is present (empty dict `{}` -- centroid embeddings are not exposed in free SDK v1.0.0; field reserved for future use).
   - [ ] JSON is valid and parses without errors (e.g. `python3 -m json.tool transcript.json`).

**Result:** **PASS, after one bug fixed.** All required fields present — top-level `id`, `createdAt`, `modelVersion`, `language`, `speakerCount`, `segments`, `speakerEmbeddings`, `processingDuration`; per-segment `id`, `speakerID`, `speakerLabel`, `startTime`, `endTime`, `text`, `confidence`, `noSpeechProbability`, `words`; per-word `word`, `startTime`, `endTime`, `probability`, `speakerID`. `speakerEmbeddings` is `{}` as documented. **Bug found & fixed:** `--json` output was unparseable when redirected to a file because the CLI printed its banner + "Loading models…" progress lines to **stdout** ahead of the JSON. Fixed by routing all diagnostics and error messages to **stderr** (via a `printErr` helper), leaving stdout as pure result. After the fix, `... --json 2>/dev/null | python3 -m json.tool` parses cleanly. **Field note:** segment-level `confidence` and `noSpeechProbability` came back `0` for all segments — the meaningful confidence signal is at the **word** level (`probability`). Treat segment confidence as unpopulated in this SDK version.

### 5. Custom Vocabulary

1. Choose 2-3 distinctive terms from the audio (e.g. a person's name, company name, or technical term that Whisper might misspell).
2. Run with vocabulary:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --vocab "Biscotti,Acme Corp,Jordan"
   ```
3. Verify:
   - [ ] The CLI prints the vocabulary terms in the header.
   - [ ] Compare the transcript against the run without vocab: the specified terms should be more likely to appear correctly spelled (this is a soft bias, not a guarantee).

**Result:** **PASS.** Ran with `--vocab "James,banana,Biscotti"`. Header echoed `Vocabulary: James, banana, Biscotti`; transcript produced normally and "James" appeared correctly spelled. (The clip already transcribed these terms correctly without vocab, so this confirms the prompt-bias plumbing works rather than demonstrating a correction; effect is a soft bias as documented.)

### 6. Sequential Loading Mode (8 GB Mac or Memory Test)

1. Run with `--sequential` flag:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --sequential
   ```
2. Verify:
   - [ ] The header shows `Sequential: true`.
   - [ ] The transcript is produced successfully.
   - [ ] Processing may take slightly longer (models are loaded/unloaded in sequence).
3. (Optional) Monitor memory via Activity Monitor during processing:
   - [ ] In sequential mode, peak memory should be lower than non-sequential (STT model is unloaded before diarization model loads).

**Result:** **PASS** (functional). Header showed `Sequential: true`; transcript produced successfully (3 speakers, 11 segments, ~10.0s processing — comparable to non-sequential on this 25s clip). Peak-memory delta not measured (Activity Monitor step skipped; the agent run can't observe live memory). Memory benefit is the documented design intent; not quantified here.

### 7. Quantized Model (Optional, for 8 GB Macs)

1. Run with the quantized model variant:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --model large-v3_turbo_1307MB --sequential
   ```
2. Verify:
   - [ ] The quantized model downloads (if not already cached) -- ~1.3 GB instead of ~3.1 GB.
   - [ ] A transcript is produced.
   - [ ] Quality is acceptable (may be slightly less accurate than full-precision).

**Result:** **NOT RUN (optional).** The quantized `large-v3_turbo_1307MB` variant is not in the local HuggingFace cache and would require a fresh ~1.3 GB download; skipped to avoid an unprompted large download during the agent-driven run. The full-precision path is fully validated above; the quantized variant is an optional memory optimization for 8 GB Macs and can be spot-checked later if needed.

### 8. Error Handling

1. Run with a nonexistent file:
   ```
   swift run argmaxkit-cli /tmp/nonexistent.wav
   ```
   - [ ] A clear error message is shown: "File not found" or "Invalid audio file".
2. Run with a non-audio file (e.g. a text file):
   ```
   swift run argmaxkit-cli /path/to/some/textfile.txt
   ```
   - [ ] A clear error message is shown about audio loading failure.

**Result:** **PASS** (run by agent). Nonexistent path → `Error: File not found: /tmp/nonexistent.wav` (checked before model load). Text file → `Error: Failed to load audio from <path>: ...` (the underlying AVFoundation/CoreAudio error code is appended; the human-readable prefix is clear). Minor polish opportunity: the file-not-found check is fast, but the invalid-audio case only fails after the "Loading models..." banner prints — consider validating audio decodability before the model-load banner.

### 9. Diarization Quality (Subjective)

1. Review the transcript from step 2 or 3.
2. Assess speaker attribution:
   - [ ] Different speakers are assigned different speaker IDs (Speaker 0, Speaker 1, etc.).
   - [ ] Speaker transitions generally align with actual speaker changes in the audio.
   - [ ] Single-speaker stretches are mostly attributed to one speaker (minimal false transitions).
3. Note any quality issues for the research doc:
   - Frequent misattributions?
   - Missed speaker changes?
   - Segments with "No Speaker Matched"?

**Result:** **PASS (good, on a small sample).** On the 25s clip, 3 distinct speaker IDs were assigned and transitions tracked the content well: Speaker 0 = the narrator ("This is a thing we actually need to do…", "Say something for real, James."), Speaker 1 = the deliberately-silly "banana" voice ("Banana, banana", "Okay, find my banana head."), Speaker 2 = the third, normal voice ("And what would you like me to say?", "I would like more food, please."). No "No Speaker Matched" segments. Single-speaker stretches stayed on one ID. **Caveat:** sample is short (25s, scripted) — not a stress test of overlapping speech, crosstalk, or many speakers. The deliberately-altered "banana" voice was split into its own speaker, which is the correct behavior for a voice that genuinely sounds different but is a reminder that diarization keys on vocal characteristics, not identity. Recommend a longer real-meeting sample for a fuller quality read.

### 10. Performance Measurement

1. Note the processing duration from the transcript header.
2. Compare against the audio file duration.
3. Record:
   - Audio duration: 25.1 seconds
   - Processing duration: ~10.7 seconds (non-sequential); ~10.0 seconds (sequential)
   - Real-time factor: ~0.43x (processing / audio) — faster than real time
   - Hardware: Apple M4 MacBook Pro, macOS 15
   - Model: large-v3_turbo (full precision)

**Result:** **PASS.** ~0.43x real-time on warm models (models + CoreML already compiled/cached). Note this excludes one-time first-run costs: ~3.1 GB STT + ~33 MB diarization download, plus 15–90s CoreML compilation. For the production app these are paid once at setup. RTF on a 25s clip is indicative only; longer files amortize fixed model-load overhead and should show a better steady-state RTF.

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| 1. CLI Help | PASS | All options + WhisperKit/SpeakerKit described. |
| 2. Model Download & First Transcription | PASS | Models cached; transcript w/ speakers + timestamps. |
| 3. Transcript Output Shape | PASS (1 anomaly) | All fields present; trailing hallucinated segment past audio length. |
| 4. JSON Output | PASS (1 bug fixed) | Banner polluted stdout in `--json`; fixed → diagnostics now on stderr. Segment-level confidence is 0 (word-level is the real signal). |
| 5. Custom Vocabulary | PASS | Vocab echoed in header; soft-bias plumbing works. |
| 6. Sequential Loading | PASS (functional) | `Sequential: true`, transcript produced; memory delta not measured. |
| 7. Quantized Model (optional) | NOT RUN | Optional; would need ~1.3 GB download (not cached). |
| 8. Error Handling | PASS | Clear errors for missing file & non-audio file. |
| 9. Diarization Quality | PASS (small sample) | 3 speakers, transitions tracked content; short scripted clip only. |
| 10. Performance | PASS | ~0.43x real-time (warm models) on M4. |

**Validation run summary:** Run by the coding agent on an Apple M4 / macOS 15 with models pre-cached, against `~/Downloads/voice_test.mp3` (25.1s, 3 speakers). 8 of 10 tests PASS (Test 7 optional/not-run; Test 6 functionally passes, memory unquantified). One bug found and fixed (`--json` stdout pollution → diagnostics moved to stderr). Findings folded into `research/argmax/README.md`.
