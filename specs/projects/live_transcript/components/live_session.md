---
status: complete
---

# Component: Live Session

## Purpose and scope

The engine-side core, in two new targets of `Packages/Transcription`:

- **`LiveTranscriptModel`** (Foundation only): the shared types, the snapshot, the session protocol and the agreement reducer that turns repeated Whisper decodes into settled text.
- **`LiveTranscription`**: the Whisper session with its scheduler. The SpeechAnalyzer session the experiment compared is on the reference branch.

The XPC worker, the app and the replay harness all use this code. `LiveTranscriptionSession` is the only engine interface: the in-process sessions implement it, and so does the app's XPC proxy.

Not in scope: XPC transport ([transcriber_worker](transcriber_worker.md)), audio capture and resampling ([live_transcription_service](live_transcription_service.md)), UI.

## Public interface

```swift
public enum LiveTrack: String, Codable, Sendable { case mic, system, mixed }
public enum LiveEngineKind: String, Codable, Sendable { case whisper }   // the reference branch adds speechAnalyzer
public enum LiveLanguage: Codable, Sendable, Equatable { case english, detect, locale(String) }

public struct LiveAudioChunk: Sendable, Equatable {
    public var track: LiveTrack
    public var startTime: TimeInterval    // recording timeline
    public var samples: [Float]           // 16 kHz mono
    public var isDiscontinuity: Bool      // true for the first chunk after a gap
    public var isBackfill: Bool           // handed over well behind the newest audio (second UI review)
}

public struct LiveRow: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID                   // stable for the row's lifetime
    public var track: LiveTrack
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var settledText: String        // append-only
    public var tailText: String           // replaced on every update; empty once closed
    public var isClosed: Bool
    public var isForcedBoundary: Bool
    public var isIncomplete: Bool         // set when finish timed out
}

public struct LiveGap: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable { case queueOverflow, captureGap, paused, engineRestart }
    public var track: LiveTrack
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var reason: Reason
}

public struct LiveTrackUpdate: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var generation: Int
    public var track: LiveTrack
    public var revision: Int
    public var rows: [LiveRow]            // rows created or changed since the last update, in time order
    public var gaps: [LiveGap]
    public var transcribedThrough: TimeInterval   // audio decoded at least once
    public var settledThrough: TimeInterval       // audio resolved: settled text, processed silence or a recorded gap
    public var detectedLanguage: String?
    public var decodeMilliseconds: Double?
}

public struct LiveSessionConfig: Codable, Sendable {
    public var sessionID: UUID
    public var generation: Int
    public var engine: LiveEngineKind
    public var whisperModel: String?      // folder name, e.g. "openai_whisper-large-v3-v20240930_626MB"
    public var tracks: [LiveTrack]        // [.mic, .system] or [.mixed]
    public var updateInterval: TimeInterval   // 1, 2 or 4; chosen by the experiment
    public var language: LiveLanguage
    public var vocabulary: [String]
}

public protocol LiveTranscriptionSession: Sendable {
    var updates: AsyncStream<LiveTrackUpdate> { get }
    func start(_ config: LiveSessionConfig) async throws
    func append(_ chunk: LiveAudioChunk) async
    func setUpdateInterval(_ seconds: TimeInterval) async
    func setPaused(_ paused: Bool) async
    func finish(timeout: Duration) async -> [LiveTrackUpdate]   // final rows; tail marked incomplete on timeout
    func cancel() async
}

public struct LiveTranscriptSnapshot: Sendable, Equatable {
    public var sessionID: UUID
    public var revision: Int
    public var captureWatermark: TimeInterval
    public var transcribedThrough: TimeInterval
    public var settledThrough: TimeInterval
    public var rows: [LiveRow]            // time order across tracks
    public var gaps: [LiveGap]
    public var includesTail: Bool
}
```

`LiveAudioChunk` has a binary XPC codec (`encodedForXPC() -> Data`, `init(xpcData:)`): an 8-byte header length, a small JSON header (track, start time, flag, count), then raw little-endian Float32 samples.

## The agreement reducer

`LocalAgreementReducer` is a pure value type, one per track, with no clock and no audio. It implements LocalAgreement-2 from [Whisper-Streaming](https://arxiv.org/abs/2307.14743) with timestamp-aware matching.

Input per decode:

```swift
struct TimedWord: Equatable { var text: String; var start: TimeInterval; var end: TimeInterval; var probability: Float }
struct Hypothesis { var words: [TimedWord]; var windowStart: TimeInterval; var windowEnd: TimeInterval }  // absolute times
```

State: committed words, `committedEnd`, the previous uncommitted hypothesis, and the open row.

Each decode:

1. **Drop the already-committed region:** remove hypothesis words whose `end ≤ committedEnd − 0.05`.
2. **Remove duplicates of committed words:** a hypothesis word is a duplicate only when its normalized text equals a committed word's and the two cover the same audio: their time ranges overlap by at least half of the shorter word, or their starts differ by at most 0.2 s. Matching text near the boundary is not enough: a speaker who says "yes" again just after a committed "yes" keeps both.
3. **Agree:** k = the length of the longest common prefix between the previous hypothesis and this one, comparing normalized tokens and requiring each pair's start times to differ by at most 0.5 s. Matching on time keeps a phrase a speaker repeats.
4. **Commit** the first k words, using this decode's text and times.
5. The rest becomes the new previous hypothesis and the tail.
6. **Rows:** committed words join the open row unless one of these closes it first; then the open row closes (`isClosed = true`) and a new row opens, with the tail row's `UUID` when there is one, otherwise a new one (`LiveRowBuilder`):
   - the gap from the open row's last word to the new word is at least 1.5 s;
   - the row is at least 8 s long and its last word ends a sentence;
   - the row is at least 20 s long;
   - the other track started speaking inside the row (`breakRow(at:)`), and the new word starts at or after that time.

   Tail words split by the same rules: those the open row would take show in it, the rest on the tail's own row. The last three rules were added in UI review on 25 October 2026, so rows in start-time order read like a conversation.
   **Speech start:** the reducer reports `latestSpeechStart`, the start of its newest word (settled or tail) that follows a 1.5 s pause, or its first word. `WhisperLiveSession`, which sees both tracks, breaks the other track's row there whenever it moves on. Rows split by length or by a break are not speech starts, so two tracks never keep splitting each other.
7. **Trim point:** return the end of the last committed word that ends a sentence (`.`, `?`, `!`), or, when retained audio is over 25 s, the end of the last committed word.
8. **Forced boundary:** when retained audio reaches 30 s and k = 0, commit every hypothesis word ending before `windowEnd − 5 s`, set `isForcedBoundary` on its row, and trim there.

`finish()` commits every word of the last hypothesis and closes the row. Normalization lowercases, removes punctuation except apostrophes, and collapses whitespace.

## Whisper session

`WhisperLiveSession` (actor) implements `LiveTranscriptionSession`. It decodes through a `LiveDecoder` protocol, so tests use a fake:

```swift
protocol LiveDecoder: Sendable {
    func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> Hypothesis
}
```

`WhisperKitLiveDecoder` wraps the shared `WhisperKit` instance (see [transcriber_worker](transcriber_worker.md)).

**Per-track state:** retained samples from `bufferStart`, the time of the last decode, samples added since then, and a reducer.

**Scheduler:** a single task checks every 100 ms and runs at most one decode at a time.

- A track is due when at least `updateInterval` has passed since its last decode and at least 0.5 s of new audio has arrived.
- When both tracks are due, the one decoded longer ago goes first.
- **Silence:** if the new audio's RMS is below −45 dBFS and the track has no tail, the decode is skipped and both `transcribedThrough` and `settledThrough` advance. If it has a tail, one confirming decode runs after 1 s of silence; if the tail is still unconfirmed after 2 s of silence, it is committed.
- **Discontinuity:** a chunk with `isDiscontinuity` makes the track decode and commit everything before the gap, then restart with an empty buffer at the new start time. The gap is emitted.
- **Hard cap:** retained audio over 45 s (decodes falling behind) drops the oldest undecoded audio and emits a `queueOverflow` gap, silent when every dropped 250 ms frame was. Since the second UI review, the app hands a track's audio over only up to 36 s past its transcribed time, so with the 4 s in transit the session stays under the cap ([live_transcription_service](live_transcription_service.md#audio-pump)).
- **Paused:** incoming audio is dropped and emitted as one `paused` gap, silent when every dropped chunk was; on resume, tracks restart empty.

**Decode options** (`DecodingOptions`):

| Option | Value |
|---|---|
| `language` | `"en"` for English. For Detect, nil with `detectLanguage: true` until the first non-empty decode, then that language is locked |
| `wordTimestamps` | true |
| `temperature`, `temperatureFallbackCount` | 0, 0 |
| `skipSpecialTokens`, `suppressBlank` | true, true |
| `noSpeechThreshold`, `compressionRatioThreshold`, `logProbThreshold` | 0.6, 2.4, −1.0 |
| `promptTokens` | None: live decodes are unprompted (`WhisperKitLiveDecoder.defaultPrompt` is `.none`). With argmax-oss-swift 1.1.0, a prompt switches off WhisperKit's timestamp rules on multilingual models, so live text has no custom vocabulary ([research](../../../research/live_transcription/README.md#vocabulary)). The original design, `VocabularyFormatter.formatPrompt(vocabulary)` followed by the last 100 characters of committed text, capped at 200 tokens (vocabulary first), stays available as `LiveDecoderPrompt.vocabularyAndSettledText` for re-measurement |

**Filtering:** segments with `noSpeechProb > 0.6` and `avgLogprob < −1.0` are dropped. Words that end after the window end are dropped. The last word of a hypothesis is dropped when its probability is below 0.3; this applies only to the tail, never to committed text.

**Mixed mode:** the session has one `.mixed` track; the pump already sums the tracks. Mixed rows carry no speaker, so the app shows them without labels or copy prefixes.

**Finish:** stop accepting chunks, decode each track's retained audio once, call `reducer.finish()`, and return the final rows. On timeout, return what exists with the open row marked `isIncomplete`.

**Non-speech annotations** (hardware review, 25 October 2026). `WhisperKitLiveDecoder` drops Whisper's descriptions of sounds before the reducer sees a decode (`NonSpeechAnnotations`): words in "[…]", "(…)" or "*…*", even when split across words, and words made only of punctuation or symbols (a dash or dots left beside one, a music note; a lone combining mark such as a Thai tone mark stays). An opener with no closer within six words or 3 s is not an annotation, and only the opener goes, so a stray "(" or "*" cannot take the rest of a decode with it. An annotation the decode's last words leave open is left out and its start reported (`LiveDecodeResult.openAnnotationStart`): streaming holds the settled time before it (`heldBackFrom`) and marks the track as holding words back (`heldBackWords`), so silence runs a confirming decode first, and a catch-up window ends there; the next decode sees the whole of it, and a fragment such as "[BLANK" never settles. A decode that no later one can hear more than (in silence, at Stop, at the forced boundary, or a catch-up decode before a gap or with no audio to follow) reads the opener as stray instead and keeps the words after it (`wordsWithoutOpener`). On the echo-cancelled mic, whisper-small had written "[typing]", "[COUGH]" or a fragment for nine of ten "You" rows; the final pass, large-v3 on both tracks mixed, rarely writes them and has no filter.

### Catch-up

Chosen by the user in the second UI review (25 October 2026): the live transcript covers the recording from its start. The app keeps up to 15 minutes per track while no engine runs, across restarts and while the engine falls behind, and marks the chunks it hands over more than 5 s behind the newest audio `isBackfill`.

- A track that receives a backfill chunk catches up (`TrackState.isCatchingUp`, from its window's start). While any track catches up, or has kept words waiting, no streaming decode runs.
- **Decodes** follow the update interval and the power policy's pause. The due track that has decoded least far goes first (`TrackState.catchUpWork`):
  - `window`: once the track holds 30 s (`LiveAudioLimits.catchUpWindow`), decode its first 30 s.
  - `rest(endsRun: true)`: a gap follows the window; decode the rest, keep every word, report the gap, and go on after it.
  - `liveEdge`: live audio arrived; decode the rest, then stream from what is left.
  - `rest(endsRun: false)`: no audio for 2 s, counted from the later of the track's last chunk and the end of the session's latest catch-up decode (the app holds a track's audio until a decode's update reaches it, so that quiet is not a stall); decode the rest, keeping every word, then stream. A stopped capture would otherwise hold every track.
- **Kept words:** a `window` or `liveEdge` decode keeps the words that end at least 1 s before the decoded audio's end (`catchUpHoldBack`); the others keep every word. The window is trimmed there, or at the start of the first word not kept, so the next window starts with it, and what is left counts as new audio again (`markWindowUndecoded`), so the next decode or the finish decodes it. A silent window is not decoded. The reducer's transcribed time moves to the trim point (`noteDecoded(through:)`). `commitCatchUp` leaves out a word that repeats one just committed, as a window boundary may decode it twice.
- **Settling:** kept words wait per track and are committed one by one in start-time order across tracks, up to the time every catching-up track has decoded through and no later than the start of any other track's window, whose undecoded audio may still hold earlier words (that track joins catch-up from there once it falls behind). So the other track's row breaks where one starts speaking (`breakRow`), as in streaming. Once no track catches up, every kept word is settled. Committing bypasses agreement (`LocalAgreementReducer.commitCatchUp`): the backlog is decoded once. For the first 2 s of a session, a track that has sent nothing yet holds the words back too.
- **Finish** ends catch-up and settles every kept word before its final decodes.

## SpeechAnalyzer session

Built for the engine experiment and not used by the app: it lives on the reference branch ([`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench)) with the replay harness, together with the `.speechAnalyzer` engine kind and its errors. The design below is the record.

`SpeechAnalyzerLiveSession` (`@available(macOS 26, *)`) implements the same protocol in the app process.

- **Per track:** a `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])` in its own `SpeechAnalyzer`, fed by an `AsyncStream<AnalyzerInput>` created with `.bufferingOldest(16)`. A `yield` that returns `.dropped` records a `queueOverflow` gap, and the next input sets `bufferStartTime`.
- **Audio:** chunks are converted from 16 kHz Float32 to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` with a persistent converter. The first chunk and every discontinuity set `bufferStartTime` from `chunk.startTime`, so result times are on the recording timeline.
- **Results:** a final result appends its text to the open row (same 1.5 s pause rule) and clears the tail; a volatile result replaces the tail. Times come from the result's `range`.
- **Language:** SpeechAnalyzer cannot detect the spoken language, so this session accepts only `.locale(_)` (English is `en-US`). The menu lists its supported languages and defaults to the system locale when supported, otherwise English.
- **Vocabulary:** set through `AnalysisContext.contextualStrings`. The experiment records whether it changes output; if not, it is left in place harmlessly.
- **Availability:** a locale missing from `SpeechTranscriber.supportedLocales` throws `languageUnsupported`. A missing asset throws `assetNotInstalled`; the app requests the install through `AssetInventory` and shows progress.
- **Finish:** `finalizeAndFinish(through:)` with the last chunk's end time.

## Dependencies

- `LiveTranscriptModel` depends on Foundation only. It is used by `Transcription` (XPC types), `LiveTranscription`, `LiveTranscriptionService`, `TranscriptUI` (row types) and, later, `meeting_chat`.
- `LiveTranscription` depends on `LiveTranscriptModel`, `Transcription` and WhisperKit (argmax-oss-swift 1.1.0, as pinned). It is used by the transcriber worker and `LiveTranscriptionService`, and on the reference branch by `live-bench`.

## Test plan

`LocalAgreementReducerTests`:
- `sharedPrefixOfTwoDecodesIsCommitted`
- `disagreementCommitsNothing`
- `repeatedPhraseIsKeptWhenTimesDiffer`
- `repeatedWordJustAfterCommittedBoundaryIsKept` (a committed "yes" ending at 1.0 s, a new "yes" at 1.1 to 1.3 s)
- `silenceAdvancesSettledThrough`
- `overlapWithCommittedTextIsRemovedAfterTrim`
- `pauseOfOnePointFiveSecondsStartsNewRow`
- `rowIDStaysStableAsTailChanges`
- `settledTextIsAppendOnly` (randomized hypotheses, 500 seeded runs)
- `forcedBoundaryAtThirtySecondsMarksRow`
- `finishCommitsTailAndClosesRow`
- `normalizationIgnoresCaseAndPunctuation`

`WhisperLiveSessionTests` (fake decoder, virtual clock):
- `neverRunsTwoDecodesAtOnce`
- `alternatesTracksWhenBothDue`
- `respectsUpdateInterval`
- `silenceSkipsDecodesAndConfirmsTail`
- `discontinuityCommitsAndRestartsTrack`
- `fallingBehindDropsOldestAndReportsOverflow`
- `pauseEmitsOneGapAndResumesEmpty`
- `detectLocksLanguageAfterFirstDecode`
- `promptCombinesVocabularyAndCommittedTail`
- `finishTimeoutMarksTailIncomplete`

`SpeechAnalyzerMappingTests` (reference branch; fake result stream; no Speech framework call):
- `finalResultsBecomeSettledRows`, `volatileResultReplacesTail`, `resultTimesUseBufferStartTime`

`LiveTypesCodecTests`: `chunkRoundTripsThroughXPCData`, `updateRoundTripsThroughJSON`, and (second UI review) `backfillRoundTripsAndDefaultsToLive`, `engineLeadFitsTheSessionRetention`.

`WhisperLiveSessionCatchUpTests` (second UI review): `backfillIsDecodedInWindows`, `tracksSettleInConversationOrder`, `silentWindowIsSkipped`, `handsOverToStreamingAtTheLiveEdge`, `stalledTrackEndsCatchUp`, `finishSettlesKeptWords`, `gapInBackfill`, `heldBackWordIsDecodedAtTheFinish`, `slowDecodeIsNotAStall`, `trackJoiningCatchUpKeepsConversationOrder`. `LocalAgreementReducerTests.catchUpWordAtWindowBoundaryIsNotRepeated`.

Changing `Packages/Transcription` marks the `tx_*` manual tests not-run.
