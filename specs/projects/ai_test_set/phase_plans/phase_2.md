---
status: complete
---

# Phase 2: AI Tests + Make Target + Docs

## Overview

Add the env-gated AI test suite that exercises the real Transcription pipeline against reference audio clips. These tests are heavy (download models, run inference) and must be isolated from the gating `make test` tier. Also add `make test-ai` and document it in `CLAUDE.md`.

## Steps

1. Create `AIModelTests.swift` in `Tests/TranscriptionTests/` with:
   - `Tag` extension: `@Tag static var aiModel: Self`
   - `AITestGate` enum: checks `BISCOTTI_RUN_AI_TESTS == "1"`
   - `audioDuration(url:)` helper using AVFoundation for the no-hallucination check
   - `@Suite("AI model tests")` containing two gated tests:
     a. Diarization + accuracy test: loads mic/system fixtures, runs `Transcriber(backend: .inProcess).processAudio(mic:system:)`, asserts `DiarizationGroundTruth.evaluate` passes and no segment endTime exceeds audio duration
     b. Custom-vocab test: loads custom_vocab_test fixture, runs `processAudio(mic:clip, system:clip, customVocabulary: GroundTruth.vocabTerms)`, asserts `VocabGroundTruth.evaluate` passes

2. Add `test-ai` target to `Makefile`: `BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/Transcription`. Not added to any other target.

3. Add `test-ai` row to CLAUDE.md Makefile table, noting it is non-gating, heavy, developer-run, and cannot be run by agents.

## Tests

- The two AI tests themselves are the deliverable, but they are env-gated and will not run under `make test`. Verification that they compile and are properly skipped happens via `make test` (which must stay green).
- No new fast unit tests needed -- the evaluators and utilities were fully tested in Phase 1.
