---
status: complete
---

# Architecture: Live Transcript

How the behavior in [functional_spec.md](functional_spec.md) and [ui_design.md](ui_design.md) is built. This document holds the cross-cutting design. Each part has a component document in [components/](components/) with its interfaces, algorithms and test plan.

## Principles

1. **Capture never waits.** Live transcription reads a copy of the audio. A full queue drops audio from the live path and records a gap; the AAC files are untouched.
2. **One contract, two engines.** Whisper and SpeechAnalyzer sit behind the same session contract, so the experiment, the app and the tests use the same code. The app ships only Whisper.
3. **Settled text is append-only.** Within a recording, a row's settled text never changes; only the tail of the newest row per track is replaced.
4. **Nothing new is persisted for live text.** The live transcript lives in memory. The final pass stays the only writer of saved transcripts.
5. **Existing boundaries hold.** Packages stay testable without the app, screens stay separate modules, AppCore stays the coordinator, and every new path reads storage the way the app already does.
6. **Each recording owns its live work.** Finishing one recording never changes another's state; every lifecycle call carries the recording's ID.
7. **Every buffer has a limit.** Each stage of the live path has a fixed capacity and one defined overflow result: a correctly timed gap.

## Module map

| Module | Kind | Change | Component |
|---|---|---|---|
| `Packages/AudioCapture` | package | A live audio sink on `AudioRecorder`; writers copy PCM after processing | [live_audio_branch](components/live_audio_branch.md) |
| `Packages/Transcription` → new target `LiveTranscriptModel` | package target | Contract types, the snapshot and the agreement reducer; Foundation only | [live_session](components/live_session.md) |
| `Packages/Transcription` → new target `LiveTranscription` | package target | The Whisper session (the experiment's SpeechAnalyzer session is on the reference branch) | [live_session](components/live_session.md) |
| `Packages/Transcription` → `Transcription` | package target | XPC protocol messages for live sessions; `Transcriber` client methods | [transcriber_worker](components/transcriber_worker.md) |
| `Packages/Transcription` → new target `TranscriberWorker` | package target | The worker's engine host and exported service, linked by the XPC service | [transcriber_worker](components/transcriber_worker.md) |
| `XPCServices/BiscottiTranscriber` | XPC service | One engine per process; live session hosting | [transcriber_worker](components/transcriber_worker.md) |
| `Packages/Transcription` → executable `live-bench`, on the reference branch | package target | The replay harness, kept on [`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench), not in the app's source | [replay_harness](components/replay_harness.md) |
| `BiscottiKit/TranscriptionService` | L1 service | A job queue with live-first admission | [transcriber_worker](components/transcriber_worker.md) |
| `BiscottiKit/LiveTranscriptionService` (new) | L1 service | Audio pump, engine choice, live transcript store, drafts, snapshots, power policy | [live_transcription_service](components/live_transcription_service.md) |
| `BiscottiKit/TranscriptUI` (new) | L3a shared UI | The bubble transcript list, used by two screens | [transcript_bubble_view](components/transcript_bubble_view.md) |
| `BiscottiKit/RecordingUI` | L3a screen | The drawer, toggle, find bar and note-time links | [live_drawer](components/live_drawer.md) |
| `BiscottiKit/MeetingDetailUI` | L3a screen | Transcript tab switches to `TranscriptUI`; shows drafts | [transcript_bubble_view](components/transcript_bubble_view.md) |
| `BiscottiKit/DataStore` | L0 | `AppSettings.liveTranscriptEnabled`; a current-user person query | [live_transcription_service](components/live_transcription_service.md) |
| `BiscottiKit/AppCore`, `SettingsUI`, `App` | L2, L3a, app | Wiring, the Settings toggle, the View menu command | [live_drawer](components/live_drawer.md) |

Dependency changes keep the DAG downward:

- `LiveTranscriptModel` has no dependencies beyond Foundation. Everything that only reads live transcripts (the bubble view, and later `meeting_chat` and MCP) depends on it, never on the engines.
- `LiveTranscription` depends on `LiveTranscriptModel`, `Transcription` and WhisperKit. `Transcription` depends on `LiveTranscriptModel` for the types it sends over XPC.
- `TranscriberWorker` depends on `Transcription`, `LiveTranscription` and `LiveTranscriptModel`; only the XPC service links it.
- `LiveTranscriptionService` depends on `AudioCapture`, `Transcription`, `LiveTranscriptModel` and `LiveTranscription`. AppCore owns one instance.
- `TranscriptUI` depends on `DesignSystem`, `DataStore`, `Formatting` and `LiveTranscriptModel`, never on an engine. `RecordingUI` and `MeetingDetailUI` depend on it. `MeetingDetailUI`'s `TranscriptListView` and `TranscriptContent` move into it.

## Data flow

```text
AudioRecorder writers ──copy──▶ LiveAudioQueue (mic, system)        [AudioCapture]
        │ (AAC unchanged)                │
        ▼                                ▼ pump thread
   AAC files                    LiveAudioPump: resample to 16 kHz, timeline,
                                levels, gap detection                [LiveTranscriptionService]
                                         │ LiveAudioChunk
                                         ▼
                          WhisperXPCSession (XPC proxy)
                                         │ NSXPC
                          BiscottiTranscriber.xpc:
                          WhisperLiveSession + LocalAgreementReducer
                                         │
                                         ▼ LiveTrackUpdate
                              LiveTranscriptStore (@MainActor)
                       ┌─────────────────┼──────────────────┐
                       ▼                 ▼                  ▼
                  Live drawer     Transcript tab draft   snapshot() for meeting_chat
```

At Stop, the store publishes the current live text as the meeting's draft at once. The recording's live session then finishes in the background, with one 10-second deadline for draining the pump and finishing the engine, and adds its last words to that draft only. `TranscriptionService` runs the queued final pass, and the draft is released when the final transcript is saved. A new recording that starts meanwhile cancels the earlier finishing work; that draft keeps what it has.

## Shared types

Defined in `LiveTranscriptModel`, `Sendable`, `Codable` where they cross XPC. Full definitions are in [live_session](components/live_session.md).

| Type | Purpose |
|---|---|
| `LiveTrack` | `.mic`, `.system`, `.mixed` |
| `LiveAudioChunk` | Track, start time on the recording timeline (seconds), 16 kHz mono Float32 samples, discontinuity flag |
| `LiveRow` | Stable `UUID`, track, start and end time, settled text, tail text, forced-boundary flag |
| `LiveTrackUpdate` | Track, appended settled rows, replaced tail row, new gaps, transcribed-through and settled-through times |
| `LiveGap` | Track, start time, duration, reason (`.queueOverflow`, `.captureGap`, `.paused`, `.engineRestart`) |
| `LiveSessionConfig` | Engine, model choice, tracks, update interval, language policy, vocabulary |
| `LiveTranscriptSnapshot` | The frozen copy defined in the functional spec |

## Time base

All times are seconds on the **recording timeline**: t = 0 is the first mic buffer written to the AAC file, the same anchor the recorder already uses to align the system track.

- Chunk times come from **written frame counts** at the source rate, including gap fills and the system track's leading silence, never from host time. This matches the files exactly, so live and final times line up.
- Note timestamps count from a later moment (`CaptureState.startTimestamp`, taken after both engines start). `AudioRecorder` exposes `timelineOffset = startTimestamp − micAnchorSeconds` once recording starts; a note at elapsed `e` sits at `e + timelineOffset` on the recording timeline.

## Recording ownership

- **One active recording ID.** AppCore uses the meeting ID as the recording ID. `TranscriptionService.recordingDidStart(id)` and `recordingDidStop(id)` take it, and a stop clears the active recording only when the ID still matches.
- **One live session object per recording.** `LiveTranscriptionService` creates a `LiveRecordingSession` (pump, engine session, store, draft destination) for each recording. Stop detaches it from `current` and finishes it in a task that can write only to its own meeting's draft.
- **New recordings come first.** Starting a recording cancels any earlier session still finishing; the worker hosts one live session at a time.
- **Admission waits for acknowledgement.** New work starts on the worker only after the worker replies that earlier work has stopped (`cancelActiveWork`), never just because a connection was invalidated.

## Bounded buffering

| Stage | Limit | When full |
|---|---|---|
| Writer → live queue | 128 slots per track, about 3 to 5 s | Drop the newest block; emit a timed `overflow` gap |
| Pump → engine (XPC chunks or SpeechAnalyzer input) | 8 chunks of 250 ms per track in the app's pipe and 8 unacknowledged on the XPC connection, plus up to 15 minutes per track waiting in the pump, as 16-bit samples (35 s before the second UI review) | Keep waiting and offer again; past 15 minutes, drop the oldest waiting audio, emit a `queueOverflow` gap and mark the next chunk discontinuous |
| Session retained audio | 45 s per track | Drop the oldest undecoded audio; emit a `queueOverflow` gap |
| Updates to the app | Merged while pending, never dropped | None needed |

Until the second UI review, the pump kept less than the session retains (`LiveAudioLimits`): its 35 s, the 4 s in transit and 6 s for the audio that arrived during the session's first decodes added up to the session's 45 s, so a backlog the pump handed over when a slow engine start ended never overflowed the session; with 45 s in both, the hand-over dropped about 2.5 s of the oldest audio (UI review, 25 October 2026).

**Backfill (chosen by the user in the second UI review, 25 October 2026).** The pump now keeps up to 15 minutes per track (`LiveAudioLimits.pumpBacklog`), about 29 MB per track as 16-bit samples, so the live transcript can cover the recording from Record even when the engine starts late or restarts. The app hands a track's audio to the engine only up to `engineLead` (36 s) past the track's transcribed time, one forwarder per track; with the 4 s in transit the session stays under its 45 s. Chunks handed over more than 5 s behind the newest audio are marked `isBackfill`, and the Whisper session catches up on them in 30 s decodes, settling the words of both tracks in start-time order, before it streams again ([live_session](components/live_session.md#catch-up)). A restarted engine first gets the audio the failed one took but had not settled ([live_transcription_service](components/live_transcription_service.md#lifecycle)).

**The worker keeps the live model loaded** while the live transcript is on (second UI review): macOS purges the compiled model when the disk runs low, so each new load compiled for one to two minutes ([transcriber_worker](components/transcriber_worker.md#keeping-the-live-model-loaded)). One rule, chosen by the user on 25 October 2026: on Macs with more than 8 GiB, whisper-small stays loaded at all times, also during a final pass, and the final pass's models are unloaded in place after the last pass (their wired memory returns; the worker stays up). The two may be loaded together, about 0.3 GB on top of large-v3. On 8 GiB Macs nothing is kept, and the worker still shuts down after a pass.

**Low disk space** (chosen by the user on 25 October 2026): a model load that runs past 15 s while the startup disk has less than 20 GB free is blamed on the disk, and the app says so in the drawer, in the final transcription's status and in Settings ([transcriber_worker](components/transcriber_worker.md#low-disk-space)).

A gap is marked silent when the stage that dropped the audio had the samples and every 250 ms of them was below −45 dBFS, the session's silence test. Audio that never arrived is not silent. The view joins touching gaps of either track and either silence into one stretch, and marks it, at its full length, only when the parts not known to be silent total 5 s or more.

Closing a queue never needs a free slot, so end of input is always seen, and any pending overflow is emitted as a final gap.

## What each engine must promise

- **"You" and "Others" need two tracks.** The shipping configuration recognizes mic and system separately. Mixed mode stays allowed only as the fallback from the functional spec, and mixed rows never name a speaker: no label, no copy prefix, no "Others" in VoiceOver.
- **Language:** an engine that cannot detect the spoken language (SpeechAnalyzer) offers no "Detect language"; the menu lists its supported languages instead.
- **Vocabulary** is passed to every engine that accepts it. Neither engine applies it to live text today: live Whisper decodes unprompted (`WhisperKitLiveDecoder.defaultPrompt` is `.none`), and SpeechAnalyzer's contextual strings had no measurable effect ([research](../../research/live_transcription/README.md#vocabulary)).

## Concurrency

| Work | Where |
|---|---|
| Copy into the live queue | The existing writer threads; lock-free, no allocation after start |
| Drain, resample, levels, gap detection | One pump thread owned by `LiveAudioPump` (QoS `.userInitiated`) |
| Whisper decoding | The XPC worker; one decode at a time, in a dedicated task |
| SpeechAnalyzer (reference branch only) | Its own async sequences, in the calling process |
| Store, UI, snapshots | `@MainActor`; updates coalesced to at most 4 per second |

Priority under load follows the functional spec: capture, then live text, then everything else. The worker runs decodes at `.userInitiated`; final passes keep their current priority.

## Error handling

- **Never fatal to recording.** Every live failure maps to a toggle status (`Unavailable` with a reason) and, where audio was lost, a `LiveGap`. Recording and the final pass continue.
- **Worker crash or interruption** during a live session: the service restarts the session once on a new connection, from the current time, with an `.engineRestart` gap. A second failure in the same recording ends live transcription for that recording.
- **Stop deadline:** draining the pump and finishing the engine share one 10-second deadline; after it, the tail row is marked incomplete and the draft keeps what it has.
- **Logging:** `os.Logger(subsystem: "net.scosman.biscotti", category: "live")`. State changes log at `.notice`; numbers use `privacy: .public`; no per-chunk logging. Transcript text is never logged.

## Settings and stored data

- `AppSettings.liveTranscriptEnabled: Bool?`, default `nil`. `nil` resolves to on, or off on Macs with 8 GiB or less (the same rule `MethodResolver` uses). It is an additive optional field in `DataStoreSchemaV1`.
- A new DataStore query, `currentUserPersonIDs() -> Set<UUID>`, returns every distinct `CalendarSnapshot.currentUserPersonID`. The bubble view uses it to place "You" on the right in saved meetings.
- The drawer's open state is a per-app preference in `UserDefaults` (`liveTranscript.drawerExpanded`).
- No transcript schema changes.

## Storage and paths

- The app and the worker derive storage as today: models in the app's model cache, recordings under `~/Library/Application Support/Biscotti/Recordings`. The live session receives PCM, not paths; a final pass receives audio paths, as today.
- The replay harness (reference branch) is a command-line tool with no app bundle. It takes explicit `--models`, `--fixtures` and `--out` folders, never calls `ModelStorage`, and refuses any path under `~/Library/Application Support/Biscotti`.
- The harness reuses an existing model cache and never downloads Whisper weights. The SpeechAnalyzer locale asset is installed by the system on request, as a setup step.

## Testing strategy

| Level | What | Where |
|---|---|---|
| Unit | Reducer, scheduler, timeline math, gap detection, store merge, snapshot, queue admission, bubble grouping, right-side rule, find | Swift Testing in each package's test target |
| Writer integration | Live sink attached to real writers, real AAC output compared with recording-only; gaps, late system start, 48 → 24 kHz | `AudioCaptureTests` (gate 4) |
| Replay | Public meeting audio at real-time speed through each engine; the four gates | `live-bench` + `Tools/live_bench`, on the reference branch |
| Hardware | A test build on real calls, per `specs/research/audio/hardware_debugging_workflow.md` | [hardware checklist](components/live_audio_branch.md#hardware-checks) |
| In-app latency | `OSSignposter` intervals from chunk sent to row rendered, read during a hardware check; adds the app's delivery, merging and rendering time to the harness's session latency | `LiveTranscriptionService`, `TranscriptUI` |

- **Manual test staleness:** changing `Packages/AudioCapture` marks `ac_*` steps not-run; changing `Packages/Transcription` or the transcriber XPC service marks `tx_*` steps not-run, as `CLAUDE.md` requires.
- **Gating:** everything except replay and hardware runs in `make test`. Replay is `make bench-live` on the reference branch, non-gating.

## Risks and spikes

| Risk | Spike, before the dependent phase |
|---|---|
| Whisper cost per update is too high during a call | The harness's `cost` command times 2, 10 and 30 s decodes first |
| `List` on macOS does not report scroll position reliably for following | A spike in the bubble view phase, with two tracks updating at once and a draft-to-final swap; fallback is `ScrollView` + `LazyVStack` with `scrollPosition` (see [transcript_bubble_view](components/transcript_bubble_view.md)) |
| SpeechAnalyzer needs speech-recognition permission or a bundle | A spike at the start of the SpeechAnalyzer arm; if it does, the harness runs it from a minimal test app bundle |
| Two concurrent analyzers for two tracks | The same spike; fallback is mixed mode for SpeechAnalyzer |
| The system tap delivers more than one buffer in a list | Covered by a writer-integration test; the live copy downmixes every channel it receives |
