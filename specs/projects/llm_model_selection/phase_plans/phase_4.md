---
status: complete
---

# Phase 4: ModelManager + Integration (Breaking Core)

## Overview

This phase replaces the single-model assumption in the app layer. It reworks
`ModelProviding` to a multi-model protocol with `LiveModelProvider`, introduces
`ModelManager` as the central owner of model state (selection, downloads,
suitability), adds an explicit `model: URL` parameter to `LLMRunning.withSession`,
rewires `Intelligence` to delegate all model concerns to `ModelManager`, and wires
`ModelManager` into `AppCore`. All existing users (12B already downloaded) are
seamlessly migrated via the write-back in `ModelManager.refresh()`.

## Steps

### 1. Rework `ModelProviding` to multi-model protocol

File: `Packages/BiscottiKit/Sources/Intelligence/ModelProviding.swift`

Replace the single-model protocol with:
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

### 2. Rework `LiveModelProvider` to implement multi-model protocol

File: `Packages/BiscottiKit/Sources/Intelligence/LiveModelProvider.swift`

Wrap `LLMModelCatalog.all` + `ModelInventory` + `ModelDownloader` (all sharing
`LocalLLMPaths.defaultModelCacheDir`).

### 3. Add `model: URL` to `LLMRunning.withSession`

File: `Packages/BiscottiKit/Sources/Intelligence/LLMRunning.swift`

Add explicit `model: URL` parameter so the runner is told which GGUF to load.

### 4. Drop `modelProvider` from `LiveLLMRunner`

File: `Packages/BiscottiKit/Sources/Intelligence/LiveLLMRunning.swift`

`init()` takes nothing; `withSession` forwards the new `model` param to
`LLMService.withConnection(model:)`.

### 5. Create `ModelManager`

File: `Packages/BiscottiKit/Sources/Intelligence/ModelManager.swift` (new)

`@MainActor @Observable` class with:
- `downloads: [String: ModelDownloadState]`, `selectedModelID: String`
- Dependencies: `DataStore`, `ModelProviding`, `HardwareProbing`
- Reads: `isModelAvailable`, `activeModelID`, `activeModelURL()`, `modelChoices()`
- Actions: `refresh()`, `downloadModel(id:)`, `deleteModel(id:)`, `selectModel(id:)`
- `LastFraction` moved from Intelligence

Also defines `ModelChoice` and `ModelBlockedReason`.

### 6. Rewire `Intelligence`

File: `Packages/BiscottiKit/Sources/Intelligence/Intelligence.swift`

- Drop `models: any ModelProviding` and `download: ModelDownloadState` members.
- Add `modelManager: ModelManager` dependency.
- Replace `models.isDownloaded()` guards with `modelManager.activeModelURL()`.
- Pass the model URL into `llm.withSession(model:url, ...)`.
- Remove `isModelDownloaded`, `refreshModelState()`, `downloadModel()`, `LastFraction`.

### 7. Wire `ModelManager` into `AppCore`

Files: `AppCore.swift`, `AppCore+Live.swift`

- Add `public let modelManager: ModelManager` to `AppCore`.
- `buildIntelligence` -> `buildModelAndIntelligence`: construct `LiveModelProvider`,
  `LiveHardwareProbe`, `ModelManager`, `LiveLLMRunner` (no args), `Intelligence`.
- `onLaunch()` triggers `modelManager.refresh()`.

### 8. Update `PreviewAppCore`

File: `PreviewAppCore.swift`

Construct a `ModelManager` with in-memory fakes. Update preview fakes to the new
`ModelProviding`/`LLMRunning` signatures.

### 9. Update `SettingsViewModel` bridging

File: `SettingsViewModel.swift`

- `modelDownload` -> reads from `core.modelManager.downloads` (pick active model's state).
- `modelAvailable` -> `core.modelManager.isModelAvailable`.
- `load()` calls `core.modelManager.refresh()` instead of `refreshModelState()`.
- `startModelDownload()` -> delegates to `core.modelManager`.

### 10. Update `BiscottiTestSupport` fakes

File: `CoreFixture.swift`

- Update `FakeCoreModelProvider` to implement the new multi-model `ModelProviding`.
- Update `FakeCoreLLMRunner` to accept the new `model: URL` signature.
- Construct a `ModelManager` with fakes and pass it to `AppCore` + `Intelligence`.

### 11. Update `SettingsView` (minimal)

File: `SettingsView.swift`

Update `modelDownloadRow` to use the new ViewModel accessors. No sheet yet (Phase 5).

## Tests

### Intelligence tests (ModelManager)
- `testActiveModelResolutionMigration`: empty selection + 12B downloaded -> active = 12B, selectedModelID persisted
- `testAutoSelectOnFirstDownload`: download E2B when no selection -> auto-selects E2B
- `testDeleteSelectedFallsBack`: delete selected with another downloaded -> falls back
- `testDeleteLastClearsSelection`: delete only downloaded model -> isModelAvailable = false
- `testSelectModelGuard`: select non-runnable/non-downloaded -> no-op
- `testOneDownloadAtATime`: second download while one in flight -> no-op
- `testModelChoicesMatrix`: correct blockedReason/flags across RAM/disk/downloaded/selected combos
- `testIntelligencePassesActiveURL`: active model URL is passed to withSession
- `testIntelligenceNoOpsWhenNoModel`: no active model -> no session opened

### Updated existing tests
- All `FakeLLMRunner`/`FakeModelProvider` updated to new signatures
- All `Intelligence` orchestration tests updated for `modelManager` injection
- `SettingsAIEnhancementsTests` updated for `ModelManager`-based API
- `CoreFixture` updated for `ModelManager` construction
