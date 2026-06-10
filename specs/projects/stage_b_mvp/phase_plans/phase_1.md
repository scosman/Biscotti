---
status: complete
---

# Phase 1: Leaf Modules + DataStore Read-Models

## Overview

Add the two dependency-free leaf modules (`DesignSystem` and `Permissions`) and the additive
read-model DTOs + query methods to `DataStore`. Wire everything into `Package.swift`. This phase
has no dependencies on `AudioCapture` or `Transcription` at the module level (those arrive in
Phases 2-3). Unit tests cover the Permissions state machine and the DataStore DTO mappers.

## Steps

### 1. DesignSystem module (`Sources/DesignSystem/`)

Create a minimal design-system target with:

- **Tokens.swift** -- color, typography, and spacing constants (system colors, dynamic type, 8-pt grid).
- **RecordButton.swift** -- a SwiftUI view for the prominent Record action.
- **StatusRow.swift** -- spinner/progress + label row (for download/transcription status).
- **TranscriptSegmentRow.swift** -- speaker chip + text row.
- **Banner.swift** -- warning/error banner with an optional action button.

All views have SwiftUI previews. No business logic.

### 2. Permissions module (`Sources/Permissions/`)

- **PermissionState.swift** -- `PermissionState` enum (`notDetermined`, `authorized`, `denied`),
  `PermissionKind` enum (`microphone`, `systemAudio`).
- **MicAuthorizing.swift** -- `MicAuthorizing` protocol (seam over `AVCaptureDevice`), plus
  `LiveMicAuthorizer` production implementation.
- **Permissions.swift** -- `@MainActor @Observable` class:
  - `microphone` / `systemAudio` published state.
  - `refresh()` -- re-read mic status on app focus.
  - `requestMicrophone() async -> Bool`.
  - `noteSystemAudio(_:)` -- called by Recording's inference.
  - `settingsURL(for:) -> URL` -- deep links to System Settings panes.

### 3. DataStore read-model DTOs (`Sources/DataStore/`)

Add a new file `DataStore+ReadModels.swift`:

- `MeetingSummary` struct (Sendable, Identifiable, Equatable): id, title, date, hasTranscript.
- `MeetingDetailData` struct: id, title, date, duration, hasAudio, preferredTranscript.
- `TranscriptData` struct: id, createdAt, speakerCount, segments.
- `SegmentData` struct: id, speakerLabel, startTime, endTime, text.
- `DataStore.meetingSummaries(limit:)` -- maps Meeting -> MeetingSummary.
- `DataStore.meetingDetail(id:)` -- maps Meeting + preferred transcript -> MeetingDetailData.
- `DataStore.audioPaths(meetingID:)` -- returns (mic: URL, system: URL)? from AudioFileRefs.

### 4. Package.swift updates

- Add `DesignSystem` target (no internal deps, SwiftUI framework).
- Add `Permissions` target (no internal deps, AVFoundation + AppKit frameworks).
- Add test targets: `PermissionsTests`, `DesignSystem` needs no tests (views only).
- DataStore tests extended for DTO mappers in existing `DataStoreTests` target.

## Tests

### Permissions tests (`Tests/PermissionsTests/`)

- **testInitialState**: default state is `.notDetermined` for mic, `.notDetermined` for systemAudio.
- **testRefreshReadsFromSeam**: after seam returns `.authorized`, `microphone` reflects it.
- **testRequestMicrophoneGranted**: request returns true, state transitions to `.authorized`.
- **testRequestMicrophoneDenied**: request returns false, state transitions to `.denied`.
- **testRequestMicrophoneSkipsWhenAuthorized**: no request call when already authorized.
- **testNoteSystemAudio**: calling `noteSystemAudio(.denied)` updates `systemAudio`.
- **testSettingsURLMicrophone**: returns correct `x-apple.systempreferences:` URL for mic.
- **testSettingsURLSystemAudio**: returns correct URL for system audio / screen recording.

### DataStore DTO mapper tests (in `Tests/DataStoreTests/ReadModelTests.swift`)

- **testMeetingSummariesMapping**: create meetings with/without transcripts, verify DTO fields.
- **testMeetingSummariesOrdering**: newest first, respects limit.
- **testMeetingDetailWithTranscript**: meeting with preferred transcript maps correctly.
- **testMeetingDetailWithoutTranscript**: meeting without transcript has nil preferredTranscript.
- **testMeetingDetailNotFound**: returns nil for unknown ID.
- **testAudioPaths**: meeting with mic+system refs returns correct URLs.
- **testAudioPathsMissing**: meeting without audio refs returns nil.
- **testSegmentDataMapping**: segments map speaker/time/text correctly, ordered by index.
