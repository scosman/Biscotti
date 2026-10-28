---
status: complete
---

# Phase 1: LiveTranscriptModel Target

## Overview

Add the `LiveTranscriptModel` target to `Packages/Transcription`. It depends on Foundation only and holds everything that readers of the live transcript and both engines share: the live types, the binary XPC codec for audio chunks, the snapshot, the `LiveTranscriptionSession` protocol, and `LocalAgreementReducer`, which turns repeated Whisper decodes of one track into append-only rows. Nothing uses the target yet; phase 2 (the Whisper session), phase 7 (XPC) and phase 8 (the service) build on it. No app, worker or UI code changes.

## Steps

1. **Package manifest** (`Packages/Transcription/Package.swift`):
   - Product `.library(name: "LiveTranscriptModel", targets: ["LiveTranscriptModel"])`.
   - Target `LiveTranscriptModel`, no dependencies, `path: "Sources/LiveTranscriptModel"`, `swiftSettings: warningsAsErrors`.
   - Test target `LiveTranscriptModelTests` depending on `LiveTranscriptModel`, `path: "Tests/LiveTranscriptModelTests"`.

2. **Live types** (`Sources/LiveTranscriptModel/LiveTypes.swift`), public with public memberwise initializers, as in the component document:
   - `LiveTrack` (`mic`, `system`, `mixed`), `LiveEngineKind` (`whisper`, `speechAnalyzer`): `String`, `Codable`, `Sendable`, `Hashable`.
   - `LiveLanguage` (`english`, `detect`, `locale(String)`): `Codable`, `Sendable`, `Hashable`.
   - `LiveRow` (`Codable`, `Sendable`, `Equatable`, `Identifiable`): `id`, `track`, `startTime`, `endTime`, `settledText`, `tailText`, `isClosed`, `isForcedBoundary`, `isIncomplete`. Computed `hasText`.
   - `LiveGap` with nested `Reason` (`queueOverflow`, `captureGap`, `paused`, `engineRestart`).
   - `LiveTrackUpdate`: `sessionID`, `generation`, `track`, `revision`, `rows`, `gaps`, `transcribedThrough`, `settledThrough`, `detectedLanguage`, `decodeMilliseconds`.
   - `LiveSessionConfig` (`Codable`, `Sendable`, `Equatable`): `sessionID`, `generation`, `engine`, `whisperModel`, `tracks`, `updateInterval`, `language`, `vocabulary`.

3. **Audio chunk and codec** (`Sources/LiveTranscriptModel/LiveAudioChunk.swift`):
   - `LiveAudioChunk` (`Sendable`, `Equatable`): `track`, `startTime`, `samples: [Float]`, `isDiscontinuity`, plus `duration` at `sampleRate = 16_000`.
   - `func encodedForXPC() -> Data`: an 8-byte little-endian `UInt64` header length, a JSON header `{track, startTime, isDiscontinuity, sampleCount}`, then the samples as little-endian Float32 bit patterns.
   - `init(xpcData: Data) throws(LiveAudioChunkCodingError)`: reads through `withUnsafeBytes` with bounds checks (works for `Data` slices), never traps on malformed input.
   - `LiveAudioChunkCodingError: Error, Equatable`: `truncatedHeader`, `malformedHeader`, `sampleCountMismatch(expected: Int, actual: Int)`.

4. **Snapshot** (`Sources/LiveTranscriptModel/LiveTranscriptSnapshot.swift`): `LiveTranscriptSnapshot` (`Sendable`, `Equatable`) with the component's fields. The initializer enforces the `includesTail` flag: when false it strips every row's `tailText` and drops rows left with no text; when true it drops only rows with no text at all (rows the reducer emptied when a tail retracted).

5. **Session protocol** (`Sources/LiveTranscriptModel/LiveTranscriptionSession.swift`): the protocol exactly as in the component document (`updates`, `start`, `append`, `setUpdateInterval`, `setPaused`, `finish(timeout:)`, `cancel`).

6. **Agreement reducer** (`Sources/LiveTranscriptModel/LocalAgreementReducer.swift`):
   - Public inputs `TimedWord` (`text`, `start`, `end`, `probability`) and `Hypothesis` (`words`, `windowStart`, `windowEnd`, absolute times), `Sendable`, `Equatable`.
   - Output `AgreementResult` (`rows: [LiveRow]` changed or created by this call, in time order; `trimPoint: TimeInterval?`).
   - `public struct LocalAgreementReducer: Sendable` with `init(track:)`, `mutating func reduce(_ hypothesis: Hypothesis) -> AgreementResult`, `mutating func finish() -> AgreementResult`, `mutating func resolveSilence(through:)`, and read-only `transcribedThrough`, `settledThrough`, `hasTail`.
   - `reduce` follows the component's eight steps: drop words ending at or before `committedEnd − 0.05`; drop duplicates of recent committed words (same normalized text and overlap of at least half the shorter word, or starts within 0.2 s); k = the longest common prefix with the previous hypothesis (normalized text equal, starts within 0.5 s); commit k words; the rest becomes the tail.
   - Rows: an internal open row (has settled words, not closed) and an optional tail row (tail only, used when the tail follows a pause of at least 1.5 s or no open row exists). A commit that starts 1.5 s or more after the open row's last settled word closes the open row and opens a new one, reusing the tail row's ID so the bubble keeps its identity. When a tail retracts from the tail row, that row is emitted once with no text and its ID is kept for the next new row. Only rows whose value changed are returned.
   - Trim point: the end of the last committed sentence-ending word (`.`, `?`, `!`, `。`, `？`, `！`) inside the window, or, when the window is over 25 s, the end of the last committed word inside it. Returned only when it is later than `windowStart`.
   - Forced boundary: when the window reaches 30 s and k = 0, commit the leading words that end before `windowEnd − 5 s`, set `isForcedBoundary` on the row that receives them, and trim at the last of them (or at the earlier of `windowEnd − 5 s` and the first remaining word's start when none qualify).
   - Watermarks: `transcribedThrough` is the latest window end (or silence); `settledThrough` is monotonic: the latest window end when no tail remains, otherwise the end of the last committed word. `resolveSilence(through:)` advances `transcribedThrough`, and `settledThrough` only when there is no tail.
   - `finish()` commits every tail word through the same row rules, closes the open row, and sets `settledThrough` to `transcribedThrough`. The reducer stays usable afterward, so the session can call it at a discontinuity.
   - Recent committed words older than `windowStart − 1 s` are pruned on each `reduce`, so memory stays bounded by the retained window.
   - `static func normalize(_:)`: lowercase, keep letters, digits and apostrophes (`'`, `’` mapped to `'`), drop other punctuation and symbols, collapse whitespace.

7. **Manual-test staleness:** confirm the recordable `tx_*` steps in `ManualTestApp/Results/manual_test_results.json` are `not-run` (they are already).

## Tests

`LocalAgreementReducerTests` (`Tests/LiveTranscriptModelTests/LocalAgreementReducerTests.swift`):
- `sharedPrefixOfTwoDecodesIsCommitted`: the common prefix of two decodes becomes settled text; the rest is tail.
- `disagreementCommitsNothing`: two decodes with different first words commit nothing; the tail shows the newest decode.
- `repeatedPhraseIsKeptWhenTimesDiffer`: a decode that keeps only the second "thank you" does not agree with the first; both occurrences end up settled.
- `repeatedWordJustAfterCommittedBoundaryIsKept`: committed "yes" ending at 1.0 s, a new "yes" at 1.1 to 1.3 s is kept.
- `silenceAdvancesSettledThrough`: `resolveSilence` advances both watermarks without a tail and only `transcribedThrough` with one; an empty decode advances `settledThrough` to the window end.
- `overlapWithCommittedTextIsRemovedAfterTrim`: after a sentence-end trim, re-decoded committed words with shifted times are not committed twice.
- `pauseOfOnePointFiveSecondsStartsNewRow`: a 1.5 s pause closes the open row and opens a new one; 1.4 s does not.
- `rowIDStaysStableAsTailChanges`: the open row keeps its ID across changing tails and when its tail settles.
- `tailAfterPauseKeepsItsRowWhenSettled`: a tail shown on its own row after a pause keeps that row ID once committed.
- `retractedTailEmptiesItsRowAndReusesItsID`: a tail row whose words move back onto the open row is emitted empty, and its ID is reused for the next new row.
- `settledTextIsAppendOnly`: 500 seeded runs of random hypotheses; every row's settled text only grows, closed rows never change, and committed word times never go backward.
- `forcedBoundaryAtThirtySecondsMarksRow`: with a 30 s window and no agreement, words ending before `windowEnd − 5 s` are committed, the row is marked, and the trim point is the last of them.
- `trimPointFollowsSentenceEnd`: the trim point is the end of the last committed sentence-ending word, and nil when none is inside the window.
- `trimPointFallsBackToLastCommittedWordAfterTwentyFiveSeconds`.
- `finishCommitsTailAndClosesRow`: `finish` commits the tail, closes the row, and settles through the window end.
- `normalizationIgnoresCaseAndPunctuation`: "Hello," agrees with "hello"; apostrophes are kept.

`LiveTypesCodecTests` (`Tests/LiveTranscriptModelTests/LiveTypesCodecTests.swift`):
- `chunkRoundTripsThroughXPCData`: track, start time, flag and samples (including negative, zero and extreme values) survive.
- `chunkDecodesFromDataSlice`: decoding works when the `Data` does not start at index 0.
- `malformedChunkDataThrows`: truncated header, bad JSON and a short sample payload each throw the matching error.
- `updateRoundTripsThroughJSON`: a `LiveTrackUpdate` with rows and gaps survives JSON.
- `configRoundTripsThroughJSON`: including each `LiveLanguage` case.

`LiveTranscriptSnapshotTests` (`Tests/LiveTranscriptModelTests/LiveTranscriptSnapshotTests.swift`):
- `snapshotWithoutTailStripsTailAndDropsEmptyRows`.
- `snapshotWithTailKeepsTailAndDropsOnlyEmptyRows`.
