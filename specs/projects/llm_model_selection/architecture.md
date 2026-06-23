---
status: complete
---

# Architecture: LLM Model Selection

## 0. Strategy & Layering

The `LocalLLM` package is **already multi-model-capable** below the app: `LLMService.withConnection(model: URL)`,
`LLMLoadRequest(modelPath:)`, the `BiscottiLLM.xpc` service, and `GemmaChatTemplate` all accept an
arbitrary GGUF path, and both Gemma 4 variants share the template. **No XPC or engine changes.** The
single-model assumption lives entirely in four app-layer spots, which this project replaces:

| Layer | Today | After |
|---|---|---|
| `LocalLLM` | one `defaultModelURL` / `modelPath` | a **catalog** of `LLMModel`s + a disk **inventory** (list/path/delete). `defaultModelURL` kept for the CLI. |
| `DataStore` | — | new persisted `selectedModelID` setting |
| `Intelligence` | `Intelligence` owns single `download` state + `ModelProviding.modelURL` | new **`ModelManager`** owns per-model state, selection, suitability; `Intelligence` resolves the **active model** at analysis time |
| `SettingsUI` | conditional inline download row | permanent "AI Language Model" row + **Manage Models sheet** |

**Layering rule:** `LocalLLM` stays free of product policy — it knows *which files exist and how to
fetch/delete them*. **Hardware thresholds, recommendation, disk gating, and UI copy live in the app
layer** (`Intelligence`/`SettingsUI`).

Single architecture doc (no `components/`): the surface is moderate and cohesive.

---

## 1. Data Model

### 1.1 Persisted setting (`DataStore`)

Add one field to the existing settings singleton (mirrors `aiAnalysisEnabled` exactly):

- `AppSettings.selectedModelID: String = ""` (SwiftData `@Model` stored property; plain `String`, no
  `[String]`-materialization issue — lightweight migration adds it with default `""`).
- `AppSettingsData.selectedModelID: String` (the `Sendable` DTO; default `""` in `init`).
- Map it in `DataStore.settings()` (read) and `updateSettings()` (read-into-DTO + write-back).

`""` = "no explicit choice yet" (drives the migration/fallback in §4).

### 1.2 Catalog descriptor (`LocalLLM`)

```swift
public struct LLMModel: Sendable, Equatable, Identifiable {
    public let id: String            // stable, persisted: "gemma-4-12b", "gemma-4-e2b"
    public let displayName: String   // "Gemma 4 12B"
    public let downloadURL: URL
    public let fileName: String      // == downloadURL.lastPathComponent; on-disk name
    public let approxDownloadBytes: Int64  // for the disk gate + delete-confirmation copy
}

public enum LLMModelCatalog {
    public static let all: [LLMModel]            // [12B, E2B] in display order
    public static func model(id: String) -> LLMModel?
}
```

Catalog data:

| id | displayName | downloadURL | fileName | approxDownloadBytes |
|---|---|---|---|---|
| `gemma-4-12b` | Gemma 4 12B | `…/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf` | `gemma-4-12b-it-UD-Q4_K_XL.gguf` | 7 GB |
| `gemma-4-e2b` | Gemma 4 E2B | `…/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` | `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` | 3 GB |

(GB = 1_000_000_000 for the disk gate; exact-byte precision is unnecessary.)

### 1.3 App-layer per-model policy & copy (`Intelligence`)

A small static table keyed by `LLMModel.id` (kept out of `LocalLLM`):

```swift
enum ModelPolicy {
    static func description(id: String) -> String   // UI marketing copy (functional spec §2)
    static func minRAMBytesToRun(id: String) -> UInt64  // 12B: 15 GB; default: 0
    static func approxRAMUsageBytes(id: String) -> Int64 // for copy only (8 GB / 4 GB)
}
```

### 1.4 UI value type (`Intelligence`, consumed by `SettingsUI`)

Assembled per render; not persisted:

```swift
public struct ModelChoice: Sendable, Identifiable, Equatable {
    public let model: LLMModel
    public let description: String
    public let isRecommended: Bool
    public let runnable: Bool                 // canRun (RAM floor met)
    public let hasEnoughDiskToDownload: Bool  // free space >= approxDownloadBytes
    public let isDownloaded: Bool
    public let isSelected: Bool               // == active selection
    public let downloadState: ModelDownloadState
    public var id: String { model.id }
    public var blockedReason: ModelBlockedReason?  // .cannotRun | .insufficientDisk | nil
}

public enum ModelBlockedReason: Sendable, Equatable { case cannotRun, insufficientDisk }
```

The UI maps `ModelChoice` → the row-state matrix (ui_design §2.2): `.cannotRun` → greyed + "This
Mac can't run this model"; `.insufficientDisk` → disabled Download + "Insufficient free space on
disk"; else by `downloadState` + `isSelected`.

---

## 2. Component Breakdown

### 2.1 `LocalLLM` — `ModelInventory` (new, in-process; the "list downloaded models" API)

Disk-facing companion to `ModelDownloader` (which already does network + arbitrary-URL download).
No XPC.

```swift
public struct ModelInventory: Sendable {
    public init(cacheDirectory: URL)                       // LocalLLMPaths.defaultModelCacheDir
    public func path(for model: LLMModel) -> URL           // cacheDirectory + model.fileName
    public func isDownloaded(_ model: LLMModel) -> Bool     // ModelDownloader.fileExistsAndNonEmpty
    public func downloadedModels(in catalog: [LLMModel]) -> [LLMModel]
    public func delete(_ model: LLMModel) throws            // remove file + sibling ".partial"
}
```

- `path(for:)` is consistent with `ModelDownloader.download(from: model.downloadURL)` (both resolve
  `cacheDirectory + fileName`), so a downloaded file is found by both.
- `ModelDownloader` is unchanged except keeping `defaultModelURL`/`modelPath` for the CLI; the app
  calls `download(from: model.downloadURL, progress:)`.

### 2.2 `Intelligence` — `HardwareProbing` (new) + `ModelSuitability` (new, pure)

```swift
public protocol HardwareProbing: Sendable {
    var physicalMemoryBytes: UInt64 { get }                // ProcessInfo.physicalMemory
    func availableDiskBytes(at url: URL) -> Int64?         // volumeAvailableCapacityForImportantUsageKey
}
public struct LiveHardwareProbe: HardwareProbing { /* reads real hardware */ }

enum ModelSuitability {
    static func canRun(_ m: LLMModel, ram: UInt64) -> Bool          // ram >= minRAMBytesToRun(m.id)
    static func hasEnoughDisk(_ m: LLMModel, freeBytes: Int64?) -> Bool  // freeBytes == nil ? true : free >= approxDownloadBytes
    static func recommendedModelID(catalog: [LLMModel], ram: UInt64) -> String?  // §3
}
```

- Pure functions → fully unit-testable with fabricated RAM/disk values. No real hardware in tests.
- `hasEnoughDisk` returns **true when free space is unknown** (`nil`) — never falsely block a
  download on a failed capacity read; the downloader's size validation is the backstop.

### 2.3 `Intelligence` — `ModelManager` (new; `@MainActor @Observable`)

The in-process owner of all model state, **replacing** `Intelligence`'s current `download`,
`downloadModel`, `refreshModelState`, `isModelDownloaded`, and the `ModelProviding.modelURL`
single-model coupling. Observed by Settings (parallels how `Intelligence.download` is observed
today).

```swift
@MainActor @Observable
public final class ModelManager {
    // Observable state
    public package(set) var downloads: [String: ModelDownloadState] = [:]  // per model id
    public private(set) var selectedModelID: String = ""                   // cached mirror of the setting

    // Dependencies (injected; fakes in tests)
    private let store: DataStore
    private let models: any ModelProviding     // LocalLLM-backed: catalog + inventory + downloader
    private let hardware: any HardwareProbing

    public init(store: DataStore, models: any ModelProviding, hardware: any HardwareProbing)

    // Reads / derived
    public var isModelAvailable: Bool          // activeModelID != nil
    public var activeModelID: String?          // §4.2 resolution against `downloads` + `selectedModelID`
    public func activeModelURL() -> URL?       // models.url(for: activeModelID) when downloaded
    public func modelChoices() -> [ModelChoice]  // assemble catalog × downloads × selection × suitability

    // Lifecycle / actions
    public func refresh() async                // recompute downloads from disk; load + (migration) persist selection
    public func downloadModel(id: String) async   // one-at-a-time guard; drives downloads[id]
    public func deleteModel(id: String) async     // inventory.delete; recompute selection (§4.3)
    public func selectModel(id: String) async     // guard runnable+downloaded; persist selectedModelID
}
```

`ModelProviding` (the injected abstraction) is **reworked** from single- to multi-model:

```swift
public protocol ModelProviding: Sendable {
    var catalog: [LLMModel] { get }
    func url(for id: String) -> URL?
    func isDownloaded(_ id: String) -> Bool
    func downloadedModelIDs() -> [String]
    func download(_ id: String, progress: @Sendable @escaping (Int64, Int64?) -> Void) async throws
    func delete(_ id: String) throws
}
```

`LiveModelProvider` wraps `LLMModelCatalog.all` + `ModelInventory(cacheDirectory:)` + `ModelDownloader(cacheDirectory:)`
(all sharing `LocalLLMPaths.defaultModelCacheDir`). Test fakes implement the protocol in-memory.

### 2.4 `Intelligence` — analysis path (modified)

`Intelligence` drops its `models`/`download` members and instead holds `modelManager: ModelManager`.

- Guards in `runAutoEnhancements` / `runAnalysis`: replace `guard models.isDownloaded()` with
  `guard let modelURL = modelManager.activeModelURL() else { …no-op… }`.
- `runAnalysisSession` passes that URL into the session (see §2.5).
- `isModelDownloaded` → `modelManager.isModelAvailable` (used by the toggle gate).

### 2.5 `Intelligence` — `LLMRunning.withSession` gains an explicit model (modified)

So the runner is told *which* GGUF to load (it no longer owns a `ModelProviding`):

```swift
public protocol LLMRunning: Sendable {
    func withSession<T: Sendable>(
        model: URL,
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T
}
```

- `LiveLLMRunner`: drop `modelProvider`; `init()` takes nothing; `withSession` forwards `model` to
  `LLMService.withConnection(model:)`.
- `Intelligence.runAnalysisSession`: `try await llm.withSession(model: modelURL, config: .modelOnly) { … }`.
- All `LLMRunning` fakes in tests update to the new signature (they can ignore `model`).

### 2.6 `SettingsUI` — row + sheet (modified/new)

- **`SettingsView.aiEnhancementsSection`**: remove the conditional `modelDownloadRow`; add a
  permanent `aiLanguageModelRow` and a `.sheet(isPresented: $showManageModels) { ManageModelsSheet(viewModel:) }`.
  The "AI Analysis & Summary" toggle keeps `.disabled(!viewModel.isModelAvailable)`.
- **`aiLanguageModelRow`** (ui_design §1): title "AI Language Model" + subtitle; trailing = active
  model display name (secondary text) + `Manage`, or `Download…` when none.
- **`ManageModelsSheet`** (new view) + **`ModelRowView`** (new subview): render
  `viewModel.modelChoices` per the state matrix; `Done` to dismiss; `.confirmationDialog` for delete.
- **`SettingsViewModel`** (modified):
  - Remove `modelDownload`/`modelAvailable` single-model accessors.
  - Add `isModelAvailable: Bool { core.modelManager.isModelAvailable }`,
    `activeModelDisplayName: String?` (looks up `LLMModelCatalog.model(id:)?.displayName`).
  - `load()` calls `await core.modelManager.refresh()` (replaces `refreshModelState()`).
- **`ManageModelsViewModel`** (new, thin; `@MainActor @Observable`): holds `core`; exposes
  `var modelChoices: [ModelChoice] { core.modelManager.modelChoices() }` and actions
  `download(id:)`/`delete(id:)`/`choose(id:)` delegating to `core.modelManager`; owns the
  delete-confirmation `@State` target. Kept thin for testability/parity with existing VMs.

### 2.7 `AppCore` (modified wiring)

- Add `public let modelManager: ModelManager` to `AppCore` (and its init).
- `buildIntelligence` becomes `buildModelAndIntelligence`: construct `LiveModelProvider()` +
  `LiveHardwareProbe()` → `ModelManager(store:models:hardware:)`; construct `LiveLLMRunner()`;
  `Intelligence(store:, llm:, modelManager:, settings:)`. Return both; assign to `AppCore`.
- `AppCore.onLaunch()` (existing) triggers `Task { await modelManager.refresh() }` so migration
  selection is resolved/persisted at startup.
- `PreviewAppCore`/test factories construct a `ModelManager` with in-memory fakes.

---

## 3. Recommendation & Suitability Logic (the algorithms)

All in `ModelSuitability` (pure), driven by `hardware.physicalMemoryBytes` and
`hardware.availableDiskBytes`:

- **canRun(model):** `ram >= ModelPolicy.minRAMBytesToRun(model.id)`.
  `minRAMBytesToRun`: `gemma-4-12b → 15 GB`, everything else → `0`.
- **recommendedModelID(catalog, ram):** if `ram >= 24 GB` and the catalog contains a runnable
  `gemma-4-12b` → `"gemma-4-12b"`; otherwise the smallest always-runnable model → `"gemma-4-e2b"`.
  (Explicit two-model rule; the documented extension point when models are added. Never returns a
  non-runnable model.)
- **hasEnoughDisk(model, freeBytes):** `freeBytes == nil ? true : freeBytes >= model.approxDownloadBytes`.

Thresholds: `15 GB` and `24 GB` use `1_000_000_000` GB. Centralize as named constants in
`ModelPolicy`/`ModelSuitability`.

---

## 4. Selection, Active Model & Migration (the state machine)

### 4.1 The setting

`selectedModelID` (persisted, §1.1). `ModelManager.selectedModelID` is the cached mirror, loaded in
`refresh()` and updated by `selectModel`. `ModelManager` is `@MainActor` and the **sole writer**, so
the cache is authoritative after first `refresh()`.

### 4.2 Active model resolution (`activeModelID`)

Computed against the current `downloads` (disk truth) + `selectedModelID`:

1. If `selectedModelID` names a **downloaded** catalog model → that id.
2. Else the **first downloaded** model in `LLMModelCatalog.all` order → its id.
3. Else → `nil`.

`activeModelURL()` = `models.url(for: activeModelID)` (the on-disk path) when present.

### 4.3 Transitions

- **`refresh()`** (startup + Settings appear): rebuild `downloads` from `ModelInventory`; load
  `selectedModelID` from settings. **Migration:** if the loaded selection is empty or names a
  non-downloaded model, but step-2 resolves a downloaded model, **persist** that id
  (`store.updateSettings { $0.selectedModelID = id }`) and update the cache. → Existing 12B users
  silently keep 12B; no auto-download ever happens here.
- **`downloadModel(id:)`**: guard `canRun` + `hasEnoughDisk` + **no other download in flight**
  (one-at-a-time, §6). Drive `downloads[id]` through `.downloading(fraction:)` → `.downloaded` /
  `.failed`. **On success**, if the current selection is empty or names a non-downloaded model →
  `selectModel(id:)` (auto-select first/recovered model).
- **`selectModel(id:)`**: guard the model is `canRun` **and** downloaded; persist + cache.
- **`deleteModel(id:)`**: `inventory.delete`; set `downloads[id] = .notDownloaded`. If the deleted id
  was selected → recompute: first remaining downloaded model (catalog order) → `selectModel(that)`;
  if none remain → persist `selectedModelID = ""`.

### 4.4 Analysis-time use

`Intelligence` reads `modelManager.activeModelURL()` (cached, synchronous, `@MainActor`). A switch
takes effect on the **next** run; an in-flight run keeps its already-opened session. No-active-model
→ silent no-op (unchanged behavior).

---

## 5. Error Handling

- **Download failure** → `downloads[id] = .failed(message:)` via the existing
  `shortDescription(error)` helper (`LocalLLMError`/underlying). Row shows error + Retry; no partial
  file remains (existing temp-cleanup). `CancellationError` → `.notDownloaded`.
- **Delete failure** (rare) → log; leave `downloads[id]` as `.downloaded` (the file is still there);
  the row reverts to the downloaded state. Non-fatal.
- **Disk capacity read returns nil** → treated as "enough" (don't false-block); download proceeds and
  is validated by Content-Length.
- **Guarded no-ops**: `selectModel`/`downloadModel` on a non-runnable model do nothing (UI prevents
  reaching them anyway). Defensive only.
- Logging via the existing `os.Logger` conventions where the surrounding code already logs.

---

## 6. Concurrency

- `ModelManager` is `@MainActor`; all mutations of `downloads`/`selectedModelID` are main-actor
  isolated. Progress callbacks marshal to the main actor exactly as `Intelligence.downloadModel`
  does today (the `LastFraction` throttle moves into `ModelManager`).
- **One download at a time:** `downloadModel` returns early if any `downloads.values` is
  `.downloading`. The UI disables other rows' Download buttons while one is in flight.
- The actual network download runs in the `ModelDownloader`/`URLSession` task off the main actor;
  only state updates hop back to `@MainActor`.

---

## 7. Testing Strategy

All via the package test suites (`mcp__hooks-mcp__test`); no heavy/AI tests; no real hardware.

**`LocalLLM` (LocalLLMTests):**
- `LLMModelCatalog`: ids/URLs/filenames are distinct and non-empty; `model(id:)` lookups.
- `ModelInventory`: `path(for:)` derivation; `isDownloaded` true/false against temp files (regular
  file > 0 bytes vs directory vs missing); `downloadedModels(in:)` filtering; `delete` removes the
  file **and** a sibling `.partial`; delete of a missing file does not throw fatally.

**`Intelligence` (BiscottiKit Intelligence tests):**
- `ModelSuitability` (table-driven, pure): `canRun(12B)` at 8/14/15/16/24/64 GB and `canRun(E2B)`
  always true; `recommendedModelID` flips at the 24 GB boundary and never returns a non-runnable id;
  `hasEnoughDisk` boundaries incl. `nil` free → true.
- `ModelManager` (fake `ModelProviding` + fake `HardwareProbing` + in-memory `DataStore`):
  - Active-model resolution & **migration**: empty selection + 12B-only downloaded → active = 12B and
    `selectedModelID` persisted to "gemma-4-12b".
  - First successful download auto-selects when no valid selection.
  - Delete selected with another downloaded present → selection falls back; delete last → cleared
    (`isModelAvailable == false`).
  - `selectModel` on non-runnable/not-downloaded → ignored.
  - One-at-a-time: second `downloadModel` while one is `.downloading` → no-op.
  - `modelChoices()` produces correct `blockedReason`/flags across a RAM/disk/downloaded/selected
    matrix (incl. 12B `.cannotRun` at 8 GB; `.insufficientDisk` when free < size).
- `Intelligence`: updated for `withSession(model:)` + `modelManager` injection; verify the active
  model URL is the one passed to the (fake) runner; no-op when no active model.

**`DataStore`:** settings round-trip persists/reads `selectedModelID`; default is `""`.

**`SettingsUI`:** `SettingsViewModel.activeModelDisplayName`/`isModelAvailable` mapping;
`ManageModelsViewModel` action delegation and `modelChoices` pass-through (with a fake/preview core).

**Manual tests:** this touches `Packages/LocalLLM` → mark existing `llm_*` steps `not-run` in
`ManualTestApp/Results/manual_test_results.json` (recordable steps only) per the repo rule.
**New E2B coverage** in the "Local LLM" tab: a `.action` to download the E2B model, a `.action` to
run the **multi-turn (KV-cache reuse)** inference through `BiscottiLLM.xpc` on E2B (the single most
demanding path — full suite not repeated), and a `.humanQuestion` observation. Add those recordable
IDs to the results JSON as `not-run`; update `ScriptShapeTests` for the new steps. The shape steps
live in `ManualTestKit/Scripts/LocalLLMScript.swift`; wiring (real XPC calls using `LLMModelCatalog`/
`ModelInventory` for the E2B path) in `ManualTestApp/Sources/WiredScripts.swift`.

---

## 8. File-Level Change List

**`Packages/LocalLLM/Sources/LocalLLM/`**
- `LLMModel.swift` (new): `LLMModel` + `LLMModelCatalog`.
- `ModelInventory.swift` (new): path/isDownloaded/downloadedModels/delete.
- `ModelDownloader.swift`: unchanged (keep `defaultModelURL`/`modelPath` for CLI).

**ManualTestApp (Phase 1)**
- `Packages/BiscottiKit/Sources/ManualTestKit/Scripts/LocalLLMScript.swift`: append E2B
  download + multi-turn-inference `.action`s + observation `.humanQuestion`.
- `ManualTestApp/Sources/WiredScripts.swift`: wire the new E2B steps (download via E2B descriptor;
  multi-turn KV-reuse generate using the E2B model URL).
- `ManualTestApp/Results/manual_test_results.json`: add new recordable IDs as `not-run`; mark
  existing `llm_*` recordable steps `not-run`.
- `Packages/BiscottiKit/Tests/ManualTestKitTests/ScriptShapeTests.swift`: update for the new steps.

**`Packages/BiscottiKit/Sources/DataStore/`**
- `Models/AppSettings.swift`: add `selectedModelID` stored prop + init param.
- `DataStore+ReadModels.swift`: add to `AppSettingsData` (+ init), `settings()`, `updateSettings()`.

**`Packages/BiscottiKit/Sources/Intelligence/`**
- `HardwareProbing.swift` (new): protocol + `LiveHardwareProbe`.
- `ModelSuitability.swift` (new): pure logic + `ModelPolicy` (copy/RAM table) + thresholds.
- `ModelManager.swift` (new): `ModelManager`, `ModelChoice`, `ModelBlockedReason`; move
  `LastFraction` here.
- `ModelProviding.swift`: rework to multi-model protocol.
- `LiveModelProvider.swift`: implement multi-model over catalog + inventory + downloader.
- `LLMRunning.swift` + `LiveLLMRunning.swift`: add `model: URL` to `withSession`; drop
  `modelProvider` from `LiveLLMRunner`.
- `Intelligence.swift`: swap `models`/`download` for `modelManager`; update guards + session call;
  remove the model-download methods now owned by `ModelManager`.
- `EnhancementStatus.swift`: `ModelDownloadState` unchanged (reused per-model).

**`Packages/BiscottiKit/Sources/AppCore/AppCore.swift` + `AppCore+Live.swift`**
- Add `modelManager` to `AppCore`; build it in the live factory; `onLaunch` → `refresh()`.

**`Packages/BiscottiKit/Sources/SettingsUI/`**
- `SettingsView.swift`: permanent `aiLanguageModelRow`; remove `modelDownloadRow`; add sheet.
- `SettingsViewModel.swift`: new model accessors; `load()` → `modelManager.refresh()`.
- `ManageModelsSheet.swift` (new) + `ModelRowView` + `ManageModelsViewModel.swift` (new).

**Tests:** add/adjust per §7 across `LocalLLMTests`, `IntelligenceTests`, `DataStoreTests`,
`SettingsUITests`; update existing `LLMRunning` fakes to the new signature; PreviewAppCore builds a
`ModelManager`.

---

## 9. Out of Scope (unchanged from functional spec)

Download resume / checksums / general download manager (Project 10); UI cancel of in-flight
downloads; custom user-supplied model URLs; per-model runtime tuning; transcription-model selection.
