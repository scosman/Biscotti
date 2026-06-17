---
status: complete
---

# Phase 8: UI polish & responsiveness

## Overview

Post-review polish phase addressing four items discovered during implementation
review. Fixes sidebar kicker color, toolbar button animation bleed, record-click
responsiveness, and test-helper duplication.

## Steps

### 1. Sidebar "RECORDING NOW" kicker color + placement

- **File:** `AppShellUI/AppShellView.swift` (`RecordingNowSection`)
- Change the `"RECORDING NOW"` kicker `foregroundStyle` from `Color.signalRed`
  to `.inkSecondary` to match the "UPCOMING" section title color.
- Move the `RecordingNowSection` block in the `sidebar` body so it appears
  **above the Upcoming section** (after the Past Meetings row + divider) instead
  of above the Home row. Match the placement pattern of Upcoming.

### 2. Toolbar record button: isolate pulsing dot animation

- **File:** `AppShellUI/AppShellView.swift` (`RecordingToolbarButton`)
- Root cause: `withAnimation` in `onAppear` animates the `pulsing` state
  change. Because `pulsing` drives the dot opacity, and the whole label
  (including `Text("REC ...")`) lives inside the same body, SwiftUI's implicit
  animation leaks to layout changes caused by the elapsed text updating every
  second.
- Fix: remove the `withAnimation` wrapper. Instead, apply the repeating
  animation as a `.animation(_:value:)` modifier **only** on the dot `Circle`,
  so only the dot's opacity is driven by the animation and the text/frame
  updates are not animated.

### 3. Record-click responsiveness: instant route + loading state

- **File:** `AppCore/AppCore.swift` (`startRecording`)
  - Set `route = .recording` and `runState = .recording(...)` **before** the
    async `recording.start()`, so the UI navigates instantly.
  - Introduce a new `RecordingStartupState` enum:
    `.loading`, `.started`, `.failed(String)`.
  - Add `recordingStartup: RecordingStartupState?` observable property.
  - On record click: set `recordingStartup = .loading`, route immediately, then
    `Task { await heavyStartup() }`. On success set `.started`; on failure set
    `.failed(message)`.
  - Refactor `startRecording` into a synchronous setup (route + state) and an
    async `completeRecordingStartup()` that does `recording.start()`,
    `associateEvent`, `reloadSummaries`.

- **File:** `RecordingUI/RecordingViewModel.swift`
  - Expose `recordingStartup` from AppCore.
  - Add `retryStartRecording()` and `cancelStartRecording()` for the failure
    state.

- **File:** `RecordingUI/RecordingView.swift`
  - When `recordingStartup == .loading`, show a centered spinner with
    "Starting recording..." text instead of the main column.
  - When `recordingStartup == .failed(msg)`, show an error state with the
    message and a "Retry" / "Cancel" button.
  - When `recordingStartup == .started` (or nil), show the normal recording
    content.

### 4. Test-helper dedup (`pollUntil` + `makeAudioProcess`)

- **File:** `Tests/BiscottiTestSupport/TestHelpers.swift` (new)
  - Extract `pollUntil` and `makeAudioProcess` into this shared module.
- **File:** `Tests/AppCoreTests/AppCoreBackgroundTests.swift`
  - Remove the local `pollUntil` and `makeAudioProcess` definitions.
  - Import `BiscottiTestSupport` (already imported).
- **File:** `Tests/RecordingUITests/RecordingViewModelTests.swift`
  - Remove the local `pollUntil` and `makeAudioProcess` definitions.
  - Import `BiscottiTestSupport` (already imported).

## Tests

- **RecordingStartupState transitions:** test that `beginRecording()` sets
  `.loading` then `.started` on success, or `.failed` on error.
- **Cancel/retry from failed state:** test that `cancelRecordingStartup()`
  resets state and route, and `retryStartRecording()` re-attempts.
- **`pollUntil` / `makeAudioProcess`:** all existing tests using these helpers
  must still pass after migration to the shared module.
