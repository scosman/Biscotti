---
status: complete
---

# Phase 11 G1: Onboarding Fixes + G7 Architecture Docs Reconcile

## Overview

Implements five onboarding UX fixes from the human hardware review, plus reconciles the architecture doc to reflect that conference-link detection lives in MeetingCatalog (L0).

## Steps

### G7 — Architecture docs reconcile
1. Edit `specs/projects/stage_c/architecture.md` section 7 to clarify that conference-link detection (`conferenceMatch`) lives in `MeetingCatalog` (L0), not in a RemoteConfig/Calendar split. Minimal, accurate edit.

### G1.1 — Granted-state hides permission action buttons
2. Add computed properties to `OnboardingViewModel` for each permission step: `microphoneGranted`, `systemAudioGranted`, `calendarGranted` that return `true` when the corresponding result is `.authorized`.
3. In `OnboardingStepViews.swift`, wrap each "Allow..." button in an `if !viewModel.xxxGranted` conditional, so the button is hidden once granted. Keep the existing granted checkmark label.

### G1.2 — Layout improvements
4. In `OnboardingView.swift`, restructure: title + step indicator pinned near the top (not centered by Spacer), step content fills remaining space and is vertically centered within it.
5. In `calendarToggles`, remove the fixed `.frame(maxHeight: 200)` so content fills available space, only scrolling on genuine overflow. Use a `ScrollView` that expands to fit content up to available height.

### G1.3 — Rename model step
6. Change title from "Download speech model" to "Download Local AI Models" in `OnboardingStepViews.swift` `modelDownloadStep`.
7. Change the "Model ready" label to "Models ready".

### G1.4 — Notification TODO
8. Add `// TODO(notifications): onboarding notification permission request not functioning on-device -- revisit` in `OnboardingViewModel.requestPermission()` at the `.notifications` case.

### G1.5 — Launch at Login step
9. Add `.launchAtLogin` case to `OnboardingViewModel.Step` (between `.modelDownload` and `.done`).
10. Update `totalSteps` to 8, `progressIndex` to map the new step.
11. Add `setLaunchAtLogin(_:)` method that persists to DataStore + calls SMAppService (same pattern as SettingsViewModel).
12. Wire `advance()` and `skip()` to transition through the new step.
13. Add `launchAtLoginStep` view in `OnboardingStepViews.swift` with "Start Biscotti when you start your computer?" headline and [No] [Yes] buttons (no skip/continue).
14. Add the new step to the view switch in `OnboardingView.swift`.

## Tests

- `grantedStateDerivedFromPermissionResult`: after requesting microphone and getting `.authorized`, `microphoneGranted` is true; same for systemAudio and calendar.
- `launchAtLoginStepPresentInSequence`: walking through all steps includes `.launchAtLogin` between `.modelDownload` and `.done`.
- `launchAtLoginYesPersists`: calling `setLaunchAtLogin(true)` persists `launchAtLogin: true` in settings.
- `launchAtLoginNoPersists`: calling `setLaunchAtLogin(false)` persists `launchAtLogin: false`.
- `totalStepsIs8`: `totalSteps` is now 8.
- `progressIndexMapsLaunchAtLogin`: `progressIndex` for `.launchAtLogin` is 6, `.done` is 7.
- `renamedModelStepTitle`: verify the step label is data-driven (not strictly needed since it's a view constant, but confirm the VM exposes model data correctly for the new step count).
