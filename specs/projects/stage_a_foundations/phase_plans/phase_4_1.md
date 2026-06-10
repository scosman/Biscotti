---
status: complete
---

# Phase 4.1: ManualTestKit (testable harness logic)

## Overview

Add the `ManualTestKit` library target to `Packages/BiscottiKit` with all the value types, test scripts, auto-check helpers, and results store needed by the manual test app. This is pure, unit-testable Swift with no UI, no Core Audio, no XPC. The app shell (Phase 4.2) will render these types; this phase only builds the logic.

## Steps

1. **Package.swift** — add `ManualTestKit` library product, source target (no dependencies on other BiscottiKit modules), and `ManualTestKitTests` test target depending on `ManualTestKit`.

2. **Value types** — create source files under `Sources/ManualTestKit/`:
   - `TestStep.swift` — `public enum TestStep: Sendable, Identifiable` with cases `.action`, `.instruction`, `.humanQuestion`, `.autoCheck`, each carrying an `id: String` plus case-specific payloads (closures for action/autoCheck).
   - `CheckOutcome.swift` — `public struct CheckOutcome: Sendable, Equatable` with `passed: Bool` and `detail: String`.
   - `TestScript.swift` — `public struct TestScript: Sendable, Identifiable` with `id`, `title`, `steps: [TestStep]`.
   - `TestStatus.swift` — `public enum TestStatus: String, Codable, Sendable` with `.pass`, `.fail`, `.notRun` (raw value `"not-run"`).
   - `TestResult.swift` — `public struct TestResult: Codable, Sendable, Equatable` with `stepID`, `status`, optional `note`, optional `timestamp`.

3. **Test scripts** — `Scripts/` subdirectory:
   - `AudioCaptureScript.swift` — a public static property returning a `TestScript` with steps derived from the AudioLab VALIDATION.md: request permissions, confirm two dialogs, timed capture, auto-check two `.aac` files exist with sane sizes, playback quality, route-change, crash-safety, monitoring.
   - `TranscriptionScript.swift` — a public static property returning a `TestScript` with steps derived from the ArgMaxKit VALIDATION.md: model download, transcribe over XPC, auto-check diarized output has >=2 speakers and no segment past audio duration, crash-isolation, custom-vocab.
   - `allScripts` — a public list of both scripts for iteration.

4. **Auto-check helpers** — `AutoChecks.swift`:
   - `checkAACFilesExist(micURL:systemURL:minBytes:)` — pure function returning `CheckOutcome`; checks both files exist and exceed a minimum size threshold.
   - `checkNoSegmentPastDuration(segmentEndTimes:audioDuration:)` — pure function returning `CheckOutcome`; verifies no segment end time exceeds audio duration (with a small tolerance).

5. **ResultsStore** — `ResultsStore.swift`:
   - `public struct ResultsStore: Sendable` initialized with a `fileURL: URL`.
   - `load() throws -> [String: TestResult]` — reads JSON from disk; returns empty dict if file missing.
   - `save(_:) throws` — writes the dictionary as JSON.
   - `record(_ result: TestResult) throws` — loads, merges (overwrites by stepID), saves.
   - `markScriptNotRun(scriptID:allStepIDs:) throws` — sets all listed step IDs to `.notRun` status.
   - `allStepIDs(in scripts: [TestScript]) -> [String]` — collects every step ID across scripts.
   - `unrun(in scripts: [TestScript]) throws -> [String]` — returns step IDs that are `.notRun` or missing from the results file.

## Tests

- **`ResultsStoreTests`** — load from empty/missing file returns empty dict; record overwrites existing entry; `markScriptNotRun` sets all steps to `.notRun`; `unrun` returns exactly the not-run/missing IDs; round-trip encode/decode fidelity.
- **`ScriptShapeTests`** — both scripts have non-empty, unique step IDs; step count is non-zero; all IDs are stable and unique across both scripts.
- **`CIGateTests`** — given a results file with one `.notRun`, `unrun` reports it; given all `.pass`, `unrun` returns empty; given a missing step ID, `unrun` includes it.
- **`CheckOutcomeTests`** — `checkAACFilesExist` passes with valid files above threshold, fails with missing/small files; `checkNoSegmentPastDuration` passes when all segments are within duration, fails when one exceeds it.
