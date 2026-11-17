---
status: complete
---

# Component: UI (Sheet, Settings, Onboarding, Alerts)

## Purpose and Scope

Build the Speech to Text Model sheet, the Settings row, the Custom Vocabulary alert flow, and the 3-row onboarding model step from `ui_design.md`. All state comes from `SpeechEngineManager` (`core.speechEngines`); views hold only presentation state. Views follow `ui_design.md` metrics exactly; this doc defines types, view models and logic.

## 1. Shared Pieces (`ModelManagementUI/ModelSheetComponents.swift`)

Extract from `ManageModelsSheet.swift` (no visual change to the LLM sheet):

```swift
struct RecommendedBadge: View      // star.fill + "Recommended", sage capsule
struct DefaultIndicator: View      // checkmark.circle.fill + "Default"
struct WarningChip: View { let text: String }   // exclamationmark.triangle.fill + text, warningChip tokens
```

`ManageModelsSheet` uses them; `ModelBlockedReason.warningText` stays.

## 2. Speech to Text Model Sheet (`ModelManagementUI`)

### 2.1 Row model (pure, testable)

```swift
public struct SpeechEngineSnapshot: Equatable, Sendable {   // built from SpeechEngineManager
    var availability: AppleSpeechAvailability
    var recommended: SpeechEngine
    var target: SpeechEngine
    var apple: EngineDownloadState
    var whisper: EngineDownloadState
    var hasEnoughDiskForWhisper: Bool
    var isAnyDownloadInFlight: Bool
    var isJobInFlight: Bool
    var osMajor: Int
}

struct SpeechEngineRow: Equatable, Identifiable {
    enum Selection: Equatable { case isDefault, choose, none }
    enum Progress: Equatable { case none, determinate(Double), indeterminate, failed(String), insufficientDisk }
    enum Action: Equatable { case download(enabled: Bool), retry, delete(enabled: Bool), none }
    enum Unavailable: Equatable { case requiresOSUpdate, notAvailable }
    struct Trait: Equatable { let text: String; let isPro: Bool; let hasLocalePicker: Bool }

    let engine: SpeechEngine            // id
    let name: String                    // "Apple Speech" | "Whisper"
    let isRecommended: Bool
    let unavailable: Unavailable?       // apple only
    let selection: Selection
    let traits: [Trait]                 // 4, in ui_design order
    let technicalLine: String
    let progress: Progress
    let action: Action
}

enum SpeechEngineRowBuilder {
    static func rows(_ s: SpeechEngineSnapshot) -> [SpeechEngineRow]   // [apple, whisper]
}
```

Builder rules (ui_design §2.2–2.3):
- `isReady`: apple = availability `.available` && `apple == .downloaded`; whisper = `whisper == .downloaded`.
- `selection`: unavailable → `.none`; ready && target → `.isDefault`; ready → `.choose`; else `.none`.
- Apple traits: "5× faster"(pro), ready ? "Built in, no download" : "Built into macOS"(pro), "1 language"(con, `hasLocalePicker = availability == .available`), "No custom vocabulary"(con).
- Whisper traits: "Better with jargon & rare words", "Any of 99 languages", "Custom vocabulary" (pro), "5× slower" (con).
- Technical line: apple "SpeechTranscriber · macOS \(osMajor)" + (not ready ? " · system download" : ""); whisper "Whisper V3 Turbo · 626 MB".
- Progress: `.downloading(f?)` → apple `.determinate(f)` when f != nil else `.indeterminate`; whisper always `.indeterminate`; `.failed(m)` → `.failed(m)`; whisper not downloaded && !hasEnoughDisk → `.insufficientDisk`; else `.none`.
- Action: unavailable → `.none`; downloading → `.none`; failed → `.retry`; apple ready → `.none`; whisper ready → `.delete(enabled: !isJobInFlight)`; not ready → `.download(enabled: !isAnyDownloadInFlight && (engine == .apple || hasEnoughDisk))`.
- Unavailable: `.requiresOSUpdate` → `.requiresOSUpdate`; `.unavailable` → `.notAvailable`.

### 2.2 `SpeechModelSheetViewModel` (`@MainActor @Observable public final class`)

```swift
public init(core: AppCore)

// Reads
var rows: [SpeechEngineRow]                 // SpeechEngineRowBuilder.rows(snapshot)
var localeOptions: [AppleLocaleOption]      // core.speechEngines.appleLocales
var selectedLocale: String                  // core.speechEngines.appleLocale
private(set) var vocabularyStoredOn = false // settings.customVocabularyResolved, loaded in onAppear

// Presentation state
var showLearnMore = false
var showTurnOffVocabulary = false
var showDeleteWhisper = false
private var pendingAppleAction: PendingAppleAction?   // .choose | .download

// Actions
func onAppear() async          // await engines.refresh(); load vocabularyStoredOn
func tapDownload(_ engine: SpeechEngine)
func tapRetry(_ engine: SpeechEngine)      // same as download
func tapChoose(_ engine: SpeechEngine)
func tapDelete()                // showDeleteWhisper = true
func confirmDelete()            // Task { await engines.deleteWhisper() }
func confirmTurnOffVocabulary() // runs pendingAppleAction
func cancelTurnOffVocabulary()
func setLocale(_ id: String)    // Task { await engines.setAppleLocale(id) }
var deleteMessage: String       // base + vocab sentence when vocabularyStoredOn && availability == .available && target == .whisper
var learnMoreMessage: String    // "This Mac is running macOS \(osMajor). …"
```

Vocabulary guard: `tapDownload(.apple)` / `tapChoose(.apple)` → if `core.speechEngines.effectiveCustomVocabulary(storedPreference: vocabularyStoredOn)` → stash `pendingAppleAction`, `showTurnOffVocabulary = true`; else run. (Effective is false when Apple is already the target, so no alert then.) Whisper actions never alert.

### 2.3 `SpeechModelSheet` view

`public struct SpeechModelSheet: View { @Bindable var viewModel: SpeechModelSheetViewModel }`. Layout per ui_design §2; `.task { await viewModel.onAppear() }`. Rows render `SpeechEngineRowView(row:, localeOptions:, selectedLocale:, onDownload:, onRetry:, onChoose:, onDelete:, onLearnMore:, onLocale:)`.
- Trait grid: `LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 7)`.
- Locale picker: `Picker("", selection: Binding(get: selectedLocale, set: setLocale)) { ForEach(localeOptions) { Text($0.displayName).tag($0.id) } }.pickerStyle(.menu).controlSize(.small).labelsHidden().fixedSize()`.
- Unavailable: content `.opacity(0.5)`, footer leading `WarningChip("Requires macOS 26 or later")` + `Button("Learn more…") { onLearnMore() }.buttonStyle(.plain).foregroundStyle(.sage).font(.system(size: 12))`, or `WarningChip("Not available on this Mac")`.
- Alerts (`.alert(title, isPresented:)`):
  - Learn more: "Not Now" (`.cancel`) and "Software Update…" → `openURL(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)` via `@Environment(\.openURL)`.
  - Turn off vocabulary: "Cancel" (`.cancel`) → `cancelTurnOffVocabulary()`; "Turn Off and Switch" → `confirmTurnOffVocabulary()`.
- Delete: `confirmationDialog("Delete Whisper?", …) { Button("Delete", role: .destructive) { confirmDelete() } } message: { Text(viewModel.deleteMessage) }`.

## 3. Settings (`SettingsUI`)

- `SettingsView`: `@State private var showSpeechModels = false`; `speechToTextModelRow` (ui_design §3) between `summaryPromptRow` and `aiLanguageModelRow`; `.sheet(isPresented: $showSpeechModels) { SpeechModelSheet(viewModel: SpeechModelSheetViewModel(core: viewModel.appCore)) }`.
- `SettingsViewModel`: `var speechTargetReady: Bool { core.speechEngines.targetReady }`, `var speechSummaryLabel: String { core.speechEngines.summaryLabel }`; `load()` also awaits `core.speechEngines.refresh()`. On sheet dismiss, `load()` re-reads the vocabulary state (display follows the target).
- Custom Vocabulary section: binding `get: viewModel.customVocabularyDisplayed`, `set: { on in Task { await viewModel.requestCustomVocabularyEnabled(on) } }`; child rows shown when `customVocabularyDisplayed`. Attach `.alert("Requires Whisper Transcription", isPresented: $viewModel.showRequiresWhisperAlert) { Button("Cancel", role: .cancel) {}; Button("Switch to Whisper") { Task { await viewModel.switchToWhisperForVocabulary() } } } message: { Text(viewModel.requiresWhisperAlertMessage) }`. (VM logic: `speech_engine_manager.md` → Custom vocabulary.)

## 4. Onboarding (`OnboardingUI`)

### 4.1 Row state changes (`ModelRowState.swift`)

- `case ready` → `case ready(caption: String?)` (update existing call sites/tests to `.ready(caption: nil)`).
- `transcriptionRowState()` (target = `engines.target`):
  1. `isPreparingModelStep` → `.checking`.
  2. state of target (`engines.apple` or `engines.whisper`):
     - `.downloaded` (and apple available) → `.ready(caption: target == .apple ? "Built in" : nil)`.
     - `.downloading(f)` → apple `.downloading(.determinate(fraction: f))`; whisper `.downloading(.indeterminate(status: "Downloading\u{2026}"))`.
     - `.failed(m)` → `.failed(message: m)`.
     - not downloaded: whisper && `!engines.hasEnoughDiskForWhisper` → `.insufficientDisk`; else `.idle(sizeCaption: target == .apple ? "System download" : "626 MB")`.
- New `speakerIDRowState()`: same mapping on `engines.speakerID`, indeterminate progress, idle caption "~11 MB", no disk row state (50 MB headroom is checked by the engine).
- Language row unchanged.
- Derivations: `transcriptionReady = engines.targetReady`; `transcriptionStarted = ready || target state is .downloading`; `speakerIDReady/Started` likewise; `allModelsStarted = transcriptionStarted && speakerIDStarted && languageStarted` (replaces `bothModelsStarted`); `allModelsReady` (replaces `bothModelsReady`) for the footer caption.

### 4.2 `OnboardingViewModel`

- Remove `downloadStatus`, `isDownloading`, `downloadComplete`, `downloadFailed`, `transcriptionDownloaded`, `requiredDiskSpaceMB`, `checkDiskSpace`, `hasSufficientDisk` (state now lives in the manager) and `startTranscriptionDownload()`.
- Add: `func startTranscriptionDownload() { Task { await core.speechEngines.download(core.speechEngines.target) } }`, `func startSpeakerIDDownload() { Task { await core.speechEngines.downloadSpeakerID() } }`, `var showSpeechSheet = false`, `var transcriptionLineText: String { "Model: \(engines.summaryLabel)" }`, `var languageLineText: String? { guard let name = languageTargetDisplayName else { return nil }; return "Model: \(name)" }`.
- `runModelProbes()`: `await core.modelManager.refresh(); await core.speechEngines.refresh()`.
- `advance()`: if `currentStep == .modelDownload` → `await core.speechEngines.persistTargetIfUnset()` before `proceed()`. `skip()` does not persist.
- `footerButton(.modelDownload)` uses `allModelsStarted`.

### 4.3 Views

- `ModelCard`: rows Transcription (`waveform`, "Transcription", "Turns speech into text."), Speaker ID (`person.2`, "Speaker ID", "Labels who’s speaking."), Language Model (unchanged), with `InsetDivider(leadingInset: 48)` between each.
- Transcription `extraContent`: when state is not `.downloading` → `RecommendationLine(modelName: transcriptionLineText, onChange: { showSpeechSheet = true })`. "Change…" shows on every OS including macOS 15.
- Language Model `extraContent`: when state is not `.downloading` → `RecommendationLine(modelName: languageLineText, onChange: { showVariantSheet = true })`.
- `RecommendationLine`: model name in `.biscottiMono(11.5)`, `.inkSecondary`, tracking ~0.01em; "Change…" link in SF 12.5 semibold, `.inkSecondary` (hover/pressed `.ink`). `FlowLayout(horizontalSpacing: 12)`, top padding 7pt. Model text `.lineLimit(1)` + `.fixedSize()`. `showsSeeAll` parameter removed.
- `DownloadControl` `.ready(caption)`: `GrantedTag("READY")` + optional caption in `.biscottiMono(11)`, `.inkTertiary`.
- `modelDownloadStep`: add `.sheet(isPresented: $viewModel.showSpeechSheet) { SpeechModelSheet(viewModel: SpeechModelSheetViewModel(core: viewModel.appCore)) }` next to the LLM sheet.

## 5. ManualTestApp

`TranscriptionScript` (+ `WiredScripts`): add steps (action ids wired to `Transcriber(.hosted)` with `.apple(locale:)`):

| id | kind | Does / asks |
|---|---|---|
| `tx_apple_status` | action | Prints `AppleSpeechSupport.availability()`, supported locale count, `assetsInstalled(en_US)` |
| `tx_apple_install` | action | `installAssets(locale: "en_US")` with progress output |
| `tx_apple_transcribe` | action | Hosted XPC transcription of the bundled 3-speaker fixture with `.apple(locale: "en_US")`; prints method id, language, segment/speaker counts, first lines |
| `tx_apple_no_prompt` | question | "Did any permission prompt appear during the Apple steps?" (pass = no) |
| `tx_apple_output_ok` | question | "Is the Apple transcript readable with plausible speaker turns?" |

Fixture: `ManualTestApp/project.yml` adds `Packages/Transcription/Tests/TranscriptionTests/Fixtures/mic_fixture.wav` and `system_fixture.wav` as bundle resources **by path** (no copy in the repo); the step loads them with `Bundle.main.url(forResource:withExtension:)`.

Only the two questions and the three actions are recordable; mark all `tx_*` `not-run` per the staleness rule.

## Dependencies

- `ModelManagementUI` gains `TranscriptionService` (for `SpeechEngine`, `EngineDownloadState`, manager) — already transitively available via `AppCore`; add it explicitly to the target.
- `OnboardingUI`, `SettingsUI` use `ModelManagementUI` (already) and `core.speechEngines`.

## Test Plan

| Suite / test | Verifies |
|---|---|
| `SpeechEngineRowBuilderTests` (ModelManagementUITests): each row state in ui_design §6 checklist — unavailable(15)/(26), not ready/downloading(f, nil)/failed/ready × target/not, recommended badge, disk block, download disabled while another download runs, delete disabled during a job, traits/technical line text | §2.1 rules |
| `SpeechModelSheetViewModelTests`: Apple choose/download with vocab on → alert, confirm runs action, cancel doesn't; vocab off or Apple already target → no alert; Whisper actions never alert; delete message variants; learn-more message uses OS major; setLocale forwards | §2.2 |
| `ManageModelsSheet` snapshot-free check: shared components compile + `ManageModelsViewModelTests` unchanged pass | §1 |
| `SettingsSpeechRowTests`: ready → label + Manage; not ready → Download… | §3 |
| `OnboardingModelRowStateTests` (extend): transcription row for each target state incl. "Built in" caption and "System download"/"626 MB" captions; speaker row states; language line without prefix | §4.1 |
| `OnboardingFooterButtonTests` (extend): Continue requires all three started | §4.1 |
| `OnboardingViewModelTests` (extend): Continue persists target when unset; Skip doesn't; See-all link hidden when Apple unavailable | §4.2 |
| `ManualTestKit` script tests: new step ids present; recordable ids exclude instruction steps | §5 |

## 6. Meeting Detail Re-transcribe Submenu (amendment, Phase 6, `MeetingDetailUI`)

Functional spec §12, ui_design §7, architecture A16.

```swift
struct ReTranscribeMenuItem: Equatable, Identifiable {
    let engine: SpeechEngine
    let title: String          // e.g. "Apple Speech (current transcription)", "Whisper (not downloaded)"
    let isEnabled: Bool
    var id: SpeechEngine { engine }
}

enum ReTranscribeMenuBuilder {
    /// Pure. Order: Apple, Whisper. Reason text replaces the current marker when disabled.
    static func items(
        appleAvailability: AppleSpeechAvailability,
        apple: EngineDownloadState,
        whisper: EngineDownloadState,
        currentEngine: SpeechEngine?
    ) -> [ReTranscribeMenuItem]
}
```

`MeetingDetailViewModel` additions:
- `var currentTranscriptEngine: SpeechEngine?` — newest `versions` entry's `methodId` → `TranscriptionMethod(id:).engine`; nil when there are no versions.
- `var reTranscribeMenuItems: [ReTranscribeMenuItem]` — builder over `core.speechEngines` state.
- `func reTranscribe(with engine: SpeechEngine) async` — builds `.apple(locale: core.speechEngines.appleLocale)` or `.whisper()`, calls `core.transcription.reTranscribe(meetingID:config:)`, then `load()` and `core.intelligence.runAutoEnhancements(meetingID:)` (same tail as `reTranscribe()`).
- `reTranscribe()` (no engine) stays for Transcribe now and the post-correction offer.

`MeetingDetailView.overflowMenu`: inside the existing `if viewModel.canReTranscribe`, replace the Re-transcribe `Button` with `Menu { ForEach(viewModel.reTranscribeMenuItems) { Button(item.title) { Task { await viewModel.reTranscribe(with: item.engine) } }.disabled(!item.isEnabled) } } label: { Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath") }`. The menu reads observable manager state, so text is current each time it opens.

| Suite / test | Verifies |
|---|---|
| `ReTranscribeMenuBuilderTests`: every row of the functional spec §12.2 table; current marker on Apple / Whisper / none; reason replaces marker; order Apple then Whisper; macOS 15 → Apple disabled "(requires macOS 26)", Whisper enabled | §12.2 |
| `MeetingDetailReTranscribeEngineTests`: `reTranscribe(with: .apple)` passes apple(saved locale); `.whisper` passes whisper; selection unchanged; `currentTranscriptEngine` from newest version, empty id → whisper, no versions → nil; Transcribe now path passes no override | §12.1, §12.3 |
