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

**Result:** _______________

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

**Result:** _______________

### 3. Transcript Output Shape (Formatted)

1. Examine the formatted output from step 2.
2. Verify:
   - [ ] Header shows: Model version (`large-v3_turbo`), Language (e.g. `en`), Speaker count, Segment count, Processing duration.
   - [ ] Each segment shows a time range (e.g. `[00:05.2 -> 00:08.7]`) and speaker label (e.g. `Speaker 0:`).
   - [ ] Segment text is present and generally makes sense for the audio content.
   - [ ] Word-level detail is shown with per-word confidence percentages.
   - [ ] Multiple speakers are detected (if the audio has multiple speakers).

**Result:** _______________

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

**Result:** _______________

### 5. Custom Vocabulary

1. Choose 2-3 distinctive terms from the audio (e.g. a person's name, company name, or technical term that Whisper might misspell).
2. Run with vocabulary:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --vocab "Steak,Acme Corp,Jordan"
   ```
3. Verify:
   - [ ] The CLI prints the vocabulary terms in the header.
   - [ ] Compare the transcript against the run without vocab: the specified terms should be more likely to appear correctly spelled (this is a soft bias, not a guarantee).

**Result:** _______________

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

**Result:** _______________

### 7. Quantized Model (Optional, for 8 GB Macs)

1. Run with the quantized model variant:
   ```
   swift run argmaxkit-cli /path/to/your/audio.wav --model large-v3_turbo_1307MB --sequential
   ```
2. Verify:
   - [ ] The quantized model downloads (if not already cached) -- ~1.3 GB instead of ~3.1 GB.
   - [ ] A transcript is produced.
   - [ ] Quality is acceptable (may be slightly less accurate than full-precision).

**Result:** _______________

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

**Result:** _______________

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

**Result:** _______________

### 10. Performance Measurement

1. Note the processing duration from the transcript header.
2. Compare against the audio file duration.
3. Record:
   - Audio duration: _____ seconds
   - Processing duration: _____ seconds
   - Real-time factor: _____ x (processing / audio)
   - Hardware: _____ (e.g. M1 Pro 16 GB, M2 Air 8 GB)
   - Model: _____ (e.g. large-v3_turbo)

**Result:** _______________

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| 1. CLI Help | | |
| 2. Model Download & First Transcription | | |
| 3. Transcript Output Shape | | |
| 4. JSON Output | | |
| 5. Custom Vocabulary | | |
| 6. Sequential Loading | | |
| 7. Quantized Model (optional) | | |
| 8. Error Handling | | |
| 9. Diarization Quality | | |
| 10. Performance | | |
