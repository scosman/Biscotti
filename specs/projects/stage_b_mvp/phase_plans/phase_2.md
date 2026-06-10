---
status: complete
---

# Phase 2: Recording Module

## Overview

Add the `Recording` module to `BiscottiKit`. This module provides the app-level recording lifecycle
on top of the `AudioCapture` engine: storage-path ownership, DataStore wiring (create meeting, attach
audio refs, mark presence), system-audio permission inference, elapsed-time pumping, and orphan
recovery on launch. Everything is behind a `RecorderControlling` seam so tests run with a fake
engine, in-memory DataStore, and a temp-dir storage root.

## Steps

### 1. Add `RecorderControlling` protocol and types (`Sources/Recording/RecorderControlling.swift`)

Define the seam over `AudioCapture.AudioRecorder`:

```swift
public protocol RecorderControlling: Sendable {
    func requestPermissions(systemProbePath: URL) async -> Bool
    func start(paths: CapturePaths) async throws
    func stop() async
    func stateStream() -> AsyncStream<CaptureState>
    func probableSystemAudioDenied() async -> Bool
}
```

Re-export `CapturePaths` and `CaptureState` from `AudioCapture` so downstream consumers don't need
a direct dependency on `AudioCapture`.

### 2. Add `RecordingState` and `RecordingError` (`Sources/Recording/RecordingState.swift`)

```swift
public struct RecordingState: Sendable, Equatable {
    public var isRecording: Bool
    public var elapsed: TimeInterval
    public var meetingID: UUID?
    public static let idle = RecordingState(isRecording: false, elapsed: 0, meetingID: nil)
}

public enum RecordingError: Error, Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case engineFailed(String)
    case alreadyRecording
}
```

### 3. Add `RecordingController` (`Sources/Recording/RecordingController.swift`)

`@MainActor @Observable` class implementing:

- `state: RecordingState` (published)
- `systemAudioWarning: Bool` (published)
- `lastError: RecordingError?` (published)
- `init(store:permissions:storageRoot:makeRecorder:)`
- `start() async` -- mic JIT permission, create meeting, create dir + marker, attach audio refs,
  start engine, pump stateStream, check system-audio denial after ~2 s
- `stop() async -> UUID?` -- stop engine, delete marker, markAudioPresence, clear state, return
  meeting ID
- `recoverOrphans() async` -- scan storageRoot for `.recording` marker files, reconcile each

### 4. Update `Package.swift`

- Add `Recording` target depending on `DataStore`, `Permissions`, and `AudioCapture` (path package).
- Add `RecordingTests` test target depending on `Recording`, `DataStore`, `Permissions`, `AudioCapture`.
- Add `AudioCapture` as a path package dependency.
- Add `Recording` library product.

### 5. Write `FakeRecorder` test helper (`Tests/RecordingTests/FakeRecorder.swift`)

A configurable fake implementing `RecorderControlling`:
- Configurable start behavior (succeed, throw)
- Configurable `probableSystemAudioDenied` result
- Emits scripted `CaptureState` values via its `stateStream()`
- Tracks method calls for verification

### 6. Write `RecordingController` tests (`Tests/RecordingTests/RecordingControllerTests.swift`)

Cover the MVP flow per architecture and functional spec.

## Tests

- **testStartCreatessMeetingAndLinksAudioRefs**: start creates a meeting in the store with auto-title,
  attaches mic + system audio refs with correct paths, sets state to recording.
- **testStartRequestsMicPermission**: start calls permissions.requestMicrophone() when not determined.
- **testStartDeniedMicPermission**: start with denied mic produces `permissionDenied` error, no
  meeting created.
- **testStartAlreadyRecording**: calling start while already recording produces `alreadyRecording`
  error.
- **testStartEngineFailure**: engine start throws -> error surfaced, meeting cleaned up or left with
  not-present audio.
- **testStopFinalizesAndReturnsMeetingID**: stop returns the meeting ID, deletes marker, marks audio
  presence, resets state to idle.
- **testStopWhenNotRecording**: stop when idle returns nil, no-op.
- **testSystemAudioDenialInference**: after start, when engine reports probable denial, controller
  sets systemAudioWarning and notifies permissions.
- **testRecoverOrphansReconciles**: with a marker file on disk, recoverOrphans marks presence and
  deletes the marker.
- **testRecoverOrphansNoMarkers**: with no markers, recoverOrphans is a no-op.
- **testStoragePaths**: verify recording directory structure matches
  `storageRoot/<meetingID>/mic.aac` and `system.aac`.
- **testElapsedTimePumping**: stateStream values pump through to RecordingState.elapsed.
