---
status: complete
---

# Phase 1.2: Engine seam + in-process engine + merge + status machine

## Overview

Defines the `TranscriptionEngine` protocol (the testable seam), implements `InProcessTranscriptionEngine` (refactored `ArgMaxProcessor` behind the protocol), adds the two-stream audio merge logic, and wires `ModelStatus` transitions. Links `argmax-oss-swift` products (WhisperKit + SpeakerKit) to the Transcription target. All ML calls are behind the engine seam so merge logic and status machine are testable with stubs.

## Steps

1. **Update `Package.swift`**: Link WhisperKit and SpeakerKit products to the `Transcription` target. Add a test fixture resource bundle for merge tests.

2. **Create `TranscriptionEngine.swift`**: Define the `TranscriptionEngine` protocol (Sendable, transport-friendly: paths in, Codable result out) with `ensureModelsDownloaded(progress:)`, `processAudio(micPath:systemPath:mergedPath:config:customVocabulary:)`, `unloadModels()`, `status()`.

3. **Create `AudioMerger.swift`**: Pure function that takes two mono 16 kHz `[Float]` arrays (mic + system) with stream labels, sums/normalizes them to one `[Float]`, and retains label metadata (which sample ranges came from which stream). Handles single-stream and merged-only inputs. Validates: at least one input non-empty; empty/zero-sample throws `invalidInput`.

4. **Create `ModelStatusMachine.swift`**: An actor managing `ModelStatus` state transitions with validation (e.g., can only go to `downloading` from `needsDownload` or `error`). Observable/queryable.

5. **Create `DiskSpaceChecker.swift`**: A small utility (behind a protocol for testability) that checks available disk space against a required threshold, throwing `insufficientDisk` if needed.

6. **Create `InProcessTranscriptionEngine.swift`**: An actor conforming to `TranscriptionEngine`. Refactors `ArgMaxProcessor` logic: validates inputs, runs the merge via `AudioMerger`, does disk-space pre-check before download, drives `ModelStatus` transitions, runs STT -> diarize -> merge -> sanitize, supports `sequentialLoading` unload-between for 8 GB.

7. **Create test fixture audio files**: Two tiny mono WAV files (mic + system) as bundled resources for merge tests.

8. **Create `MergeTests.swift`**: Tests for `AudioMerger`: two mono arrays -> one 16 kHz merged array of expected length; labels retained; single-stream input accepted; empty/zero-sample -> `invalidInput`.

9. **Create `StatusMachineTests.swift`**: Tests for the status state machine: `needsDownload -> downloading(progress) -> compiling -> loading -> ready -> running -> ready` transitions; invalid transitions; error recovery.

## Tests

- `MergeTests`: Two mono fixtures merged to expected length; labels retained; single-stream works; empty/zero-sample throws `invalidInput`.
- `StatusMachineTests`: Full lifecycle transitions; invalid transitions rejected; error state recovery.
