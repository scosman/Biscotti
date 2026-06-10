---
status: complete
---

# Phase 6: App Target + XPC Integration

## Overview

Wire the real Biscotti app target to the Stage B modules (AppShellUI, AppCore, DataStore) and
embed the BiscottiTranscriber XPC service so the app compiles, links, and launches with the full
Record-to-Transcribe stack. This is the integration phase: no new library code, just project
configuration and the composition root.

## Steps

1. **Update `App/project.yml` packages** -- add `Transcription` and `AudioCapture` path packages
   (mirroring `ManualTestApp/project.yml`) alongside the existing `BiscottiKit`.

2. **Update `App/project.yml` app dependencies** -- replace the single `BiscottiKit` product
   dependency with the three products the app target actually imports (`AppShellUI`, `AppCore`,
   `DataStore`) plus the two engine packages (`Transcription`, `AudioCapture`) and the embedded
   XPC service target (`BiscottiTranscriber`, `embed: true`).

3. **Add `BiscottiTranscriber` XPC service target** to `App/project.yml` -- identical to the
   proven wiring in `ManualTestApp/project.yml`: sources from `../XPCServices/BiscottiTranscriber`
   (excluding plist/entitlements), bundle ID `net.scosman.biscotti.BiscottiTranscriber`, depends
   on the `Transcription` package product, entitlements/Info.plist from the shared XPC directory.

4. **Replace `App/Sources/BiscottiApp.swift`** -- swap the placeholder stub with the real
   composition root: build `AppCore.live(storageRoot:transcriberServiceName:)` in a `.task`
   modifier, present `AppShellView(viewModel: AppShellViewModel(core:))` in a `WindowGroup`.
   Includes error handling for DataStore/filesystem failures and a loading state. Storage root
   is `~/Library/Application Support/Biscotti/`.

5. **Verify existing Info.plist and entitlements** -- confirmed that `App/Resources/Info.plist`
   already contains `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`, and
   `App/Biscotti.entitlements` already has `com.apple.security.device.audio-input`. No changes
   needed.

## Tests

- No new unit tests for this phase. Phase 6 is a configuration/wiring phase; the composition root
  is a thin `@main` struct with no testable logic beyond what the underlying modules already cover.
  The `build_app` target (app + embedded XPC compile/link) is the verification gate.

## Verification

- `build_app` green (app + XPC service compile, link, and produce a launchable bundle).
- `lint` green.
- `test` green (all 494 existing tests pass, no regressions).
