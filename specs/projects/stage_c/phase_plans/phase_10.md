---
status: complete
---

# Phase 10: Onboarding & Settings (completes Project 8 = feature-complete V1)

## Overview

Delivers the first-run onboarding wizard and completes the Settings UI, making the app
feature-complete (V1). Onboarding guides users through permissions (mic, system audio, calendar +
selection, notifications) and model download (skippable). Settings gains launch-at-login toggle and
a stubbed custom-vocabulary section (Phase 9 deferred). The onboarding gate + `completeOnboarding`
wiring from AppCore (Phase 6) is completed so finishing the wizard routes into the app.

**Phase 9 (Vocabulary) is DEFERRED** -- the SDK cannot use vocabulary yet. This phase:
- Does NOT build `VocabularyService` or wire vocabulary into `TranscriptionService`.
- Stubs the custom-vocabulary section in SettingsUI with a "Coming soon" placeholder.
- Implements model-readiness/download for onboarding independently of vocabulary.

## Steps

### 1. Add `ensureModelsReady` / `modelsReady` to TranscriptionService

Expose model-readiness methods on `TranscriptionService` for the onboarding download step.
These wrap the existing `engine.ensureModelsDownloaded(status:)` without vocabulary changes.

```swift
// TranscriptionService.swift
public func ensureModelsReady(
    status: @escaping @Sendable (String) -> Void
) async throws

public func modelsReady() async -> Bool
```

`modelsReady` calls `ensureModelsDownloaded` in a dry-run check (or catches
`.needsDownload`). `ensureModelsReady` delegates to `engine.ensureModelsDownloaded(status:)`.

### 2. Add `requestSystemAudioPermission()` to AppCore

The onboarding system-audio step needs to trigger the capture probe. Add:

```swift
public func requestSystemAudioPermission() async {
    // Exercise the recording probe to trigger the system prompt
    // and infer the permission state.
    await recording.probeSystemAudio()
    // Update permissions with inferred state
}
```

If `RecordingController` already has a probe path, use it. Otherwise, surface the permission
through the existing silence-detection inference -- the onboarding step will show a "request"
button that attempts a brief capture probe, and the user sees the system prompt if not already
granted. Read the resulting state from `permissions.systemAudio`.

### 3. Build OnboardingUI module (new target)

Create `Packages/BiscottiKit/Sources/OnboardingUI/` with:

- **`OnboardingViewModel.swift`** -- Step state machine (welcome, microphone, systemAudio,
  calendar, calendarSelection, notifications, modelDownload, done). Each step with
  advance/skip/requestPermission. Model download with progress + disk check + skip. Calendar
  selection reuses `SettingsViewModel.CalendarGroup` pattern. `completeOnboarding()` at the end.

- **`OnboardingView.swift`** -- Step indicator dots, WizardStep scaffold for each step,
  permission request buttons, denial-fix deep links, calendar selection toggles, model download
  progress, "Get Started" button on done.

### 4. Extend SettingsUI with launch-at-login and stubbed vocabulary

- **SettingsViewModel**: Add `launchAtLogin` toggle (read from settings, write via
  `store.updateSettings` + `SMAppService`). Add `setLaunchAtLogin` action.
- **SettingsView**: Add "General" section with launch-at-login toggle. Add "Custom Vocabulary"
  section with a disabled/"Coming soon" placeholder (no real vocab editing).

### 5. Wire OnboardingUI into AppShellUI

- Add `OnboardingUI` dependency to `AppShellUI` target in `Package.swift`.
- `AppShellViewModel` creates and caches an `OnboardingViewModel`.
- `AppShellView` renders `OnboardingView` for `.onboarding` route (replacing the placeholder).
- When onboarding is active, the sidebar + search are hidden (full-window takeover).

### 6. Add `OnboardingUI` target to Package.swift

New target with dependencies: `AppCore`, `Calendar`, `DataStore`, `DesignSystem`, `Permissions`,
`TranscriptionService`. New test target `OnboardingUITests`.

### 7. Wire SMAppService into AppCore/SettingsUI for launch-at-login

AppCore does not directly import ServiceManagement. The settings toggle calls
`SMAppService.mainApp.register()` / `unregister()` from the app-target level. For testability,
the SettingsVM toggle writes to settings and the BiscottiApp reads+applies it on launch. Or:
SettingsViewModel directly calls `SMAppService` (it already imports AppKit). Decision: keep
`SMAppService` in SettingsViewModel (it's app-level UI glue, acceptable).

### 8. Update Package.swift

- Add `OnboardingUI` target + test target.
- Add `OnboardingUI` dependency to `AppShellUI`.
- Add `TranscriptionService` dependency to `OnboardingUI` (for model download).

## Tests

### OnboardingUI tests (`OnboardingUITests/OnboardingViewModelTests.swift`)

- `onboardingAdvancesThroughSteps` -- advance() walks from .welcome through .done
- `onboardingSkipSkipsPermission` -- skip() on .microphone advances without requesting
- `onboardingCalendarSelectionShownWhenGranted` -- after granting, advance goes to .calendarSelection
- `onboardingCalendarSelectionSkippedWhenDenied` -- after denial, advance skips selection
- `onboardingModelDownloadSkippable` -- skip() on .modelDownload advances to .done
- `onboardingModelDownloadProgress` -- startDownload() sets isDownloading and updates status
- `onboardingCompletePersistsFlag` -- completeOnboarding() calls core.completeOnboarding()
- `onboardingProgressIndexMapsCorrectly` -- each step maps to expected progress index
- `onboardingDiskCheckSurfacesWarning` -- insufficient disk: hasSufficientDisk == false

### SettingsUI tests (additions)

- `settingsToggleLaunchAtLogin` -- toggle persists launchAtLogin to settings
- `settingsVocabSectionStubbed` -- vocabularyTerms is empty, section renders "Coming soon"

### TranscriptionService tests (additions)

- `ensureModelsReadyDelegates` -- calls engine.ensureModelsDownloaded with status callback
- `modelsReadyReturnsTrueAfterDownload` -- returns true when engine succeeds
