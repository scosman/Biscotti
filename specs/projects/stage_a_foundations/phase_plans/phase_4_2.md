---
status: complete
---

# Phase 4.2: ManualTestApp shell (XcodeGen + SwiftUI runner)

## Overview

Create the `ManualTestApp/` directory at the repo root (peer to `App/`) — an XcodeGen-based macOS app that serves as the manual test harness. It renders every `TestScript` from ManualTestKit in a TabView, provides a generic script-runner view that walks steps and records outcomes via `ResultsStore`, and wires REAL `AudioRecorder.live()` and `Transcriber(backend: .inProcess)` calls at the app layer (replacing placeholder closures from ManualTestKit scripts).

**Phase boundary:** `.inProcess` only — no `.xpc` service or `.hosted` backend (that is Phase 4.3).

## Steps

1. **XcodeGen config** — `ManualTestApp/project.yml`:
   - Name: `ManualTestApp`, bundle ID `net.scosman.biscotti.manualtest`.
   - macOS 15.0, Swift 6.0, strict concurrency, ad-hoc signing.
   - Three local package dependencies: `BiscottiKit`, `Transcription`, `AudioCapture`.
   - Target depends on `ManualTestKit` (from BiscottiKit), `Transcription`, and `AudioCapture` products.
   - Entitlements: non-sandboxed + audio-input.
   - Info.plist with mic + system audio usage descriptions.

2. **Entitlements** — `ManualTestApp/ManualTestApp.entitlements`:
   - `com.apple.security.app-sandbox` = `false` (non-sandboxed).
   - `com.apple.security.device.audio-input` = `true`.

3. **Info.plist** — `ManualTestApp/Resources/Info.plist`:
   - `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` (no calendar).

4. **App entry point** — `ManualTestApp/Sources/ManualTestAppApp.swift`:
   - `@main` SwiftUI app with a `WindowGroup` containing the root `ScriptTabView`.

5. **ScriptTabView** — `ManualTestApp/Sources/ScriptTabView.swift`:
   - A `TabView` iterating `allScripts`, one tab per script title.
   - Each tab hosts a `ScriptRunnerView` for that script, with wired closures.

6. **ScriptRunnerView** — `ManualTestApp/Sources/ScriptRunnerView.swift`:
   - Accepts a `TestScript` and a `ResultsStore`.
   - Renders each `TestStep` via `StepView`.
   - Loads/displays per-step status from the results store.

7. **StepView** — `ManualTestApp/Sources/StepView.swift`:
   - Renders each `TestStep` case appropriately:
     - `.action` — a button that runs the async closure.
     - `.instruction` — static text.
     - `.humanQuestion` — yes/no buttons + optional note field.
     - `.autoCheck` — a "Run Check" button that executes the check closure and shows the outcome.
   - Records results to `ResultsStore` after each interaction.

8. **Wiring layer** — `ManualTestApp/Sources/WiredScripts.swift`:
   - Builds new `TestScript` instances that replace placeholder closures with real calls.
   - Audio capture steps: `AudioRecorder.live()` for start/stop, `AutoChecks.checkAACFilesExist` for the auto-check.
   - Transcription steps: `Transcriber(backend: .inProcess)` for model download + transcription, `AutoChecks.checkNoSegmentPastDuration` for the hallucination check.

9. **Makefile updates**:
   - `generate` target: also `cd ManualTestApp && xcodegen generate`.
   - `build-app` target: also `xcodebuild` ManualTestApp scheme.
   - `LINT_PATHS`: add `ManualTestApp`.
   - `clean` target: remove `ManualTestApp/*.xcodeproj` and DerivedData.

## Done when

- `mcp__hooks-mcp__build_app` builds both App and ManualTestApp GREEN.
- `mcp__hooks-mcp__test` still green (ManualTestKit logic unchanged).
- `mcp__hooks-mcp__lint` passes with ManualTestApp sources included.

## Notes

- **Results path**: `ResultsStore` currently writes to `~/Documents/ManualTestApp/results.json`. The canonical results path (shared between the app and CI/scripts) is reconciled in Phase 4.4.
