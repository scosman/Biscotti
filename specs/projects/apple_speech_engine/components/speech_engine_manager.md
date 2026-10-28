---
status: complete
---

# Component: Speech Engine Manager (BiscottiKit state and wiring)

## Purpose and Scope

Own all speech-engine state in the app process: selection, recommendation, Apple locale, per-engine readiness and downloads, Speaker ID readiness. Feed the transcription job its config. Apply the custom-vocabulary rule. Mirrors `Intelligence/ModelManager` for LLMs.

Not in scope: views (see `ui.md`), the engine itself (see `transcription_engine.md`).

## Persistence (`DataStore`)

`AppSettings` + `AppSettingsData` (+ `settings()` mapping, `updateSettings` DTO build and write-back; ~8 touch points, as for `calendarVocabularyEnabled`):

```swift
public var sttEngineSelection: String = ""   // "", "apple", "whisper"
public var appleSpeechLocale: String = ""    // "" = unresolved; else a supported locale identifier
```

## Public Interface (`TranscriptionService` module)

### Seams

```swift
/// App-side Apple Speech queries. Live impl wraps Transcription.AppleSpeechSupport.
public protocol AppleSpeechProviding: Sendable {
    func availability() -> AppleSpeechAvailability                // re-exported from Transcription
    func supportedLocales() async -> [String]
    func supportedLocale(equivalentTo id: String) async -> String?
    func assetsInstalled(locale: String) async -> Bool            // errors → false (logged)
    func installAssets(locale: String, progress: @escaping @Sendable (Double?) -> Void) async throws
}
public struct LiveAppleSpeechProvider: AppleSpeechProviding { public init() }

public protocol Transcribing: Sendable {           // changed
    func ensureModelsDownloaded(_ components: Set<ModelComponent>, status: (@Sendable (String) -> Void)?) async throws
    func processAudio(mic: URL, system: URL, customVocabulary: [String], config: TranscriptionConfig) async throws -> TranscriptResult
    func modelsPresent(_ components: Set<ModelComponent>) async -> Bool
    func deleteModels(_ components: Set<ModelComponent>) async throws
    func shutdown() async
}
```

Re-export `SpeechEngine`, `ModelComponent`, `TranscriptionConfig`, `AppleSpeechAvailability` from `Transcribing.swift` (same `@_exported import` pattern as `TranscriptResult`). `LiveTranscriberAdapter` (AppCore) forwards to `Transcriber`.

### Value types

```swift
public enum EngineDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double?)   // nil = indeterminate
    case downloaded
    case failed(message: String)
}

public struct AppleLocaleOption: Sendable, Equatable, Identifiable {
    public let id: String            // locale identifier
    public let displayName: String   // Locale.current.localizedString(forIdentifier:) e.g. "English (United States)"
    public let languageName: String  // localizedString(forLanguageCode:) e.g. "English"
}
```

### Pure policies (unit-tested)

```swift
public enum AppleLocalePolicy {
    /// §6.2: exact/equivalent match → same language (prefer language's default region,
    /// i.e. Locale(languageCode:).identifier-style "fr_FR") → "en_US".
    public static func defaultLocale(current: Locale, supported: [String], equivalent: String?) -> String
    /// Some supported locale shares current's language code.
    public static func languageSupported(current: Locale, supported: [String]) -> Bool
    public static func options(for supported: [String], displayLocale: Locale) -> [AppleLocaleOption]  // sorted by displayName
}

public enum SpeechEnginePolicy {
    /// §4.2: .apple iff availability == .available && languageSupported; else .whisper.
    public static func recommended(availability: AppleSpeechAvailability, languageSupported: Bool) -> SpeechEngine
}
```

### `SpeechEngineManager` (`@MainActor @Observable`, `public final class`)

```swift
// Observable state
public private(set) var selection: SpeechEngine?            // nil = ""
public private(set) var appleAvailability: AppleSpeechAvailability = .requiresOSUpdate(currentMajor: 15)
public private(set) var appleLocales: [AppleLocaleOption] = []
public private(set) var appleLocale: String = "en_US"        // resolved (stored or default)
public package(set) var apple: EngineDownloadState = .notDownloaded
public package(set) var whisper: EngineDownloadState = .notDownloaded
public package(set) var speakerID: EngineDownloadState = .notDownloaded
public private(set) var hasEnoughDiskForWhisper: Bool = true
public private(set) var languageSupported: Bool = false

// Derived
public var recommended: SpeechEngine
public var target: SpeechEngine            // selection (if apple, only when appleAvailability == .available) ?? recommended
public func isReady(_ engine: SpeechEngine) -> Bool   // apple: available && apple == .downloaded; whisper: whisper == .downloaded
public var targetReady: Bool
public var isAnyDownloadInFlight: Bool     // apple/whisper/speakerID .downloading
public var appleLanguageName: String       // from appleLocales; fallback Locale display of appleLocale
public var summaryLabel: String            // "Apple Speech (English only)" | "Whisper"
public var osMajorVersion: Int
public func jobConfig() -> TranscriptionConfig   // target == .apple ? .apple(locale: appleLocale) : .whisper()
public func jobComponents() -> Set<ModelComponent>  // apple: [.speakerID]; whisper: .all

// Actions
public func refresh() async
public func download(_ engine: SpeechEngine) async   // saves selection first, then downloads
public func choose(_ engine: SpeechEngine) async     // requires isReady(engine)
public func deleteWhisper() async
public func setAppleLocale(_ id: String) async
public func downloadSpeakerID() async
public func persistTargetIfUnset() async             // onboarding Continue
```

Init: `SpeechEngineManager(store: DataStore, transcriber: any Transcribing, apple: any AppleSpeechProviding, diskProbe: @Sendable () -> Int64?, isJobInFlight: @MainActor () -> Bool)`.

## Internal Design

### `refresh()`
Called from `AppCore.onLaunch()` (after `modelManager.refresh()`), Settings `load()`, sheet `onAppear`, onboarding model-step probes.
1. `appleAvailability = apple.availability()`. If `.available`: `supported = await apple.supportedLocales()`, `appleLocales = AppleLocalePolicy.options(…)`, `languageSupported = AppleLocalePolicy.languageSupported(.current, supported)`.
2. Load settings. `selection = SpeechEngine(rawValue: sttEngineSelection)`.
3. `appleLocale`: stored value if it is in `supported`; else `AppleLocalePolicy.defaultLocale(current: .current, supported:, equivalent: await apple.supportedLocale(equivalentTo: Locale.current.identifier))`. Not persisted here (§4.1 persists on user change or when Apple is selected).
4. States (keep an in-flight `.downloading` untouched): `whisper = await transcriber.modelsPresent([.whisper]) ? .downloaded : .notDownloaded`; same for `speakerID`; `apple = (available && await apple.assetsInstalled(locale: appleLocale)) ? .downloaded : .notDownloaded`.
5. `hasEnoughDiskForWhisper = (diskProbe() ?? .max) >= 750 MB`.
6. **Migration (§4.4):** if `selection == nil && settings.onboardingComplete && whisper == .downloaded` → `writeSelection(.whisper)`.

### `writeSelection(_:)` (private)
Sets `selection`, persists `sttEngineSelection`. When the engine is `.apple`, also persists `appleSpeechLocale = appleLocale` if the stored value is empty. Every selection write goes through here.

### `download(_ engine:)`
Guard: not `isAnyDownloadInFlight`; whisper also requires `hasEnoughDiskForWhisper`; apple requires `.available`.
1. `await writeSelection(engine)` (saved before the download finishes — D1).
2. Whisper: `whisper = .downloading(nil)`; `try await transcriber.ensureModelsDownloaded([.whisper], status: nil)`; → `.downloaded`; error → `.failed(short message)`; then `await transcriber.shutdown()`.
   Apple: `apple = .downloading(nil)`; `try await apple.installAssets(locale: appleLocale) { f in Task { @MainActor in self.apple = .downloading(fraction: f) } }` with 1 % throttling (reuse the LLM `LastFraction` idea; small local copy); → `.downloaded` (guard against a late progress Task by setting state after awaiting, as `ModelManager` notes) ; error → `.failed`.
3. Cancellation → `.notDownloaded`.

### `downloadSpeakerID()`
Same as Whisper with `[.speakerID]`, state `speakerID`; no selection change; same one-at-a-time guard.

### `choose(_:)`
Guard `isReady(engine)`; `writeSelection(engine)`.

### `deleteWhisper()`
Guard `whisper == .downloaded && !isJobInFlight()`. `try await transcriber.deleteModels([.whisper])`; `whisper = .notDownloaded`. If `target` was `.whisper` before the delete and `appleAvailability == .available` → `writeSelection(.apple)`; else keep the selection (`whisper`, not ready). Errors are logged; state re-read from disk.

### `setAppleLocale(_:)`
Guard id ∈ `appleLocales`. `appleLocale = id`; persist `appleSpeechLocale`; `apple = await apple.assetsInstalled(locale: id) ? .downloaded : .notDownloaded` (no auto-download — user decision: show Download).

### `persistTargetIfUnset()`
`if selection == nil { await writeSelection(target) }`.

### Custom vocabulary (A10)

```swift
public extension SpeechEngineManager {
    /// Effective custom vocabulary = stored preference AND target is Whisper.
    func effectiveCustomVocabulary(storedPreference: Bool) -> Bool { storedPreference && target == .whisper }
}
```

- `TranscriptionService.executeJob`: `let config = engines.jobConfig()`; `downloadModels` calls `engine.ensureModelsDownloaded(engines.jobComponents(), status:)`; `vocab = config.engine == .apple ? [] : await vocabulary.effectiveVocabulary(meetingID:)`; `processAudio(…, config:)`; persist `vocabularyUsed: vocab`. Config is captured once at job start. After the job, call `await engines.refresh()` so a job-time download/install flips the UI to ready.
- `TranscriptionService` gains `public var isJobInFlight: Bool { inFlightMeetingID != nil }` and an `engines` dependency (init param).
- `MeetingDetailViewModel.shouldOfferReTranscribe()`: add `core.speechEngines.target == .whisper` to the guard.
- `SettingsViewModel`:
  - Keep `customVocabularyEnabled` as the **stored** value; add `var customVocabularyDisplayed: Bool { core.speechEngines.effectiveCustomVocabulary(storedPreference: customVocabularyEnabled) }`. The section's toggle binding and the child-row visibility use `customVocabularyDisplayed`.
  - `requestCustomVocabularyEnabled(_ on: Bool)`: if `on && core.speechEngines.target == .apple` → `showRequiresWhisperAlert = true` (no write); else existing `setCustomVocabularyEnabled(on)`.
  - `switchToWhisperForVocabulary()`: `showRequiresWhisperAlert = false`; if Whisper ready → `await engines.choose(.whisper)`, else `Task { await engines.download(.whisper) }` (selection is saved immediately inside `download`); then `await setCustomVocabularyEnabled(true)`.
  - `requiresWhisperAlertMessage`: two variants by `engines.isReady(.whisper)` (ui_design §4).

### AppCore wiring

`buildTranscription` creates **two** `Transcriber(.hosted)` instances on the same service name — one for jobs (`TranscriptionService`) and one for the manager (downloads, presence, delete) — each wrapped in a `LiveTranscriberAdapter`. Separate instances mean separate XPC connections, so a job's end-of-job `shutdown()` never cuts a sheet download (and vice versa); the service process exits only when its last connection closes (`ConnectionCounter`). It then creates the `SpeechEngineManager` (store, manager adapter, `LiveAppleSpeechProvider()`, disk probe on the Application Support volume via `volumeAvailableCapacityForImportantUsage`, `isJobInFlight` closure bound to the service after construction) and `TranscriptionService(store:engine:vocabulary:engines:)`. `AppCore` gains `public let speechEngines: SpeechEngineManager`. `PreviewAppCore` and `CoreFixture` build it with fakes. The manager calls `shutdown()` on its own `Transcriber` after each of its downloads.

**Concurrent job + sheet download:** not coordinated (rare). If both touch the same model at once, one may fail and the user retries. Only Delete Whisper is blocked while a job runs.

## Dependencies

- Uses: `DataStore`, `Transcription` (types, `AppleSpeechSupport` via the live provider), `Vocabulary` (unchanged).
- Used by: `AppCore`, `ModelManagementUI`, `SettingsUI`, `OnboardingUI`, `MeetingDetailUI`, `ManualTestApp` (indirectly).

## Test Plan

`BiscottiTestSupport`: extend `FakeTranscriber` (records components, config, delete calls; per-component presence; scripted errors) and add `FakeAppleSpeech` (availability, supported locales, equivalent locale, installed set, scripted progress values, scripted error).

| Suite / test | Verifies |
|---|---|
| `AppleLocalePolicyTests`: exact match, equivalent match, same-language fallback prefers default region, `en_US` fallback, `languageSupported` true/false, options sorted + names | §6.2 |
| `SpeechEnginePolicyTests`: available+supported → apple; unsupported language → whisper; requiresOSUpdate / unavailable → whisper | §4.2 |
| `SpeechEngineManagerRefreshTests`: states from fakes; keeps in-flight; stored locale kept/replaced when unsupported; migration sets whisper only when onboarded+Whisper present; no migration when not onboarded | §4.4, §5 |
| `SpeechEngineManagerSelectionTests`: download saves selection before completion; choose requires ready; apple selection persists locale; target falls back to whisper when apple selected but unavailable (stored value kept); `persistTargetIfUnset` writes only when nil | §4.3 |
| `SpeechEngineManagerDownloadTests`: one-at-a-time guard; whisper disk guard;  apple progress fractions (throttled) → downloaded; failure → failed; cancellation → notDownloaded; speaker ID download independent of selection | §5 |
| `SpeechEngineManagerDeleteTests`: delete whisper as target → apple when available, stays whisper on macOS 15; blocked while job in flight; Speaker ID untouched | §5.4 |
| `SpeechEngineManagerLocaleTests`: `setAppleLocale` persists, re-checks assets, no auto-download; rejects unknown id | §6 |
| `TranscriptionServiceEngineTests`: apple target → config apple(locale), components [.speakerID], vocab [] sent and stored; whisper → config whisper, components all, vocab from service; refresh after job | A10, §5.5 |
| `ReTranscribeOfferTests` (MeetingDetailUI): not offered when target apple even with vocab on | §7.1 |
| `SettingsVocabularyEngineTests`: displayed off when apple + stored on; on-request while apple → alert, no write; switch to Whisper (ready → choose; not ready → download) + stored on; message variants | §7.2–7.3 |
| `DataStore` settings round-trip for the two new fields | §4.1 |

## Re-transcribe engine override (amendment, Phase 6)

Functional spec §12, architecture A13–A15.

```swift
// TranscriptionService
public func reTranscribe(meetingID: UUID, config: TranscriptionConfig? = nil) async
private func runJob(meetingID: UUID, configOverride: TranscriptionConfig? = nil) async
private func executeJob(meetingID: UUID, configOverride: TranscriptionConfig?) async
```

- `executeJob`: `let config = configOverride ?? engines?.jobConfig() ?? .whisper()`. Components: with an override, `config.engine == .apple ? [.speakerID] : .all`; without, `engines?.jobComponents() ?? .all` (unchanged). Vocabulary: unchanged line `config.engine == .apple ? [] : await vocabulary.effectiveVocabulary(meetingID:)` — so it follows the job's engine.
- First transcriptions (`Transcribe now`, the automatic job after recording) never pass an override.
- The override is never written to settings. `engines.refresh()` after the job is unchanged.
- `SpeechEngineManager`: no new API. Callers build the Apple config with `TranscriptionConfig.apple(locale: engines.appleLocale)`.

| Suite / test | Verifies |
|---|---|
| `TranscriptionServiceOverrideTests`: Whisper override with target Apple → config whisper, components `.all`, vocab from service (stored on), stored `vocabularyUsed`; Apple override with target Whisper → config apple(saved locale), components `[.speakerID]`, vocab `[]`; nil override = target (regression); selection and locale unchanged after an override job | §12.1, A13–A14 |
