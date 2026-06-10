---
status: complete
---

# Phase 3: TranscriptionService Module

## Overview

Add the `TranscriptionService` module to `BiscottiKit`. This module provides the app-level
transcription orchestration on top of the `Transcription.Transcriber` engine: resolve audio paths
from DataStore, ensure model readiness (with status messages), run `processAudio`, persist and
promote the resulting transcript, and expose per-meeting `JobStatus` for the UI. Everything is
behind a `Transcribing` protocol seam so tests run with a fake engine and in-memory DataStore.

## Steps

### 1. Add `Transcribing` protocol and `JobStatus` enum (`Sources/TranscriptionService/Transcribing.swift`)

Define the seam over `Transcription.Transcriber`:

```swift
public protocol Transcribing: Sendable {
    func ensureModelsDownloaded(status: (@Sendable (String) -> Void)?) async throws
    func processAudio(mic: URL, system: URL, customVocabulary: [String]) async throws -> TranscriptResult
}
```

Re-export `TranscriptResult` from `Transcription` so downstream consumers don't need a direct
dependency on the `Transcription` package.

### 2. Add `JobStatus` enum (`Sources/TranscriptionService/JobStatus.swift`)

```swift
public enum JobStatus: Sendable, Equatable {
    case idle
    case downloadingModel(message: String)
    case transcribing
    case completed
    case failed(message: String, retriable: Bool)
}
```

### 3. Add `TranscriptionServiceError` enum (`Sources/TranscriptionService/TranscriptionServiceError.swift`)

Typed errors for the service layer:

```swift
public enum TranscriptionServiceError: Error, Sendable, Equatable {
    case noAudioFiles
    case meetingNotFound(UUID)
}
```

### 4. Add `TranscriptionService` class (`Sources/TranscriptionService/TranscriptionService.swift`)

`@MainActor @Observable` class implementing:

- `jobs: [UUID: JobStatus]` (per-meeting status, observable)
- `init(store: DataStore, engine: any Transcribing)`
- `transcribe(meetingID:) async` -- resolve paths, ensure models, run processAudio, persist + promote
- `reTranscribe(meetingID:) async` -- same path, creates a new transcript version
- Single in-flight guard (one job at a time in MVP)

The `transcribe` flow:
1. Set `jobs[id] = .downloadingModel(message: "Preparing...")`
2. Call `store.audioPaths(meetingID:)` -- if nil, set `.failed` and return
3. Call `engine.ensureModelsDownloaded { msg in jobs[id] = .downloadingModel(message: msg) }`
4. Set `jobs[id] = .transcribing`
5. Call `engine.processAudio(mic:system:customVocabulary: [])`
6. Call `store.addTranscript(result, vocabularyUsed: [], mappedEventIdentifier: nil, to: id)`
7. Call `store.setPreferredTranscript(transcriptID, for: id)`
8. Set `jobs[id] = .completed`

Errors map to `.failed(message:, retriable:)`. TranscriptionError cases `workerInterrupted`,
`downloadFailed`, `needsDownload` are retriable; others are not.

### 5. Update `Package.swift`

- Add `TranscriptionService` target depending on `DataStore` and `Transcription` (package).
- Add `TranscriptionServiceTests` test target.
- Add `TranscriptionService` library product.

### 6. Write `FakeTranscriber` test helper (`Tests/TranscriptionServiceTests/FakeTranscriber.swift`)

A configurable fake implementing `Transcribing`:
- Returns a canned `TranscriptResult` on success
- Can be configured to throw specific errors
- Tracks method calls for verification

### 7. Write `TranscriptionService` tests (`Tests/TranscriptionServiceTests/TranscriptionServiceTests.swift`)

Cover the MVP flow per architecture and functional spec.

## Tests

- **testTranscribeSuccess**: transcribe resolves paths, calls engine, persists transcript, promotes
  it, and sets status to `.completed`.
- **testTranscribeNoAudioFiles**: transcribe with a meeting that has no audio sets
  `.failed(retriable: false)`.
- **testTranscribeMeetingNotFound**: transcribe with unknown meeting ID sets
  `.failed(retriable: false)`.
- **testTranscribeDownloadFailed**: engine throws `downloadFailed` -> `.failed(retriable: true)`.
- **testTranscribeWorkerInterrupted**: engine throws `workerInterrupted` -> `.failed(retriable: true)`.
- **testTranscribeTranscriptionFailed**: engine throws `transcriptionFailed` ->
  `.failed(retriable: false)`.
- **testReTranscribeAddsNewVersion**: re-transcribe creates a second transcript version and promotes it.
- **testTranscribeStatusProgression**: verify status transitions through downloadingModel -> transcribing -> completed.
- **testSingleInFlightGuard**: second transcribe call while one is in-flight sets `.failed` or is
  rejected cleanly.
- **testTranscribeEnsureModelsCalledBeforeProcess**: verify `ensureModelsDownloaded` is called
  before `processAudio`.
