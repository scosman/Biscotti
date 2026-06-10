---
status: complete
---

# Phase 5: UI Modules

## Overview

Add the four UI modules to `BiscottiKit`: `MeetingListUI`, `RecordingUI`,
`MeetingDetailUI`, and `AppShellUI`. Each module contains a `@MainActor @Observable`
view model that projects `AppCore`'s observable surface into display-ready values,
plus a SwiftUI view that binds to the view model and reuses `DesignSystem` components
(RecordButton, StatusRow, TranscriptSegmentRow, Banner). Views are previewable via a
shared `PreviewAppCore` factory. View models are unit-tested headlessly with all fakes
(no hardware, no XPC, no CoreML).

Also adds `navigateToRecording()` to `AppCore` for recording-indicator navigation, and
widens `TranscriptionService.jobs` setter to `package` visibility so view-model tests
can inject specific job statuses.

## Steps

### 1. Add `PreviewAppCore` to `AppCore` (`Sources/AppCore/PreviewAppCore.swift`)

`#if DEBUG` factory with no-op fakes (PreviewMicAuthorizer, PreviewRecorder,
PreviewTranscriber) that builds an `AppCore` with an in-memory store. All four UI
modules import this for their `#Preview` providers.

### 2. Add `navigateToRecording()` to `AppCore` (`Sources/AppCore/AppCore.swift`)

New public method: sets `route = .recording` if currently recording. Used by the
sidebar recording indicator to return to the recording screen after the user
navigated away.

### 3. Widen `TranscriptionService.jobs` setter (`Sources/TranscriptionService/TranscriptionService.swift`)

Change `public private(set) var jobs` to `public package(set) var jobs` so
view-model tests can inject specific `JobStatus` values without running the full
transcription pipeline. Matches the `package` visibility pattern used by
`AppCore.pendingTranscriptionTask`.

### 4. Add `MeetingListUI` module (`Sources/MeetingListUI/`)

- **MeetingListViewModel.swift** -- `@MainActor @Observable` class. Properties:
  `meetings` (projects `core.summaries`), `selectedMeetingID` (derived from
  `core.route`). Actions: `select(_:)` delegates to `core.select(_:)`. Static
  `relativeDate(_:)` formatter.
- **MeetingListView.swift** -- SwiftUI view rendering each meeting as a button row
  (title + relative date) with selection highlighting. Empty state shows "No
  recordings yet".
- **MeetingListViewModel+Preview.swift** -- `#if DEBUG` preview factory.

### 5. Add `RecordingUI` module (`Sources/RecordingUI/`)

- **RecordingViewModel.swift** -- `@MainActor @Observable` class. Properties:
  `isRecording`, `elapsedText` (formatted MM:SS / H:MM:SS), `meetingTitle` (from
  summaries), `showSystemAudioWarning`, `systemAudioSettingsURL`. Actions: `stop()`
  delegates to `core.stopRecording()`. Static `formatElapsed(_:)`.
- **RecordingView.swift** -- Centered layout: blinking red dot (opacity pulse),
  "Recording" label, large monospaced elapsed time, meeting title, prominent red
  Stop button, conditional system-audio warning Banner with "Fix..." deep link.

### 6. Add `MeetingDetailUI` module (`Sources/MeetingDetailUI/`)

- **MeetingDetailViewModel.swift** -- `@MainActor @Observable` class.
  `MeetingDetailState` enum: `.processing(message:)`, `.transcript(MeetingDetailData)`,
  `.failed(message:retriable:)`. Properties: `displayState` (combines
  `transcription.jobs[id]` + loaded detail), `canReTranscribe`, `title`,
  `formattedDate`, `formattedDuration`. Actions: `load()` fetches from store,
  `reTranscribe()`, `retry()`.
- **MeetingDetailView.swift** -- ScrollView with header (title + date + duration +
  Re-transcribe button), divider, and state-dependent body: StatusRow for processing,
  LazyVStack of TranscriptSegmentRows for transcript, Banner for failed (with Retry
  if retriable).

### 7. Add `AppShellUI` module (`Sources/AppShellUI/`)

- **AppShellViewModel.swift** -- `@MainActor @Observable` class. Properties:
  `recordButtonDisabled`, `showRecordingIndicator`, `recordingElapsedText`, `route`,
  `appCore`. Actions: `startRecording()`, `showRecording()` (delegates to
  `core.navigateToRecording()`), `onLaunch()`.
- **AppShellView.swift** -- `NavigationSplitView` with sidebar (RecordButton,
  recording indicator row, "PAST" section header, scrollable MeetingListView) and
  detail pane routed by `route` (`.empty` = placeholder with waveform icon,
  `.recording` = RecordingView, `.meeting(id)` = MeetingDetailView keyed by id).

### 8. Update `Package.swift`

Add 4 targets + 4 test targets + 4 library products:
- `MeetingListUI` depends on AppCore, DataStore, DesignSystem
- `RecordingUI` depends on AppCore, DesignSystem, Permissions, Recording
- `MeetingDetailUI` depends on AppCore, DataStore, DesignSystem, TranscriptionService
- `AppShellUI` depends on AppCore, DesignSystem, MeetingListUI, RecordingUI,
  MeetingDetailUI
- Test targets depend on all services + engine packages for fake construction

## Tests

### MeetingListViewModelTests (7 tests)

- **meetingsReflectsSummaries**: populate store, reload, verify count.
- **meetingsEmpty**: empty store produces empty meetings.
- **selectUpdatesRoute**: select(id) sets core.route to .meeting(id).
- **selectedMeetingIDReflectsRoute**: route changes reflected in selectedMeetingID.
- **selectedMeetingIDNilWhenEmpty**: nil when route is .empty.
- **selectedMeetingIDNilWhenRecording**: nil when route is .recording.
- **relativeDateFormatsCorrectly**: produces non-empty string.

### RecordingViewModelTests (9 tests)

- **isRecordingReflectsState**: false initially, true after startRecording.
- **elapsedTextZero**: "00:00" when idle.
- **formatElapsedMinutesSeconds**: 0/5/65/134 seconds format correctly.
- **formatElapsedHours**: 3661/7200 seconds include hours.
- **systemAudioWarningDefault**: false by default.
- **systemAudioSettingsURL**: returns URL containing "systempreferences".
- **stopDelegates**: stop() transitions isRecording to false.
- **meetingTitleDuringRecording**: returns title starting with "Recording".
- **meetingTitleWhenNotRecording**: nil when not recording.

### MeetingDetailViewModelTests (14 tests)

- **displayStateProcessingWhileLoading**: .processing("Loading...") before load.
- **displayStateDownloadingModel**: .processing when job is .downloadingModel.
- **displayStateTranscribing**: .processing("Transcribing...") when job is .transcribing.
- **displayStateTranscriptReady**: .transcript with segments when transcript exists.
- **displayStateFailedRetriable**: .failed with retriable=true.
- **displayStateFailedNonRetriable**: .failed with retriable=false.
- **displayStateMeetingNoTranscript**: .transcript with nil preferredTranscript.
- **canReTranscribeWithAudio**: true when audio exists and no active job.
- **canReTranscribeFalseDuringJob**: false when job is .transcribing.
- **canReTranscribeNoAudio**: false without audio files.
- **titleReflectsLoaded**: title matches store data after load.
- **formattedDateNonEmpty**: non-empty string after load.
- **formattedDurationFormats**: static formatter handles seconds/minutes/hours.
- **formattedDurationNil**: nil when meeting has no start/end dates.
- **loadSetsIsLoading**: isLoading transitions true->false.

### AppShellViewModelTests (11 tests)

- **recordButtonEnabledWhenIdle**: false when not recording.
- **recordButtonDisabledWhenRecording**: true during recording.
- **recordingIndicatorHiddenWhenIdle**: false when not recording.
- **recordingIndicatorShownWhenRecording**: true during recording.
- **recordingElapsedTextZero**: "0:00" when idle.
- **routeEmptyInitially**: .empty on construction.
- **routeRecordingAfterStart**: .recording after startRecording.
- **routeMeetingAfterSelect**: .meeting(id) after core.select.
- **showRecordingNavigatesBack**: returns to .recording from .meeting during recording.
- **showRecordingNoOpWhenIdle**: no-op when not recording.
- **appCoreAccessible**: appCore property returns the same instance.
