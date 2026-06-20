---
status: complete
---

# Phase 2: Onboarding Refresh (Atomic)

## Overview

Reshape the onboarding flow from 9 separate permission screens to a 5-screen
wizard (Welcome, consolidated Grant Access, Choose Calendars, Download Models,
Done). This is a visual refresh + step-machine refactor that preserves every
permission request, error/denial path, validation/retry, calendar selection,
disk-space check, and download-failure handling. The `.launchAtLogin` step and
its VM code are removed (capability remains in Settings, untouched).

## Steps

### 1. VM step-machine refactor (`OnboardingViewModel.swift`)

- Replace the 9-case `Step` enum with 5 cases: `.welcome`, `.permissions`,
  `.calendarSelection`, `.modelDownload`, `.done`. `Int` raw values 0-4.
- `totalSteps` -> `Step.allCases.count` (5).
- `progressIndex` -> `currentStep.rawValue` (0-4).
- Split `requestPermission()` into four independent methods:
  `requestMicrophone()`, `requestSystemAudio()`, `requestCalendar()`,
  `requestNotifications()` -- each with the exact body from the old switch case.
- Remove `requestPermission()`.
- Unify `advance()` and `skip()` to both call a private `proceed()` that
  navigates based on `currentStep` and permission state (calendar granted ->
  calendarSelection, else -> modelDownload; disk check before modelDownload).
- Add `allPermissionsGranted` computed property.
- Update `footerButton(for:)`: `.permissions` -> skip/continue based on
  `allPermissionsGranted`; remove `.custom` case; remove per-permission and
  `.launchAtLogin` cases.
- Update `syncLivePermissionState()`: for `.permissions`, sync all four.
- Remove `setLaunchAtLogin(_:)`, `Step.launchAtLogin`, `FooterButton.custom`,
  `import ServiceManagement`.
- `resetForReplay()` unchanged (same fields reset).

### 2. New views/components

- **`OnboardingPrimaryButtonStyle`** (new file): sage-fill button, height 40,
  radius 9, SF Pro 14.5 semibold white, top highlight, pressed 0.7, disabled 0.4.
- **`ProgressHeader`** (new file): 240x3 capsule track (Color.hairline),
  sage fill width = 240 * (rawValue+1)/5, kicker text below.
- **`PermissionRow`** (new file): icon tile + name + why + trailing state view;
  handles all four permission types and their state machines.
- **`GrantedTag`** (new file): small sage circle with white checkmark + "GRANTED"
  kicker text.
- **`OnboardingScaffold`** (new file): ProgressHeader, centered content, BrandFooter.

### 3. Rebuild `OnboardingView.swift`

- Replace dot indicator + step content switch with OnboardingScaffold hosting
  a 5-case content switch with animation.
- Honor `accessibilityReduceMotion`.

### 4. Rebuild `OnboardingStepViews.swift`

- Replace all per-step views with 5 screens: Welcome, GrantAccess (card with
  four PermissionRows), CalendarSelection, ModelDownload, Done.
- Reuse `.homeCard()`, `InsetDivider`, `.kicker()`, `JoinRecordButtonStyle`,
  `Banner`, `.fixPermissionsAlert`.

### 5. Test migration

- Rewrite `OnboardingViewModelTests`: 5-step walks, rawValue progress, totalSteps=5.
- Rewrite `OnboardingFooterButtonTests`: new `.permissions` gating, remove
  `.launchAtLogin`/`.custom`.
- Rewrite `OnboardingGrantedAndLoginTests`: rename to `OnboardingGrantedStateTests`,
  remove three launch-at-login tests, reframe granted-state tests for `.permissions`.
- Update `OnboardingNotificationTests`: call `requestNotifications()` instead of
  `requestPermission()`, walk to `.permissions` not `.notifications`.
- Update `OnboardingSystemAudioTests`: call `requestSystemAudio()` instead of
  `requestPermission()`, walk to `.permissions` not `.systemAudio`.
- Add new tests: `allPermissionsGranted` aggregation, progress jump when
  calendar not granted, advance/skip from `.permissions` branch correctly.

## Tests

- `advancesThroughAllSteps`: 5-step walk (welcome->permissions->calendarSelection->modelDownload->done)
- `advancesSkippingCalendarSelection`: permissions->modelDownload when calendar denied
- `skipSkipsPermission`: skip from `.permissions` doesn't request
- `calendarSelectionShownWhenGranted`: requestCalendar -> advance -> calendarSelection
- `calendarSelectionSkippedWhenDenied`: advance from permissions -> modelDownload
- `modelDownloadSkippable`: skip from modelDownload -> done
- `modelDownloadProgress`: startDownload -> downloadComplete
- `completePersistsFlag`: completeOnboarding persists
- `progressIndexMapsCorrectly`: rawValue-based 0-4
- `diskCheckSurfacesWarning`: from both edges into modelDownload
- `calendarGrouping`, `allEnabledWhenNil`: unchanged
- `totalStepsIs5`: updated from 8
- `resetForReplayResetsEverything`: same assertions, shorter walk
- `allPermissionsGranted`: false until all four, true when all
- `permissionsFooterGating`: skip until all four, continue after
- `advanceAndSkipBothBranchFromPermissions`: both go to calendarSelection iff granted
- All system audio tests updated for `requestSystemAudio()`
- All notification tests updated for `requestNotifications()`
- Granted state tests reframed for consolidated `.permissions` screen
- Three launch-at-login tests deleted
