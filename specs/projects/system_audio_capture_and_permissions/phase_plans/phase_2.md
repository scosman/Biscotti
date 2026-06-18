---
status: complete
---

# Phase 2: Stage 2a — Permission mechanism (NO UI)

## Overview

Build the system-audio permission mechanism: a dedicated state type, persistence store, probe tone player, tone-probe API on AudioRecorder, and orchestration wiring in RecordingController/AppCore. This phase provides the full backend; the UI redesign (Settings row, Onboarding step) is Phase 3.

## Steps

### 1. `SystemAudioPermissionState` (new file in Permissions)

Create `Packages/BiscottiKit/Sources/Permissions/SystemAudioPermissionState.swift`:

```swift
public enum SystemAudioPermissionState: String, Sendable, CaseIterable {
    case notRequested
    case requestedNotVerified
    case approved

    public var displayText: String { ... }
}
```

### 2. `SystemAudioPermissionStore` (new file in Permissions)

Create `Packages/BiscottiKit/Sources/Permissions/SystemAudioPermissionStore.swift`:

```swift
public protocol SystemAudioPermissionStore: Sendable {
    func load() -> SystemAudioPermissionState
    func save(_ state: SystemAudioPermissionState)
}

public struct UserDefaultsSystemAudioPermissionStore: SystemAudioPermissionStore { ... }
```

### 3. Update `Permissions` (modify)

- Change `systemAudio` from `PermissionState` to `SystemAudioPermissionState`.
- Inject `SystemAudioPermissionStore`, load on init.
- Replace `noteSystemAudio(_:)` with `setSystemAudio(_:)` that updates + persists.
- `refresh()` continues to skip system audio.

### 4. Update SettingsViewModel (minimal compile fix, NO Phase 3 UI)

- Change `systemAudioState` from `PermissionState` to `SystemAudioPermissionState`.
- In SettingsView, adapt the system audio row to compile with the new type (map to PermissionState for the existing `permissionRow` helper, or pass displayText directly). Add `// TODO: Phase 3` comment.

### 5. Update OnboardingViewModel (minimal compile fix)

- `systemAudioResult` changes from `PermissionState` to `SystemAudioPermissionState`.
- `systemAudioGranted` maps `.approved` instead of `.authorized`.
- `syncLivePermissionState` and `resetForReplay` adapt to new type.

### 6. `ProbeTonePlayer` (new file in AudioCapture)

Create `Packages/AudioCapture/Sources/AudioCapture/ProbeTonePlayer.swift`:

```swift
final class ProbeTonePlayer {
    // Tunable constants
    static let toneFrequency: Double = 1000.0  // Hz
    static let toneAmplitude: Float = 0.001     // Ultra-low, inaudible
    func start() throws
    func stop()  // idempotent
}
```

AVAudioEngine + AVAudioSourceNode rendering a sine wave.

### 7. Expose `observedNonZero` on `LiveSystemPermissionChecker`

Add `var observedNonZero: Bool` (mirrors `hasNonZero` atomic).

### 8. Extend `SystemPermissionChecker` protocol

Add `var observedNonZero: Bool { get }` to the protocol. Update `FakeSystemPermissionChecker` with a settable version.

### 9. Add `observedSystemAudio()` and `probeSystemAudioWithTone()` to `AudioRecorder`

```swift
func observedSystemAudio() -> Bool
func probeSystemAudioWithTone(timeout: Duration = .seconds(5)) async -> Bool
```

The probe method: starts system engine (fresh tap) -> ProbeTonePlayer.start() -> polls observedSystemAudio() until true or timeout -> ALWAYS stops tone + engine -> returns Bool. Never throws.

### 10. Add `observedSystemAudio()` and `probeSystemAudioWithTone()` to `RecorderControlling`

Extend the protocol so RecordingController can call it. Update FakeRecorder with fake implementations.

### 11. Update `RecordingController` orchestration

- Rename `probeSystemAudioAndInferState()` to `probeSystemAudioPermission()`.
- New implementation: `permissions.setSystemAudio(.requestedNotVerified)` -> `makeRecorder().probeSystemAudioWithTone()` -> `setSystemAudio(observed ? .approved : .requestedNotVerified)`.
- Remove old `probeSystemAudioPermission(recorder:)` private helper.

### 12. Update `AppCore.requestSystemAudioPermission()`

Update to call `recording.probeSystemAudioPermission()` (the renamed method).

### 13. Update existing tests for the type change

- `PermissionsTests`: update `noteSystemAudio` test to use `setSystemAudio` and `SystemAudioPermissionState`.
- `RecordingControllerTests`: update `systemAudioDenialInference` and `systemAudioAuthorizedInference` to assert `permissions.systemAudio == .notRequested`.
- `SettingsViewModelTests`: update `systemAudioState` assertion from `.notDetermined` to `.notRequested`.
- `OnboardingUITests`: update `systemAudioResult` assertions from `.notDetermined` to `.notRequested`.

### 14. Update RecordingController denial inference tests

The denial check now stays neutered (sets warning only, not permission state). Update assertions to use `.notRequested` instead of `.notDetermined`.

## Tests

### AudioCapture tests (new)
- `probeSystemAudioWithTone_observedTrue_returnsEarly`: inject fake checker with observedNonZero=true, assert returns true quickly.
- `probeSystemAudioWithTone_timeout_returnsFalse`: inject fake checker with observedNonZero=false, use short timeout, assert returns false.

### Permissions tests (new)
- `setSystemAudio_persists_and_updates`: create Permissions with in-memory store, call setSystemAudio, verify property and store.
- `init_restores_from_store`: pre-seed store with .approved, verify init reads it.
- `setSystemAudio_no_denied`: verify the state type has no denied case (compile-time; covered by the enum definition).
- `transition_requestedNotVerified_to_approved`: probe flow simulation.
- `transition_timeout_stays_requestedNotVerified`: probe timeout simulation.

### Existing tests (updated)
- All tests referencing `permissions.systemAudio == .notDetermined` updated to `.notRequested`.
- `noteSystemAudio` test renamed/replaced with `setSystemAudio` test.
