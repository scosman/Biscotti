---
status: complete
---

# Phase 8: ArgMaxKit (E3)

## Overview

Build the ArgMaxKit SPM package at `/experiments/ArgMaxKit/` -- a library wrapping WhisperKit (STT) and SpeakerKit (diarization) from `argmax-oss-swift` behind a clean `processAudio(URL) -> TranscriptResult` API, plus a CLI harness for manual testing. This implements R3's recommendation: free-tier models (`openai_whisper-large-v3_turbo` + Pyannote v4 community-1), custom vocabulary via `promptTokens`, sequential model loading for memory efficiency, and a rich Codable transcript output capturing segments, word timings, speaker IDs, and centroid embeddings for cross-file speaker matching. XPC isolation is deferred to the real app; the experiment validates the SDK integration and API shape.

## Steps

### 1. SPM package scaffold (`Package.swift`)
- Create `experiments/ArgMaxKit/Package.swift` with:
  - Platform: macOS 15.0
  - Dependency: `argmax-oss-swift` v1.0.0+
  - Library product `ArgMaxKit` (target depends on WhisperKit, SpeakerKit)
  - Executable product `argmaxkit-cli` (depends on ArgMaxKit + swift-argument-parser)
  - Test target `ArgMaxKitTests` (depends on ArgMaxKit)
- Swift 6.2, strict concurrency enabled.

### 2. Public model types (`Sources/ArgMaxKit/Models.swift`)
- `TranscriptResult`: id, createdAt, modelVersion, language, speakerCount, segments, speakerEmbeddings, processingDuration. Sendable + Codable.
- `TranscriptSegment`: id, speakerID, speakerLabel, startTime, endTime, text, confidence, noSpeechProbability, words. Sendable + Codable + Identifiable.
- `TranscriptWord`: word, startTime, endTime, probability, speakerID. Sendable + Codable.
- `ProcessorConfig`: sttModel, sttModelRepo, enableWordTimestamps, diarizationStrategy, sequentialLoading. Sendable + Codable with a `default` static.
- `DiarizationStrategy` enum: `.subsegment`, `.segment`.

### 3. Core processor (`Sources/ArgMaxKit/ArgMaxProcessor.swift`)
- `public actor ArgMaxProcessor`:
  - `init(config: ProcessorConfig = .default) throws`
  - `func processAudio(_ file: URL, customVocabulary: [String] = []) async throws -> TranscriptResult`
    - Loads audio via `AudioProcessor.loadAudioAsFloatArray`
    - Runs WhisperKit transcription with `DecodingOptions(wordTimestamps:, promptTokens:)`
    - Runs SpeakerKit diarization
    - Merges via `diarization.addSpeakerInfo(to:)`
    - Packages into `TranscriptResult`
  - `func ensureModelsDownloaded() async throws`
  - `func unloadModels() async`
  - `func isAvailable() async -> Bool`
- Helper: `VocabularyFormatter` to convert `[String]` vocabulary list into a natural-language prompt string.

### 4. Error types (`Sources/ArgMaxKit/ArgMaxError.swift`)
- `ArgMaxError` enum with cases: `audioLoadFailed`, `transcriptionFailed`, `diarizationFailed`, `modelLoadFailed`, `invalidAudioFile`.

### 5. CLI harness (`Sources/argmaxkit-cli/CLI.swift`)
- Uses swift-argument-parser.
- Command: `argmaxkit-cli <audio-file>` with options:
  - `--model` (default: `large-v3_turbo`)
  - `--vocab` (comma-separated custom vocabulary)
  - `--json` flag to output raw JSON
  - `--sequential` flag for sequential model loading
- Loads the processor, calls `processAudio`, prints formatted transcript or JSON.

### 6. Unit tests (`Tests/ArgMaxKitTests/`)
- `TranscriptResultTests.swift`:
  - Codable round-trip for `TranscriptResult`, `TranscriptSegment`, `TranscriptWord`
  - Default values and identifiable conformance
  - JSON encoding/decoding with expected field names
- `ProcessorConfigTests.swift`:
  - Default config values are correct
  - Custom config round-trips through Codable
  - DiarizationStrategy raw values
- `VocabularyFormatterTests.swift`:
  - Empty vocabulary produces nil prompt
  - Single term formats correctly
  - Multiple terms format into natural language
  - Long vocabulary list is truncated to fit token budget

### 7. VALIDATION.md (V3 manual test script)
- Prerequisites: built CLI, internet for model download
- Steps: download models, run on a real audio file, verify transcript JSON shape, verify speaker segments, test custom vocabulary, measure timing/memory

## Tests

| Test | What it validates |
|------|-------------------|
| `testTranscriptResultCodable` | TranscriptResult encodes to JSON and decodes back losslessly |
| `testTranscriptSegmentFields` | TranscriptSegment has all expected fields with correct types |
| `testTranscriptWordCodable` | TranscriptWord round-trips through JSON |
| `testSpeakerEmbeddingsCodable` | Dictionary of [Int: [Float]] speaker embeddings survives Codable |
| `testDefaultProcessorConfig` | Default config has expected model name, repo, and settings |
| `testProcessorConfigCodable` | ProcessorConfig round-trips through Codable |
| `testDiarizationStrategyRawValues` | Enum raw values are "subsegment" and "segment" |
| `testEmptyVocabularyReturnsNil` | Empty array produces nil prompt string |
| `testSingleTermVocabulary` | Single term formats correctly |
| `testMultipleTermsVocabulary` | Multiple terms joined into natural language prompt |
| `testVocabularyTruncation` | Very long vocabulary list is truncated to stay within token budget |
| `testArgMaxErrorDescriptions` | All error cases have useful descriptions |
