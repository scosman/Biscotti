---
status: complete
---

# Phase 1.1: Package + Pure Value/Logic Core

## Overview

Create the `Packages/Transcription` SPM package and port the pure value types and logic from `experiments/ArgMaxKit`. This phase establishes the package structure with the `argmax-oss-swift` dependency pinned but only implements types that have no ML/engine dependency: configuration, transcript models, vocabulary formatting, output sanitization, error taxonomy, and model status. No engine, client, XPC, or CLI code.

## Steps

1. **Create `Packages/Transcription/Package.swift`** — `swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]`, warnings-as-errors via `-warnings-as-errors` unsafeFlag, platform macOS 15+. Declare the `argmax-oss-swift` dependency (pinned `from: "1.0.0"`) but the library target itself only imports Foundation (no WhisperKit/SpeakerKit imports this phase). Products: `Transcription` library. Test target: `TranscriptionTests`.

2. **Port `DiarizationStrategy`** to `Sources/Transcription/DiarizationStrategy.swift` — identical to experiment.

3. **Port `ProcessorConfig`** to `Sources/Transcription/ProcessorConfig.swift` — carry over from experiment, add the `ramAware(physicalMemory:)` static factory that picks quantized `_1307MB` + `sequentialLoading` on <= 8 GB, full-precision otherwise.

4. **Port `TranscriptWord`, `TranscriptSegment`, `TranscriptResult`** to `Sources/Transcription/TranscriptResult.swift` — essentially as-is from experiment `Models.swift`.

5. **Port `VocabularyFormatter`** to `Sources/Transcription/VocabularyFormatter.swift` — as-is from experiment.

6. **Create `TranscriptionError`** in `Sources/Transcription/TranscriptionError.swift` — the new error enum superseding `ArgMaxError`, with cases: `needsDownload`, `insufficientDisk(requiredBytes:availableBytes:)`, `downloadFailed(String)`, `modelLoadFailed(String)`, `workerUnavailable`, `workerInterrupted`, `invalidInput(String)`, `transcriptionFailed(String)`, `diarizationFailed(String)`. Conforms to `Error, Sendable, Equatable`.

7. **Create `ModelStatus`** in `Sources/Transcription/ModelStatus.swift` — enum with cases: `needsDownload`, `downloading(progress: Double)`, `compiling`, `loading`, `ready`, `running`, `error(TranscriptionError)`. Conforms to `Sendable, Equatable`.

8. **Create `TranscriptSanitizer`** in `Sources/Transcription/TranscriptSanitizer.swift` — `enum TranscriptSanitizer` with a static `sanitize(_:audioDuration:)` method. Drops segments whose `startTime >= audioDuration`. Clamps segments whose `endTime > audioDuration`. Derives confidence from word-level `probability` (mean); ignores segment-level `confidence` field. Optionally drops trailing single-word segments with very low average word probability.

9. **Update `Makefile`** — add `Packages/Transcription` to the `PACKAGES` variable so `make build` / `make test` cover it.

10. **Write tests** — see Tests section below.

## Tests

- **`ConfigTests`** — default config values, custom config, Codable round-trip, `DiarizationStrategy` raw values/cases, `ramAware` picks quantized+sequential at 8 GB, full-precision at 16 GB+.
- **`ResultCodableTests`** — `TranscriptWord`, `TranscriptSegment`, `TranscriptResult` JSON round-trip, nil fields, Identifiable conformance, empty segments, JSON field names.
- **`VocabularyFormatterTests`** — empty, whitespace-only, single term, multiple terms, trimming, truncation, budget limits, framing.
- **`SanitizerTests`** — drops segment past audio duration (52.5s start on 25.1s clip), keeps in-range, clamps endTime that exceeds duration, derives confidence from word probabilities (ignoring segment-level confidence==0), drops low-confidence trailing single-word segments.
