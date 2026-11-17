---
status: complete
---

# Architecture: Apple Speech Engine

Inputs: `functional_spec.md`, `ui_design.md`. Reference code: `experiments/STTLab` (`STTLabRunner/AppleTranscription.swift`, `STTLabAnalysis/AppleWordGrouper.swift`, `STTLabHome/SpeakerAlignment.swift`). Research: `specs/research/stt-engine-swap/apple-speech-apis/`.

Details live in three component docs:

| Component | Doc | Where |
|---|---|---|
| Apple STT inside the engine, API + XPC changes | `components/transcription_engine.md` | `Packages/Transcription`, `XPCServices/BiscottiTranscriber` |
| Engine state, selection, downloads, job wiring, vocab rules | `components/speech_engine_manager.md` | `BiscottiKit`: `DataStore`, `TranscriptionService`, `AppCore`, `SettingsUI` (VM), `MeetingDetailUI` (VM) |
| Sheet, Settings row, onboarding rows, alerts | `components/ui.md` | `BiscottiKit`: `ModelManagementUI`, `SettingsUI`, `OnboardingUI`, `DesignSystem` |

## 1. Overview

```
            App process (BiscottiKit)                                   BiscottiTranscriber.xpc (per job)
┌──────────────────────────────────────────────────────────┐        ┌────────────────────────────────────┐
│ SpeechModelSheet / Settings row / Onboarding rows         │        │ TranscriberService                  │
│        │ observe + actions                                │        │   InProcessTranscriptionEngine      │
│ SpeechEngineManager (@MainActor @Observable)              │        │     config.engine == .whisper ──► WhisperKit
│   selection, locale, per-engine download state            │        │     config.engine == .apple   ──► AppleSpeechSTT
│   ├─ Transcribing (Whisper / Speaker ID download,         │  XPC   │             (SpeechAnalyzer +      │
│   │   presence, delete)  ─────────────────────────────────┼───────►│              AssetInventory)       │
│   └─ AppleSpeechProviding (availability, locales,         │        │     ▼ [TranscriptionResult]        │
│       asset status, asset install w/ progress)            │        │     SpeakerKit diarize + addSpeakerInfo
│ TranscriptionService.executeJob                           │        │     SegmentBuilder → TranscriptSanitizer
│   config = engines.jobConfig()  (method + locale)         │        │     ▼ TranscriptResult (unchanged)  │
│   vocab  = [] if Apple                                    │        └────────────────────────────────────┘
└──────────────────────────────────────────────────────────┘
```

Key idea: **Apple output is bridged into WhisperKit's `TranscriptionResult` type inside the engine**, so speaker attribution (`addSpeakerInfo`), `SegmentBuilder`, `TranscriptSanitizer`, embeddings, voiceprints, storage and every UI downstream stay untouched. This is the exact path the validation experiment measured.

## 2. Key Decisions

| # | Decision | Why |
|---|---|---|
| A1 | Engine + locale travel per call as `TranscriptionConfig { method, locale }`. Apple is a new `TranscriptionMethod` id `"apple-v1"`. Whisper keeps `v2`. | Uses the existing extension point; result types and `TranscriptResult.transcriptionMethodId` semantics unchanged. Callers that pass nothing get today's behavior. |
| A2 | Apple runs **inside** `BiscottiTranscriber.xpc`, same per-job lifecycle as Whisper. | User requirement; memory isolation. |
| A3 | Apple input = the **same** in-memory merge as today (`AudioLoading.loadAndMerge` → 16 kHz mono `[Float]`, shared with SpeakerKit), written to a temp WAV in the XPC process (deleted after the run) and fed with `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)`. Whisper keeps taking the array directly. | The file path is the validated, battle-tested path; the buffer path has a reported `nilError`. Same merged audio as SpeakerKit, so timelines match exactly. |
| A4 | Runs → words with the STTLab word grouper (token = whitespace-separated, times = min/max of overlapping timed runs, confidence = mean). One WhisperKit segment per Apple result. Untimed words get the previous timed word's end time (zero length) instead of being dropped. | Validated grouping (100% whole-word runs); never lose text. |
| A5 | **UI queries and asset installs run in the app process** (`AppleSpeechProviding`, live impl over `Transcription.AppleSpeechSupport`). The XPC engine also calls `assetInstallationRequest` before every job (installs if missing, and reserves the locale for its own process). | Fast UI (no XPC launch to open a sheet); real `Progress` in-process. Reservations are per process, and the system can evict assets, so the job must check every time. **Verified by the Phase 1 spike**; fallback: route status/install through XPC (§5). |
| A6 | Each process keeps at most one reserved locale: before reserving the target locale, release other reserved locales. | `maximumReservedLocales` is small (~5) and per app; locale changes would otherwise leak reservations. |
| A7 | Whisper and Speaker ID become separate download/presence/delete **components** (`ModelComponent.whisper`, `.speakerID`). | Speaker ID is a separate onboarding row and Apple needs only Speaker ID. The engine already downloads them separately. |
| A8 | New `SpeechEngineManager` in the `TranscriptionService` module is the single owner of engine state (mirrors `ModelManager` for LLMs). Onboarding, the sheet and Settings all read and act through it. | One selection code path (user requirement); downloads keep running when onboarding ends. |
| A9 | Selection persists in `AppSettings.sttEngineSelection` (`""`/`"apple"`/`"whisper"`), locale in `AppSettings.appleSpeechLocale`. | Same pattern as `selectedModelID`; additive SwiftData fields. |
| A10 | Custom vocabulary rule is applied in two places only: `TranscriptionService` (send `[]` for Apple) and a shared `effectiveCustomVocabulary` derivation used by Settings, the sheet and the re-transcribe offer. Stored settings are never mutated by engine changes. | User decision: keep the preference and list; restore on switch back. |
| A11 | All Speech framework code is in `Packages/Transcription`, behind `#if canImport(Speech)` and `@available(macOS 26, *)`. Deployment targets stay macOS 15. BiscottiKit never imports Speech. | Builds on the macOS 15 CI runner with the 26 SDK; testable with fakes. |
| A12 | Add `NSSpeechRecognitionUsageDescription` to the app Info.plist (insurance only; no permission request in code). | Research: not needed for `SpeechAnalyzer`, but TCC for an XPC service is attributed to the host app. Zero cost. |

## 3. Data Model Changes

- `AppSettings` (+ `AppSettingsData`, `settings()`, `updateSettings`): `sttEngineSelection: String = ""`, `appleSpeechLocale: String = ""`. No schema bump (additive with defaults, as `DataStoreMigrationPlan` documents).
- `TranscriptRecord`: no change. Apple transcripts store `transcriptionMethodId = "apple-v1"` and `language = <locale identifier>` (e.g. `en_US`); `vocabularyUsed = []`.

## 4. Public Interface Changes (summary)

`Packages/Transcription` (full detail in `components/transcription_engine.md`):

```swift
public enum SpeechEngine: String, Codable, Sendable, CaseIterable { case whisper, apple }
public enum ModelComponent: String, Codable, Sendable, CaseIterable { case whisper, speakerID }

extension TranscriptionMethod {            // now Codable
    public static let appleV1: TranscriptionMethod   // id "apple-v1"
    public var engine: SpeechEngine { get }
}
public struct TranscriptionConfig: Codable, Sendable, Equatable {
    public let method: TranscriptionMethod
    public let locale: String?             // required when method.engine == .apple
    public static func whisper() -> TranscriptionConfig          // .current
    public static func apple(locale: String) -> TranscriptionConfig
}

// Transcriber (defaults keep every existing call site compiling unchanged)
func ensureModelsDownloaded(_ components: Set<ModelComponent> = .all, status: ...) async throws
func processAudio(mic:system:customVocabulary:config: TranscriptionConfig? = nil) async throws -> TranscriptResult
func modelsPresent(_ components: Set<ModelComponent> = .all) async -> Bool
func deleteModels(_ components: Set<ModelComponent>) async throws

public enum AppleSpeechSupport { ... }     // availability, supported locales, asset status, install(progress:)
// TranscriptionError gains: .engineUnavailable(String)
```

`BiscottiKit`: `Transcribing` gains the same component/config parameters; new `AppleSpeechProviding` protocol; new `SpeechEngineManager`; `AppCore.speechEngines`. Detail in `components/speech_engine_manager.md`.

## 5. Technical Risks and Their Answers

| Risk | Answer |
|---|---|
| `SpeechAnalyzer` may not run inside a hardened-runtime XPC service, or may prompt for permission. | **Phase 1 is a hardware spike** on the macOS 26/27 Mac through the ManualTestApp (which embeds the same XPC service). If it fails, stop and escalate (running Apple in the app process breaks a user requirement). |
| Assets installed from the app might not be usable by the XPC process. | Spike checks it. The XPC engine always calls `assetInstallationRequest` first, so the job installs/reserves for itself in any case. If the app-side install proves useless, move install + status to new XPC calls (`appleSpeechStatus`, `installAppleSpeechAssets` with progress over the reverse channel) — the `AppleSpeechProviding` seam keeps that change out of the UI. |
| `AssetInventory.status(forModules:)` is reported unreliable. | Status = "`assetInstallationRequest(supporting:)` returns nil" (research recommendation), not `status(forModules:)`. |
| Asset eviction between sessions. | Status is re-checked on sheet open / Settings load / onboarding step; the job re-checks and installs. |
| Long files hang without `finalizeAndFinish`. | Always call `finalizeAndFinish(through:)` (or `cancelAndFinishNow()` when no audio); watchdog timeout `max(600 s, audio duration)` as in STTLab. |
| Missing confidence values. | `nil` → 1.0 (validated pipeline). |
| CI is macOS 15. | Apple code compiles (26 SDK) but never runs in CI; all logic above the Speech calls is unit-tested with fakes; Apple AI test skips below 26. |
| Deleting Whisper while a job runs. | Delete is disabled while a transcription job is in flight (`TranscriptionService.isJobInFlight`). |
| A job's end-of-job `shutdown()` cuts a sheet download, or a job and a sheet download write the same model files. | The manager uses its own `Transcriber` (own XPC connection), so a job's `shutdown()` never cuts a sheet download. Concurrent downloads of the same model are rare and not coordinated: one may fail and the user retries (user decision). |

## 6. Error Handling

- Engine errors stay `TranscriptionError`; mapping in `TranscriptionService.mapEngineError` adds `.engineUnavailable(detail)` → "Apple Speech isn't available: {detail}", not retriable.
- Apple asset install failure in the job → `.downloadFailed("Apple speech assets: …")` (retriable, today's copy). Analysis failure → `.transcriptionFailed`. Timeout → `.transcriptionFailed("Apple Speech timed out")`.
- Sheet/onboarding install failure → engine state `.failed(message)`, shown with Retry (LLM pattern).
- Logging: `Logger(subsystem: "net.scosman.biscotti", category: "AppleSpeech")` in the engine and `"SpeechEngineManager"` in the app. Never log transcript text.

## 7. Testing Strategy

- **Swift Testing** (`@Suite`/`@Test`), existing targets. No Speech framework in unit tests.
- `TranscriptionTests`: config/method codable + defaults, `MethodResolver` for apple, `XPCProcessRequest` decode with and without `config`, component presence/delete on a temp `ModelStorage`, `AppleWordGrouping` (pure, fed with plain run structs — port of STTLab tests), bridge to `TranscriptionResult` (segment per result, untimed-word fill, confidence default), adapter/hosted client passes config and components.
- `BiscottiKit`: `SpeechEnginePolicy` (recommendation), `AppleLocalePolicy` (default locale), `SpeechEngineManager` (selection writes, migration, download state machine, delete fallback, one-at-a-time, refresh), `TranscriptionService` (config + vocab per engine, components per engine), Settings VM (effective toggle, alert flow), sheet VM (alerts, actions), onboarding row states/footer/Continue persist, re-transcribe offer gating. Fakes: `FakeTranscriber` (extended), new `FakeAppleSpeech`.
- **AI test** (`make test-ai`, macOS 26+ only): Apple engine end-to-end on the 3-speaker fixture.
- **Manual tests**: new `tx_apple_*` steps (Phase 1 spike + final pass). Transcription script marked `not-run`.
- Detailed test lists are in each component doc.

## 8. Docs to Update (last phase)

`specs/architecture.md` (Transcription responsibilities: two engines), `specs/research/stt-engine-swap/summary.md` (decision outcome), `CLAUDE.md` current-stage line, `experiments/STTLab/NOTES.md` (graduated pointer).

## 9. Re-transcribe With a Chosen Model (amendment, Phase 6)

Behavior: `functional_spec.md` §12; UI: `ui_design.md` §7. Detail: `components/speech_engine_manager.md` ("Re-transcribe engine override") and `components/ui.md` §6.

**Decisions**
- **A13 — Per-job engine override in `TranscriptionService`.** `reTranscribe(meetingID:config:)` gains an optional `TranscriptionConfig`. `nil` keeps today's behavior (the target from `SpeechEngineManager.jobConfig()`). With an override, the job uses that config, and derives components and vocabulary from the **override's** engine. No `Transcribing`, `Transcriber`, XPC or `Packages/Transcription` change: `processAudio` already takes a config.
- **A14 — Vocabulary follows the job's engine.** `executeJob` already branches on `config.engine`; a Whisper override sends `vocabulary.effectiveVocabulary(meetingID:)` (stored preference), even when the target is Apple. The target-based display rules (A10) are unchanged.
- **A15 — No data model change.** The "current transcription" marker reads `TranscriptVersionData.methodId` of the newest version → `TranscriptionMethod(id:).engine` (empty/unknown → `.whisper`).
- **A16 — Menu model is a pure builder in `MeetingDetailUI`.** `ReTranscribeMenuBuilder` maps engine states + current engine to item text/enabled. It reads `SpeechEngineManager.isReady(_:)`, `appleAvailability`, `apple`, `whisper` (no new manager API).

**Risks**

| Risk | Answer |
|---|---|
| Nested SwiftUI `Menu` inside the overflow `Menu` renders badly on some macOS 15 builds. | The app already uses nested menus; check on macOS 15 in the final pass (Phase 7). |
| The override is accidentally persisted. | The override path never calls `SpeechEngineManager` write methods; a test asserts the selection is unchanged after an override job. |
| Vocabulary sent to a Whisper override while Settings shows vocab off (target Apple). | Intended (user decision); documented in functional spec §12.1. |
| Old transcripts have an empty method id. | Empty → Whisper, which is correct for every pre-Apple transcript. |

**Testing:** `TranscriptionServiceOverrideTests`, `ReTranscribeMenuBuilderTests`, `MeetingDetailReTranscribeEngineTests` (lists in the component docs). No Transcription-package or manual-test changes.
