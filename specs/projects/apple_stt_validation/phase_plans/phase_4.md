---
status: complete
---

# Phase 4: Runner app

## Overview

Build the STTLabRunner executable target: a SwiftUI app that loads a bundle, runs Apple SpeechTranscriber on each meeting (macOS 26+), and saves results. Includes CLI mode, a packaging script, and the deferred MemorySampler fix for `ri_lifetime_max_phys_footprint`.

## Steps

1. Fix `MemorySampler` (deferred from phase 1): track `ri_lifetime_max_phys_footprint` per system process and fill `lifetimeMaxFootprintBytes` in the report.
2. Add `STTLabRunner` executable target to `Package.swift` with dependencies on `STTLabCore` only (plus system frameworks Speech, AVFoundation, AppKit).
3. Create `ResultsWriter.swift`: manages the results folder, creates/loads/updates `run.json`, writes `apple.json` per meeting, appends to `log.txt`.
4. Create `RunnerJob.swift` (actor): `loadBundle()` delegates to `BundleLoader`, `run()` loops meetings with resume logic, SHA-256 check, delegates to `AppleTranscription` on macOS 26+, writes results through `ResultsWriter`.
5. Create `AppleTranscription.swift` (`@available(macOS 26, *)`): wraps SpeechTranscriber + SpeechAnalyzer + AssetInventory. Converts `SpeechTranscriber.Result` to `AppleMeetingResult`. Watchdog timeout via task group.
6. Create `RunnerModel.swift` (`@MainActor @Observable`): holds state, drives RunnerJob, maps progress to UI.
7. Create `RunnerView.swift`: single-window layout (header, bundle picker, meeting table, controls, progress, log view, reveal button).
8. Create `RunnerApp.swift` (`@main`): WindowGroup, CLI-mode detection in init.
9. Create `scripts/package_runner.sh`: builds release, packages as `.app` with Info.plist, ad-hoc signs, zips.
10. Write tests: `ResultsWriter` round-trip (create session, write result, reload); additional `AppleMeetingResult` edge cases.
11. Update `MemorySamplerTests` to verify `lifetimeMaxFootprintBytes` is populated for system processes.

## Tests

- `ResultsWriterTests.createAndReloadSession`: create a results dir, write a session to run.json, reload and verify fields match.
- `ResultsWriterTests.writeMeetingResult`: write an AppleMeetingResult, read it back, verify equality.
- `ResultsWriterTests.appendsMultipleSessions`: write two sessions, reload, verify both present.
- `MemorySamplerTests`: existing test already checks non-zero footprint; verify `lifetimeMaxFootprintBytes` field is not nil for system processes when available.
