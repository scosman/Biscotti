---
status: complete
---

# Phase 2: Apple Runtime + Hardware Spike

## Overview

Fill in the Phase 1 stubs with real Speech framework calls (`AppleSpeechSupport`, `AppleLocaleReservations`, `AppleSpeechSTT`), wire the `.apple` branch in `InProcessTranscriptionEngine`, add `--engine`/`--locale` to the CLI (already done in Phase 1 -- verify it works), add `NSSpeechRecognitionUsageDescription` to the app Info.plist, add the Apple AI test, add ManualTestApp `tx_apple_*` steps and fixture wiring, and mark `tx_*` not-run per the staleness rule. Hardware validation (XPC, no prompt, asset usability) defers to Phase 6's manual-test pass.

## Steps

1. **`AppleSpeech/AppleSpeechSupport.swift`**: Replace the Phase 1 stubs with real implementations behind `#if canImport(Speech)` + `@available(macOS 26, *)`. `availability()` checks `SpeechTranscriber.isAvailable` on 26+. `supportedLocales()` returns `SpeechTranscriber.supportedLocales` identifiers. `supportedLocale(equivalentTo:)` delegates to `SpeechTranscriber.supportedLocale(equivalentTo:)`. `assetsInstalled(locale:)` creates a `SpeechTranscriber` for the locale, checks `AssetInventory.assetInstallationRequest(supporting:)` -- nil means installed. Also performs locale reservation management (A6). `installAssets(locale:progress:)` creates the transcriber, gets the install request, calls `downloadAndInstall()` while observing `progress.fractionCompleted`.

2. **New file `AppleSpeech/AppleLocaleReservations.swift`**: `@available(macOS 26, *)` helper. `prepare(locale:) async throws -> SpeechTranscriber` -- releases previously reserved locales via `AssetInventory.reservedLocales` then builds a `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` and returns it.

3. **New file `AppleSpeech/AppleSpeechSTT.swift`**: `@available(macOS 26, *)` runner. `transcribe(samples:duration:locale:status:) async throws -> [TranscriptionResult]`. Resolves locale, prepares transcriber via `AppleLocaleReservations.prepare`, checks/installs assets, writes temp WAV via `WAVWriter`, runs `SpeechAnalyzer.analyzeSequence(from:)`, collects results, calls `finalizeAndFinish`/`cancelAndFinishNow`, applies watchdog timeout, bridges results via `AppleWordGrouping.transcriptionResults`. Extracts `AppleResultInput` from `AttributedString` runs with `audioTimeRange` and `transcriptionConfidence`.

4. **`InProcessTranscriptionEngine.swift`**: Replace the `.apple` case placeholder with a call to `runAppleSTT(samples:duration:locale:status:)`. The new private helper uses `#if canImport(Speech)` + `@available(macOS 26, *)` to call `AppleSpeechSTT.transcribe`, falling back to throwing `.engineUnavailable` on older OS.

5. **`App/Resources/Info.plist`**: Add `NSSpeechRecognitionUsageDescription` key: "Biscotti transcribes meetings on your Mac with Apple's built-in speech model." (A12 insurance).

6. **`AIModelTests.swift`**: Add `appleEndToEnd3Speaker` test -- uses `Transcriber(.inProcess)` with `.apple(locale: "en_US")` on the 3-speaker fixture. Asserts non-empty words with times, >=2 speakers, `transcriptionMethodId == "apple-v1"`, `language == "en_US"`. Gated on `AITestGate.isEnabled` and macOS 26+ (`#available`).

7. **`TranscriptionScript.swift` (ManualTestKit)**: Add five new steps: `tx_apple_status` (action), `tx_apple_install` (action), `tx_apple_transcribe` (action), `tx_apple_no_prompt` (humanQuestion), `tx_apple_output_ok` (humanQuestion).

8. **`WiredScripts.swift` (ManualTestApp)**: Wire the three `tx_apple_*` action steps to real `Transcription.AppleSpeechSupport` and `Transcriber(.hosted)` calls.

9. **`ManualTestApp/project.yml`**: Add the test fixture WAV files as bundle resources by path from `Packages/Transcription/Tests/TranscriptionTests/Fixtures/`.

10. **`manual_test_results.json`**: Mark all `tx_*` steps as `not-run` per the staleness rule. Add new `tx_apple_*` recordable step entries as `not-run`.

## Tests

- `appleEndToEnd3Speaker` (AI test, macOS 26+ only): Apple engine on 3-speaker fixture -- non-empty words, times, >=2 speakers, method id, language
- `appleSupportUnavailableBelow26` (existing, CI): still passes -- returns `.requiresOSUpdate` on macOS 15
- All existing tests remain green (no regressions from the runtime additions)
