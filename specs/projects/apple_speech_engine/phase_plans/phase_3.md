---
status: complete
---

# Phase 3: App State (BiscottiKit)

## Overview

Add all app-side speech-engine state management: persistence fields, the `Transcribing` protocol expansion (components + config), `AppleSpeechProviding` protocol, pure policies, `SpeechEngineManager`, `TranscriptionService` job wiring, AppCore dual-Transcriber construction, custom vocabulary engine gating, Settings VM vocabulary logic, and the re-transcribe offer guard. Fakes and tests for all new logic.

## Steps

### 1. DataStore: Add `sttEngineSelection` and `appleSpeechLocale` to AppSettings

- `AppSettings`: add `public var sttEngineSelection: String = ""` and `public var appleSpeechLocale: String = ""` with matching init parameters.
- `AppSettingsData`: add same two fields, mirror them in `settings()` read and `updateSettings` write-back.

### 2. TranscriptionService: Expand `Transcribing` protocol

- Add component + config parameters to `Transcribing`:
  - `ensureModelsDownloaded(_ components: Set<ModelComponent>, status:)`
  - `processAudio(mic:system:customVocabulary:config: TranscriptionConfig)`
  - `modelsPresent(_ components: Set<ModelComponent>)`
  - `deleteModels(_ components: Set<ModelComponent>)`
- Add re-exports for `SpeechEngine`, `ModelComponent`, `TranscriptionConfig`, `AppleSpeechAvailability` from `Transcribing.swift`.

### 3. TranscriptionService: Add `AppleSpeechProviding` protocol and value types

- New file `AppleSpeechProviding.swift` in TranscriptionService:
  - `AppleSpeechProviding` protocol
  - `LiveAppleSpeechProvider` (delegates to `AppleSpeechSupport`)
  - `EngineDownloadState` enum
  - `AppleLocaleOption` struct

### 4. TranscriptionService: Add pure policies

- New file `SpeechEnginePolicies.swift`:
  - `AppleLocalePolicy` with `defaultLocale`, `languageSupported`, `options`
  - `SpeechEnginePolicy` with `recommended`

### 5. TranscriptionService: Add `SpeechEngineManager`

- New file `SpeechEngineManager.swift`:
  - `@MainActor @Observable public final class SpeechEngineManager`
  - Observable state: selection, appleAvailability, appleLocales, appleLocale, apple/whisper/speakerID download states, hasEnoughDiskForWhisper, languageSupported
  - Derived: recommended, target, isReady, targetReady, isAnyDownloadInFlight, appleLanguageName, summaryLabel, osMajorVersion, jobConfig, jobComponents
  - Actions: refresh, download, choose, deleteWhisper, setAppleLocale, downloadSpeakerID, persistTargetIfUnset
  - effectiveCustomVocabulary helper

### 6. TranscriptionService: Wire engine config into `TranscriptionService`

- Add `engines: SpeechEngineManager` dependency to `TranscriptionService`.
- Add `public var isJobInFlight: Bool`.
- In `executeJob`: use `engines.jobConfig()` for config, `engines.jobComponents()` for components, send empty vocab for Apple.
- Call `engines.refresh()` after job completes.

### 7. AppCore: Dual Transcriber wiring

- In `AppCore+Live.buildTranscription`: create two `Transcriber(.hosted)` instances (job + manager), build `LiveAppleSpeechProvider`, `SpeechEngineManager`, wire into `TranscriptionService`.
- Add `public let speechEngines: SpeechEngineManager` to `AppCore`.
- In `onLaunch()`: call `speechEngines.refresh()` after `modelManager.refresh()`.
- Update `AppCore.init` to accept `speechEngines`.

### 8. Update `LiveTranscriberAdapter` for new `Transcribing` protocol

- Forward component/config parameters to the real `Transcriber`.

### 9. MeetingDetailUI: Gate re-transcribe offer on target engine

- In `shouldOfferReTranscribe()`: add `core.speechEngines.target == .whisper` guard.

### 10. SettingsUI: Custom vocabulary engine gating

- `SettingsViewModel`: add `customVocabularyDisplayed` (effective = stored AND whisper target), `requestCustomVocabularyEnabled`, `switchToWhisperForVocabulary`, `showRequiresWhisperAlert`, `requiresWhisperAlertMessage`.
- `SettingsVocabularySection`: wire toggle to `requestCustomVocabularyEnabled`, show alert.

### 11. PreviewAppCore + CoreFixture: Add fakes

- `FakeTranscriber`: expand for components/config/delete.
- New `FakeAppleSpeech`: implements `AppleSpeechProviding`.
- Update `CoreFixture`, `makeCoreFixture`, `PreviewAppCore` to build `SpeechEngineManager`.

### 12. Tests

- `AppleLocalePolicyTests`
- `SpeechEnginePolicyTests`
- `SpeechEngineManagerTests` (refresh, selection, download, delete, locale, migration)
- `TranscriptionServiceEngineTests` (config, components, vocab per engine)
- `ReTranscribeOfferTests` (gated on engine)
- `SettingsVocabularyEngineTests` (effective toggle, alert, switch)
- `DataStore` settings round-trip for new fields

## Tests

- `AppleLocalePolicyTests`: exact match, equivalent, same-language fallback, en_US fallback, languageSupported, options sorted
- `SpeechEnginePolicyTests`: available+supported -> apple, unsupported -> whisper, requiresOSUpdate -> whisper, unavailable -> whisper
- `SpeechEngineManagerRefreshTests`: states from fakes, keeps in-flight, stored locale kept/replaced, migration
- `SpeechEngineManagerSelectionTests`: download saves selection, choose requires ready, apple persists locale, target fallback
- `SpeechEngineManagerDownloadTests`: one-at-a-time, disk guard, progress, failure, speaker ID independent
- `SpeechEngineManagerDeleteTests`: delete whisper -> apple when available, stays whisper on macOS 15, blocked while job in flight
- `SpeechEngineManagerLocaleTests`: setAppleLocale persists, re-checks assets, rejects unknown
- `TranscriptionServiceEngineTests`: apple config/components/vocab, whisper config/components/vocab, refresh after job
- `ReTranscribeOfferTests`: not offered when target apple
- `SettingsVocabularyEngineTests`: displayed off when apple, alert on toggle, switch variants
- `DataStoreSettingsRoundTripTests`: sttEngineSelection and appleSpeechLocale
