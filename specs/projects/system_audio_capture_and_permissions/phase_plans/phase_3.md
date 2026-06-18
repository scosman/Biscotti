---
status: complete
---

# Phase 3: Stage 2b — Permission UI (SettingsUI + OnboardingUI)

## Overview

Wire the system-audio tone-probe mechanism (Phase 2) into the user-facing Settings and Onboarding
screens. Replace the interim Phase-2 bridge (`asPermissionState` adapter) with a dedicated 4-state
system-audio row in Settings and a 3-state system-audio step in Onboarding. Add a shared
"Fix permissions" alert with System Settings deeplink.

## Steps

### 1. Add `isValidatingSystemAudio` to `SettingsViewModel`

In `SettingsViewModel.swift`:
- Add `public private(set) var isValidatingSystemAudio: Bool = false`
- Add `public private(set) var showFixPermissionsAlert: Bool = false`
- Add a new method `requestSystemAudio()` that sets `isValidatingSystemAudio = true`, awaits
  `core.requestSystemAudioPermission()`, then sets `isValidatingSystemAudio = false`.
- Add a method `showFixPermissions()` to set the alert flag.
- Add a method `dismissFixPermissions()` to clear the alert flag.
- Add a method `openSystemAudioSettings()` that opens the deeplink with fallback.

### 2. Replace system-audio row in `SettingsView`

Remove the `// TODO: Phase 3` bridge usage. Replace with a dedicated `systemAudioRow` that renders
the 4 states per `ui_design.md` section 1:
- `notRequested` + not validating: "Not Requested" + [Request Access]
- validating (any base state): "Validating..." + spinner, controls disabled
- `requestedNotVerified` + not validating: "Not approved" + [Retry] + [Fix permissions]
- `approved` + not validating: "Granted checkmark" + [Validate]

### 3. Add shared Fix-permissions alert

Create a reusable alert modifier or shared view function usable by both Settings and Onboarding.
Place the alert in the view layer, triggered by a boolean binding. Copy per `ui_design.md` section 2:
- Title: "Allow Biscotti to record system audio"
- Body: the full text from the spec
- Buttons: [Open System Settings] (primary, deeplink) + [Done]
- Deeplink: `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` with
  fallback to `Privacy_ScreenCapture` or Privacy root.

### 4. Add `isValidatingSystemAudio` to `OnboardingViewModel`

- Add `public private(set) var isValidatingSystemAudio: Bool = false`
- Add `public private(set) var showFixPermissionsAlert: Bool = false`
- Modify `requestPermission()` for the `.systemAudio` case to set `isValidatingSystemAudio = true`
  before the call and `false` after.
- Add `showFixPermissions()` / `dismissFixPermissions()` / `openSystemAudioSettings()`.

### 5. Redesign onboarding system-audio step

Replace the `systemAudioStep` in `OnboardingStepViews.swift` with the new state-driven affordance:
- `notRequested` + not validating: [Request Access] button
- validating: "Validating..." + spinner
- `approved`: "Granted checkmark" (no Validate button -- Settings-only)
- `requestedNotVerified` + not validating: "Not approved" + [Retry] + [Fix permissions]
- Continue/Skip always available (non-blocking).

### 6. Remove the `asPermissionState` adapter

Remove `SystemAudioPermissionState.asPermissionState` and its usage. It was the Phase-2 bridge.
If any test specifically tests the adapter, remove that test too.

### 7. Update the `settingsURL` for systemAudio

Change the system audio deeplink from `Privacy_ScreenCapture` to `Privacy_AudioCapture` per the
spec. Add fallback logic in the deeplink open method.

## Tests

### SettingsViewModel tests (in `SettingsViewModelTests.swift`)
- `systemAudioRowShowsNotRequestedState`: when `systemAudioState == .notRequested`, verify state.
- `systemAudioRowShowsApprovedState`: when `systemAudioState == .approved`, verify state.
- `systemAudioRowShowsRequestedNotVerifiedState`: when `systemAudioState == .requestedNotVerified`.
- `requestSystemAudioSetsValidatingTrue`: verify `isValidatingSystemAudio` is true before the async
  call completes, false after.
- `requestSystemAudioInvokesCore`: verify `core.requestSystemAudioPermission()` is called.
- `noAutoProbeOnLoad`: after `load()`, verify `isValidatingSystemAudio` remains false and no probe
  was triggered.
- `showFixPermissionsAlertToggle`: verify show/dismiss cycle.

### OnboardingViewModel tests (new file `OnboardingSystemAudioTests.swift`)
- `systemAudioRequestSetsValidating`: verify the validating flag toggles around the probe call.
- `systemAudioNoValidateButton`: approved state has no validate action (implicit -- no Validate in
  onboarding API).
- `systemAudioFixPermissionsAlertToggle`: verify show/dismiss cycle.
- `systemAudioNonBlocking`: Continue/Skip always available regardless of system audio state.
- `noAutoProbeOnStepEntry`: entering the system audio step does not trigger a probe.

### Permissions tests
- Remove the `asPermissionState` test if it exists (it's in `PermissionsTests.swift` --
  `displayTextValues` tests `displayText`, not `asPermissionState`, so likely nothing to remove
  beyond the property itself).
