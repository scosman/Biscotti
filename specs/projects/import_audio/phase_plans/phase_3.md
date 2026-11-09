---
status: complete
---

# Phase 3: AudioImport module and AppCore wiring

## Overview

Builds the core AudioImport module (classifier, AVFoundation converter, metadata reader, session controller, header copy) and wires it into AppCore (Route.importing, importFiles, showImport, import-panel request flag, completion -> queue + ImportAutoNavigation, staging cleanup on launch). Also adds `DataStore.createImportedMeeting` and `FakeAudioConverter` test support. This phase delivers the full non-UI import pipeline: files go in, meetings come out, transcription is queued.

## Steps

1. **Add `AudioImport` target to Package.swift.** New library target depending on DataStore and AudioCapture. New test target `AudioImportTests` depending on AudioImport, DataStore, BiscottiTestSupport. Add AudioImport as a dependency of AppCore and BiscottiTestSupport.

2. **`ImportFileClassifier.swift`** -- `isSupported(_ type: UTType)`, `isSupported(fileURL:)`, `isSupported(typeIdentifier:)`, `allowedContentTypes`. Uses UTType conformance checks against `.audio` and `.audiovisualContent`.

3. **`AudioConverting` protocol and `AVFoundationAudioConverter`** -- Protocol with `convert(source:destination:) async throws -> ConversionResult`. Live implementation using AVAssetReader + ExtAudioFile per architecture section 4.2. Runs in `Task.detached`.

4. **`ImportMetadataReading` protocol and `AVFoundationMetadataReader`** -- Protocol with `meetingDate(for:) async -> Date?`. Reads embedded creation date, falls back to file modification date.

5. **`ImportEntry`, `ImportItem`, `ImportItemStatus`, `ImportFailure`, `ImportRun`, `ImportFinished` types** -- Public types per component doc section 2.

6. **`ImportHeaderCopy`** -- Pure function mapping items + run state to title/status strings, per functional spec section 5.2.

7. **`AudioImportController`** -- The session controller: `add(_:)`, worker loop, `hasPendingWork`, `isConverting`, `hasSession`, `onItemFinished`, `cleanStaging`, `awaitIdle`, `runPosition`. Per component doc section 6.

8. **`DataStore+Import.swift`** with `createImportedMeeting(id:title:start:duration:audioPath:audioByteSize:)`.

9. **`FakeAudioConverter` in BiscottiTestSupport** -- Scriptable outcomes, gate, records converted sources.

10. **`Route.importing`** -- Add the case to Route enum. Update exhaustive switches.

11. **AppCore wiring** -- `audioImport` property, `importFiles(_:)`, `showImport()`, `importPanelRequested`/`requestImportPanel()`/`consumeImportPanelRequest()`. `onItemFinished` callback (reload summaries, enqueue transcription, ImportAutoNavigation). `cleanStaging` in onLaunch.

12. **`ImportAutoNavigation`** -- Pure enum with `shouldNavigate(batchSize:controllerHasPendingWork:route:)`.

13. **Update `CoreFixture` and `makeCoreFixture`** to inject `AudioImportController` with `FakeAudioConverter`.

14. **Tests** -- AudioImportTests (classifier, converter real-file, metadata, controller, header copy), AppCoreTests/AppCoreImportTests (import wiring, auto-navigation, queue integration, import panel).

## Tests

- `ImportFileClassifierTests`: isSupported for audio types (wav, mp3, m4a, etc.), movie types (mp4, mov), unsupported types, directories, type identifiers.
- `AVFoundationAudioConverterTests`: real-file tests -- stereo 44k WAV to mono 24k ADTS, mono 48k resampling, 6-channel downmix, AAC M4A source, zero-frame throws noAudio, garbage bytes throws unreadable, missing source throws sourceMissing.
- `ImportMetadataReaderTests`: no embedded date uses modification date, missing file returns nil.
- `AudioImportControllerTests`: add files processed in order, add while running extends run, done creates meeting with placeholder title, failed conversion leaves no meeting, future date clamped, nil date falls back, promises, onItemFinished callback, run cleared when idle, runPosition, cleanStaging.
- `ImportHeaderCopyTests`: one test per functional spec section 5.2 row.
- `AppCoreImportTests`: importFiles routes to importing, onboarding guard, import done enqueues transcription, single-file auto-navigation, multi-file no auto-navigate, delete queued meeting, import panel request flag.
- `ImportAutoNavigationTests`: truth table of the pure predicate.
