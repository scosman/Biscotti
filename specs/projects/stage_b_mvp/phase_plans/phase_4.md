---
status: complete
---

# Phase 4: AppCore Coordinator

## Overview

Add the `AppCore` module to `BiscottiKit` -- the thin MVP coordinator that wires
Recording, TranscriptionService, Permissions, and DataStore into a single observable
surface for the UI. Owns navigation routing, sidebar summaries, launch recovery
(orphan reconciliation), and the start->stop->auto-transcribe coordination sequence.
Includes an `AppCore.live` factory with production adapters bridging `AudioRecorder`
(actor) and `Transcriber` (actor) to their respective protocol seams. Headless flow
tests cover the full lifecycle with all fakes (no hardware, no XPC, no CoreML).

## Steps

### 1. Add `Route` enum (`Sources/AppCore/Route.swift`)

```swift
public enum Route: Sendable, Equatable {
    case empty
    case recording
    case meeting(UUID)
}
```

### 2. Add `AppCore` class (`Sources/AppCore/AppCore.swift`)

`@MainActor @Observable` class with:

- `route: Route` (published, starts `.empty`)
- `summaries: [MeetingSummary]` (published, starts empty)
- `store`, `permissions`, `recording`, `transcription` (public, injected)
- `init(store:permissions:recording:transcription:summaryLimit:)` for tests
- `onLaunch() async` -- `recoverOrphans` then `reloadSummaries`
- `startRecording() async` -- delegates to `recording.start()`, routes to `.recording` on success
- `stopRecording() async -> UUID?` -- stops, reloads summaries, routes to `.meeting(id)`,
  fire-and-forget `transcription.transcribe(meetingID:)`
- `select(_ meetingID:)` -- routes to `.meeting(id)`
- `reloadSummaries() async` -- queries `store.meetingSummaries(limit:)`

### 3. Add `AppCore+Live.swift` -- production factory and adapters

- `AppCore.live(storageRoot:transcriberServiceName:) throws -> AppCore` -- builds
  on-disk `DataStore`, live `Permissions`, `RecordingController` with
  `LiveRecorderAdapter` factory, `TranscriptionService` with `LiveTranscriberAdapter`.
- `LiveRecorderAdapter` -- bridges `AudioRecorder` (actor) to `RecorderControlling`.
  `stateStream()` relays through an intermediate `AsyncStream` with a spawned Task
  to cross the actor isolation boundary (the protocol is synchronous, the actor method
  requires `await`).
- `LiveTranscriberAdapter` -- bridges `Transcriber` (actor) to `Transcribing`.

### 4. Update `Package.swift`

- Add `AppCore` target depending on `DataStore`, `Permissions`, `Recording`,
  `TranscriptionService`, `AudioCapture`, `Transcription`.
- Add `AppCoreTests` test target with matching dependencies.
- Add `AppCore` library product.

### 5. Write test fakes (`Tests/AppCoreTests/AppCoreTests.swift`)

Local fakes matching established patterns (reference-type `Backing` + `@unchecked Sendable`):

- `FakeMicAuthorizer` -- scripted status/request for Permissions construction.
- `FakeRecorder` -- configurable `RecorderControlling` (start error, denial, state values).
- `FakeTranscriber` -- configurable `Transcribing` (canned result, errors).
- `TestFixture` struct bundling all deps + `cleanup()` + `createMeetingWithAudio()`.
- `makeFixture(...)` factory for concise test setup.

### 6. Write headless flow tests

Cover all coordination paths per architecture section 8.

## Tests

### Launch and recovery (3 tests)

- **testOnLaunchRecoverAndLoadSummaries**: pre-populate a meeting, call `onLaunch`,
  verify summaries load and route stays `.empty`.
- **testOnLaunchOrphanRecovery**: simulate a crashed recording (marker file + audio
  refs), call `onLaunch`, verify marker deleted and meeting appears in summaries.
- **testOnLaunchEmpty**: empty store, `onLaunch` produces empty summaries.

### Recording coordination (5 tests)

- **testStartRecordingSuccess**: `startRecording` creates meeting, routes to `.recording`.
- **testStartRecordingDeniedMic**: denied mic stays on `.empty`, error surfaced.
- **testStartRecordingEngineFailed**: engine error stays on `.empty`.
- **testStopRecordingRoutesToDetail**: stop returns meeting ID, routes to `.meeting(id)`.
- **testStopRecordingReloadsSummaries**: after stop, summaries include the new meeting.
- **testStopRecordingAutoTranscribes**: after stop, transcription job is enqueued.
- **testStopRecordingWhenIdle**: stop when not recording returns nil, route unchanged.

### Navigation (3 tests)

- **testSelectRoutes**: `select(id)` sets `route = .meeting(id)`.
- **testSelectDifferentMeetings**: selecting different meetings updates route.
- **testRouteTransitionsThroughRecording**: `.empty` -> `.recording` -> `.meeting(id)`.

### Summaries (4 tests)

- **testReloadSummariesFromStore**: loads meetings from store.
- **testReloadSummariesRespectsLimit**: honors the `summaryLimit` cap.
- **testSummariesNewestFirst**: ordering matches DataStore query.
- **testSummariesUpdateAfterRecording**: stop triggers reload, new meeting appears.

### End-to-end flows (4 tests)

- **testFullRecordTranscribeFlow**: launch -> start -> stop -> verify transcription enqueued.
- **testMultipleRecordingSessions**: two recordings create separate meetings.
- **testSelectAfterStop**: navigate to a different meeting after recording.
- **testInitialRouteIsEmpty**: freshly created `AppCore` has `.empty` route.
