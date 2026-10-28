---
status: complete
---

# Phase 2: LiveTranscription Target (Whisper Session)

## Overview

Add the `LiveTranscription` target to `Packages/Transcription`. It holds `WhisperLiveSession`, the in-process Whisper implementation of `LiveTranscriptionSession`: per-track audio windows, the scheduler that runs one decode at a time, silence handling, discontinuities, pausing, the 45 s retention cap and finishing with a deadline. Decoding goes through a `LiveDecoder` protocol; `WhisperKitLiveDecoder` wraps a loaded `WhisperKit`, and every gating test uses a fake decoder and a manual clock, so no model is loaded. The replay harness (phase 3) and the worker (phase 7) build on this target. The SpeechAnalyzer session is phase 4.

## Steps

1. **Package manifest** (`Packages/Transcription/Package.swift`):
   - Product `.library(name: "LiveTranscription", targets: ["LiveTranscription"])`.
   - Target `LiveTranscription`, dependencies `LiveTranscriptModel`, `Transcription` (for `VocabularyFormatter`) and the `WhisperKit` product; `path: "Sources/LiveTranscription"`, `warningsAsErrors`.
   - Test target `LiveTranscriptionTests` depending on `LiveTranscription`, `LiveTranscriptModel`, `Transcription` and `WhisperKit`.

2. **Model additions** (`LiveTranscriptModel`):
   - `LiveTrackUpdate.merge(_ later:)`: rows keep their latest version by ID (time order), gaps accumulate, revision, watermarks and the optional fields take the later value. The finish result uses it; phase 7 reuses it to merge pending updates.
   - `LocalAgreementReducer.settledText(before time:) -> String`: the last 100 characters of settled text whose words end by `time`, starting at a word. Settled words are kept in a small list, pruned on each `reduce` to the words inside the window plus enough earlier words for 100 characters.

3. **Decoder contract** (`Sources/LiveTranscription/LiveDecoder.swift`):

   ```swift
   public protocol LiveDecoder: Sendable {
       func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult
   }
   public struct LiveDecodeOptions: Sendable, Equatable {
       public var language: String?          // nil: detect
       public var vocabularyPrompt: String?  // VocabularyFormatter output
       public var settledContext: String     // settled text before the window
   }
   public struct LiveDecodeResult: Sendable, Equatable {
       public var hypothesis: Hypothesis     // absolute times
       public var language: String?          // the language the decoder used or detected
   }
   ```

4. **Errors** (`LiveSessionError.swift`): `alreadyStarted`, `unsupportedEngine(LiveEngineKind)`, `noTracks`, `languageUnsupported(String)`.

5. **Helpers:**
   - `SessionClock.swift`: wraps any `Clock<Duration>` as `elapsed()` and `sleep(for:)` closures, so the session is not generic.
   - `AudioLevel.swift`: RMS through Accelerate and the −45 dBFS silence test.

6. **Track audio** (`TrackAudio.swift`), a value type per track:
   - `runs: [Run]` (start time, samples, gaps before it). `runs[0]` is the decode window; later runs follow a gap (discontinuity, pause or overflow) and wait until the window is finished.
   - `decodedCount`: samples at the start of the window that a decode covers or is covering. `beginDecode()` marks the whole window and returns a copy, so audio appended during a decode is new audio.
   - `append`, `startRun(at:samples:gap:)`, `trimWindow(before:)` (never past the decoded part), `clearWindow()`, `advanceToNextRun() -> [LiveGap]`.
   - `enforceRetentionLimit()`: when all runs exceed 45 s, drop the oldest undecoded audio. A drop inside the window splits it at the decoded part, so a decode in flight is never affected; the dropped stretch becomes a `queueOverflow` gap on the next run. Contiguous overflow gaps merge.

7. **Track state** (`TrackState.swift`): the window, the reducer, `lastDecodeAt`, trailing silence (from chunk RMS) and whether the confirming decode ran. `receive(_ chunk:)` starts a run for a discontinuity (with a `captureGap` for any time jump) and applies the cap. `nextWork(now:interval:)` returns one of:
   - `finishWindow(decode:)` when a later run waits (decode first if the window has undecoded audio that is not silence without a tail),
   - with a tail: `commitTail` after 2 s of silence, a confirming `decode` after 1 s, otherwise a `decode` when due and the new audio is not silent,
   - without a tail: when due, `skipSilence` for silent new audio, otherwise `decode`.
   - Due means `updateInterval` since the last decode and at least 0.5 s of new audio.

8. **Whisper session** (`WhisperLiveSession.swift` and extensions), `public actor WhisperLiveSession: LiveTranscriptionSession`:
   - `public init(decoder: any LiveDecoder, clock: some Clock<Duration> = ContinuousClock(), scheduling: Scheduling = .automatic)`. `.automatic` runs a task that sleeps 100 ms and runs a pass; `.manual` runs nothing, and the owner calls `public func runScheduledWork()` (tests, and the harness's virtual clock).
   - A lane (an async mutex) serializes passes and finishing, so at most one decode runs at a time.
   - `start` validates the config (Whisper engine, tracks, language), formats the vocabulary prompt once and starts the loop.
   - `append` ignores chunks outside `.running` and for unknown tracks; while paused it records the dropped span per track; the first chunk after a pause starts a run with one `paused` gap.
   - A pass: for each track, do the immediate work (finish a window without decoding, commit a tail, skip silence); then run the one due decode whose track was decoded longest ago (ties go to config order).
   - A decode: options carry the fixed or locked language, the vocabulary prompt and `reducer.settledText(before: windowStart)`. The result locks the language under Detect once it has words, drops an unsure last word (probability < 0.3) except in final decodes, feeds the reducer and trims the window at the trim point. A decode error ends the session: the update stream finishes.
   - Updates: one per change, with a session-wide revision, the reducer's watermarks, the locked language and the decode time. During finishing, updates merge into the finish result instead of the stream.
   - `finish(timeout:)`: stops accepting audio, then in the lane finishes every track (each window with a final decode where needed, its gaps, `reducer.finish()`, the paused gap). A timeout task races it on the session clock; on timeout, `reducer.finish()` rows are marked `isIncomplete`, waiting gaps are included and the late decode result is ignored.
   - `cancel()` stops everything, ends the stream and resumes a waiting `finish` with no updates.
   - Logging with `Logger(subsystem: "net.scosman.biscotti", category: "live")`: start, pause, overflow, failure and finish at `.notice`; no transcript text.

9. **WhisperKit decoder** (`WhisperKitLiveDecoder.swift`), `public actor` wrapping a loaded `WhisperKit`:
   - `decodingOptions(for:)`: language or detect, word timestamps, temperature 0 with no fallback, skip special tokens, suppress blank, thresholds 0.6 / 2.4 / −1.0.
   - Prompt tokens: vocabulary first, then the context, filtered below `specialTokenBegin`, capped at WhisperKit's prompt limit (111 tokens; the spec's 200 would let WhisperKit keep only the last 111, which drops the vocabulary first).
   - `words(in:windowStart:windowEnd:)`: drop segments with `noSpeechProb > 0.6` and `avgLogprob < −1.0`, move word times to the recording timeline, drop words ending after the window end and empty words.

10. **Manual-test staleness:** confirm the recordable `tx_*` steps are `not-run` (they are).

## Tests

`WhisperLiveSessionTests` (fake decoder, manual clock, manual scheduling unless noted):
- `neverRunsTwoDecodesAtOnce`: two concurrent passes and a finish, with a held decoder, run their decodes one after another.
- `alternatesTracksWhenBothDue`: the track decoded longer ago goes first, then the other.
- `respectsUpdateInterval`: decodes only after the interval, and only with 0.5 s of new audio.
- `silenceSkipsDecodesAndConfirmsTail`: one confirming decode after 1 s of silence settles the tail; later silent intervals skip decoding and advance both watermarks.
- `unconfirmedTailIsCommittedAfterTwoSecondsOfSilence`.
- `discontinuityCommitsAndRestartsTrack`: the audio before the gap gets a final decode and closes its row, the gap is emitted, the next window starts at the new time.
- `fallingBehindDropsOldestAndReportsOverflow`: 50 s without decodes leaves a 5 s `queueOverflow` gap and a 45 s window.
- `pauseEmitsOneGapAndResumesEmpty`.
- `detectLocksLanguageAfterFirstDecode`: detect until a decode has words, then that language; updates report it.
- `promptCombinesVocabularyAndCommittedTail`: the vocabulary prompt and the settled text before the window reach the decoder.
- `unsureLastWordStaysOutOfTheTailUntilTheFinalDecode`.
- `finishDecodesRemainingAudioAndClosesRows`: final rows come from `finish`, not the stream, and the stream ends.
- `finishTimeoutMarksTailIncomplete` (continuous clock, 100 ms timeout, decoder that never answers).
- `decodeFailureEndsTheSession`.
- `startValidatesTheConfig`: second start, SpeechAnalyzer engine, no tracks, unknown locale.
- `automaticSchedulingDecodesOnItsOwn` (continuous clock).

`TrackAudioTests`:
- `trimNeverRemovesUndecodedAudio`.
- `overflowDropsUndecodedAudioAfterTheDecodedPart`.
- `overflowContinuesIntoLaterRunsAndKeepsTheirGaps`.
- `repeatedOverflowMergesIntoOneGap`.

`WhisperKitLiveDecoderTests` (no model):
- `segmentsWithoutSpeechAreDropped`.
- `wordTimesMoveToTheRecordingTimeline`.
- `wordsEndingAfterTheWindowAreDropped`.
- `decodingOptionsFollowTheLiveSettings`.
- `promptKeepsVocabularyFirstWithinTheLimit`.

`LiveTranscriptModelTests` additions:
- `mergeKeepsLatestRowVersionAndAccumulatesGaps`.
- `settledTextBeforeTheWindowFeedsThePrompt`.
