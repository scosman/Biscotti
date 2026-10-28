---
status: complete
---

# Phase 4: SpeechAnalyzer Session

## Overview

Add Apple's SpeechAnalyzer as the third live engine option, behind the same `LiveTranscriptionSession` contract, and let `live-bench run` replay through it. Phase 5 then compares it with the two Whisper options.

The phase starts with the spike the architecture names: does SpeechAnalyzer need speech-recognition permission or an app bundle, and can two analyzers run at once for the two tracks? The spike ran against two short clips made locally with `say`, as a throwaway package outside the repository:

- No permission and no bundle: an unbundled command-line process with `SFSpeechRecognizer` status `notDetermined` got results, and the status stayed `notDetermined`. No fallback app bundle is needed.
- The en-US model was already on the system (`installedLocales`), but `AssetInventory.status` reported `.supported` until the process requested it with `assetInstallationRequest(supporting:)`, which reserved en-US for that program in under a second. The reservation persists across runs of the same program. `live-bench` therefore needs a setup command that makes that request.
- Two analyzers with their own `SpeechTranscriber` run at once in one process, results interleaved, no errors. A forward jump in `bufferStartTime` makes the analyzer finalize the text before the jump by itself, and later results carry the new times.
- `finalizeAndFinish(through:)` and `finalize(through:)` never return when `through` is the end of the input received (the analyzer waits for more audio). `finalizeAndFinishThroughEndOfInput()` after ending the input returns in about 0.1 s.
- Volatile results carry one time range for their whole text; only final results have per-word `audioTimeRange` runs. With `[.volatileResults]` results come in bursts about every 4 s of audio (first text after about 4 s); with `.fastResults` added, about every second. In silence the analyzer reports nothing, and its finalization point does not move until later speech or the finish.
- `bestAvailableAudioFormat` is 16 kHz mono Int16. The model runs outside the process (the spike's footprint stayed under 7 MB).

## Steps

1. **`LiveRowBuilder`** (`LiveTranscriptModel/LiveRowBuilder.swift`, `package`): move the row logic out of `LocalAgreementReducer` unchanged (open row, tail row with ID reuse, the 1.5 s pause rule, `rowText`, changed-row reporting), so both engines build rows the same way.

   ```swift
   package struct LiveRowBuilder: Sendable {
       package static let rowPause: TimeInterval = 1.5
       package init(track: LiveTrack)
       package private(set) var tail: [TimedWord]
       package var currentRows: [LiveRow]
       package mutating func settle(_ words: some Collection<TimedWord>, forced: Bool = false)
       package mutating func setTail(_ words: [TimedWord])
       package mutating func closeOpenRow()
       /// Rows closed since the last call, plus current rows that differ from `before`, in time order.
       package mutating func takeChanges(since before: [LiveRow]) -> [LiveRow]
       package static func rowText(_ words: [TimedWord], startsRow: Bool) -> String
   }
   ```

   `LocalAgreementReducer` keeps its agreement state (tokens, committed words, prompt words, watermarks) and calls the builder.

2. **Shared session rules** (`LiveTranscription/LiveSessionRules.swift`): move `isSupported(_ tracks:)`, `isValidInterval(_:)` and `maximumUpdateInterval` out of `WhisperLiveSession` so both sessions validate configs the same way. Add `LiveSessionError.assetNotInstalled(String)` and `.engineUnavailable`.

3. **Engine boundary** (`LiveTranscription/SpeechTrackAnalyzer.swift`, no Speech import, so it builds and tests on macOS 15):

   ```swift
   struct SpeechInput: Sendable { var samples: [Float]; var startTime: TimeInterval? }  // nil continues the previous input
   struct SpeechResult: Sendable, Equatable { var words: [TimedWord]; var start, end: TimeInterval; var isFinal: Bool; var finalizedThrough: TimeInterval }
   enum SpeechAnalyzerEvent: Sendable, Equatable { case result(SpeechResult); case received(through: TimeInterval) }
   package protocol SpeechTrackAnalyzer: Sendable {
       var events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error> { get }
       func enqueue(_ input: SpeechInput) -> Bool          // false: the input queue was full, the audio is dropped
       func finish() async throws                         // end input, finalize everything; `events` then ends
       func cancel() async
   }
   package protocol SpeechTrackAnalyzerFactory: Sendable {
       func makeAnalyzers(for tracks: [LiveTrack], locale: String, vocabulary: [String]) async throws -> [LiveTrack: any SpeechTrackAnalyzer]
   }
   ```

4. **`SpeechTrackTranscript`** (`LiveTranscription/SpeechTrackTranscript.swift`): one track's results into rows and watermarks, through `LiveRowBuilder`.
   - A final result settles its words (the 1.5 s pause rule applies per word) and clears the tail; a volatile result replaces the tail with its text over its range.
   - `transcribedThrough` follows the end of the audio the analyzer has taken (`received`) and of every result: SpeechAnalyzer reports nothing in silence, so result ends alone would stop in every pause.
   - `settledThrough` follows `resultsFinalizationTime` of delivered results only, never past `transcribedThrough`, so it never runs ahead of the final text that backs it.
   - After the analyzer's timeline restarts (a start time on an input after the first), the first final result at or after the restart gets a leading space when it has none, so text across a short gap does not run together.
   - `finish(incomplete:through:)` closes the open row; when incomplete it first settles the tail and marks the changed rows `isIncomplete`.

5. **`SpeechAnalyzerLiveSession`** (`LiveTranscription/SpeechAnalyzerLiveSession.swift`, actor, implements `LiveTranscriptionSession`):
   - `@available(macOS 26, *) public init(fastResults: Bool = false)` uses the system analyzers; `package init(factory:clock:)` takes any factory and clock, so the session runs and is tested on macOS 15.
   - `start`: engine must be `.speechAnalyzer`; tracks and interval as Whisper; `.english` is `en-US`, `.locale(id)` passes through, `.detect` throws `languageUnsupported`. The factory checks the locale and the asset. One reader task per track forwards events to the actor.
   - `append`: the first chunk of a track, the first after a discontinuity, after a pause or after dropped audio carries `startTime`; the rest carry nil. A dropped input (full queue) opens a `queueOverflow` span, emitted as one gap when input is accepted again. A discontinuity emits a `captureGap` for the missing time. While paused, chunks are not sent; on resume one `paused` gap covers the time from the last chunk sent to the resumed chunk. Gaps do not move the watermarks: only the analyzer's results do.
   - `setUpdateInterval` validates and keeps the value; SpeechAnalyzer decides when it analyzes, so the interval has no effect.
   - `finish(timeout:)`: emits pending gaps, finishes every analyzer at once and waits for each track's events to end. Updates while finishing come only from `finish`, merged per track. On timeout or an analyzer error, the tail is settled and marked incomplete. A track that never got audio is cancelled without a finish.
   - An analyzer whose events end while running ends the session (the update stream finishes). `cancel()` ends everything.
   - `package var latestRevision` and `hasEnded` for the harness, as `WhisperLiveSession` has.

6. **System analyzer** (`LiveTranscription/SystemSpeechAnalyzer.swift`, `@available(macOS 26, *)`):
   - `SystemSpeechAnalyzerFactory(fastResults:)`: `SpeechTranscriber.isAvailable` or `engineUnavailable`; `supportedLocale(equivalentTo:)` or `languageUnsupported`; `AssetInventory.status(forModules:) == .installed` or `assetNotInstalled`; `bestAvailableAudioFormat(compatibleWith:considering:)` with the 16 kHz Float32 input.
   - Per track: `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.volatileResults] (+ .fastResults), attributeOptions: [.audioTimeRange])` in its own `SpeechAnalyzer(modules:options: .init(priority: .userInitiated, modelRetention: .lingering))`; vocabulary as `AnalysisContext.contextualStrings[.general]`; `prepareToAnalyze(in:)`; an `AsyncStream<AnalyzerInput>` with `.bufferingOldest(16)`; the volatile-range handler sends `received`; a task maps `transcriber.results` to `SpeechResult` (words from the `audioTimeRange` runs, whitespace-only runs joined to the next word).
   - `finish()`: end the input stream, then `finalizeAndFinishThroughEndOfInput()` (deviation: the spec's `finalizeAndFinish(through:)` never returns, see the spike).
   - `cancel()`: end the input, `cancelAndFinishNow()`.
   - `SpeechAnalyzerAssets`: `status(locale:)` and `install(locale:progress:)` through `AssetInventory`, for `live-bench` now and the app in phase 8.

7. **`LiveSampleConverter`** (`LiveTranscription/LiveSampleConverter.swift`, AVFoundation only): a persistent `AVAudioConverter` from 16 kHz mono Float32 to the analyzer's format; the plain conversion when rates match, the input-block conversion when they do not; `reset()` before a chunk that starts a run.

8. **Harness** (`live-bench`):
   - `run --option speechanalyzer` builds a `SpeechAnalyzerLiveSession` per clip with `language: .locale("en-US")`. It needs macOS 26 and the installed asset, checked before the memory baseline with messages that name what is missing and the command that fixes it.
   - `--fast-results` (SpeechAnalyzer only) adds `.fastResults`, so phase 5 can compare both reporting modes. `validate()` refuses `--model` and `--virtual-clock` with SpeechAnalyzer (it runs on its own time) and `--fast-results` with Whisper.
   - The manifest records `fast_results` and `locale` in its options and no model. Folder names gain `-fast`.
   - New `speech-assets [--locale en-US] [--install]`: prints whether the locale is supported and installed for `live-bench`, and with `--install` requests it through `AssetInventory`, printing progress.
   - `BenchError.speechAnalyzerNotBuilt` is replaced by `speechAnalyzerNeedsMacOS26`, `speechAssetNotInstalled` and `speechLocaleUnsupported`.

9. **`Tools/live_bench/report.py`**: `fast_results` joins the configuration key and title, so the two reporting modes are never pooled.

10. **Manual-test staleness:** the recordable `tx_*` steps are already `not-run`; confirm.

## Tests

`LiveTranscriptModelTests`: every existing reducer test passes unchanged after the builder moves out.

`SpeechAnalyzerMappingTests` (fake analyzer; no Speech framework call):
- `finalResultsBecomeSettledRows`: two final results settle in one row; a final after a 1.5 s pause opens a new row; the tail is cleared.
- `volatileResultReplacesTail`: successive volatile results replace the tail on the same row ID; settled text does not change.
- `resultTimesUseBufferStartTime`: a session started at 100 s sends the first input with start 100 and the next with nil; after a discontinuity at 130 s the input carries 130 and a `captureGap` covers the missing time; rows from the fake analyzer's timeline land at those times.
- `watermarksFollowTheAnalyzer`: `received` moves `transcribedThrough` only; `settledThrough` follows `resultsFinalizationTime` and never passes `transcribedThrough`.
- `textAfterARestartIsSeparated`: the first final after a restart gains a leading space when it joins the open row.

`SpeechAnalyzerLiveSessionTests` (fake analyzer, manual clock):
- `startValidatesConfig`: Whisper engine, unsupported tracks, invalid interval and Detect are refused; English reaches the factory as en-US; vocabulary is passed.
- `fullQueueReportsOneOverflowGap`: consecutive dropped inputs become one `queueOverflow` gap when input is accepted again, and that input carries its start time.
- `pauseEmitsOneGapAndRestartsTimeline`.
- `finishReturnsFinalRowsOutsideTheStream`: results produced by the analyzer's finish come back from `finish`, merged per track, and the stream ends.
- `finishTimeoutMarksTailIncomplete`.
- `trackWithoutAudioIsCancelledAtFinish`.
- `analyzerFailureEndsSession`.
- `cancelEndsStreamAndAnalyzers`.

`LiveSampleConverterTests`: Float32 to Int16 at 16 kHz keeps every sample; 16 to 48 kHz over several chunks yields about three times the frames; a run start resets the converter.

`SystemSpeechAnalyzerTests` (`.enabled` on macOS 26 only; no analyzer is created): words come from the `audioTimeRange` runs of an `AttributedString`, a run without a range takes the result's range, and a whitespace-only run joins the next word.

`LiveBenchTests`:
- `speechAnalyzerFlagsAreValidated`: `--model` and `--virtual-clock` with SpeechAnalyzer and `--fast-results` with Whisper are refused at parse time.
- `replayRunsASpeechAnalyzerSession`: a replay through `SpeechAnalyzerLiveSession` with a fake factory logs every update and writes `final.json`.

`Tools/live_bench/tests`: `test_report_keeps_fast_results_apart`.
