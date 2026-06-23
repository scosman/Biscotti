---
status: complete
---

# Architecture: Onboarding — Download Models (V2)

A contained refactor of the `.modelDownload` step in the `OnboardingUI` module of `BiscottiKit`,
plus a small cleanup that extracts the Manage Models sheet into a shared module. All model logic
(recommendation, download, inventory, suitability, disk) is consumed from the existing
`ModelManager` (Intelligence) and `TranscriptionService` — none of it is reimplemented.

Everything fits in this doc; no separate `/components` designs.

## 1. New shared module + dependency changes (`Packages/BiscottiKit/Package.swift`)

Extract the Manage Models sheet into a new **`ModelManagementUI`** module so both `SettingsUI` and
`OnboardingUI` can present it without a UI→UI sibling edge.

- **New product/target `ModelManagementUI`** — dependencies: `AppCore`, `DesignSystem`,
  `Intelligence`, `.product(name: "LocalLLM", package: "LocalLLM")`. (These are exactly what the
  sheet already imports.) Add the matching `.library(name: "ModelManagementUI", …)` product.
- **New test target `ModelManagementUITests`** — dependencies: `ModelManagementUI`, `AppCore`,
  `BiscottiTestSupport`, `Intelligence`, `LocalLLM` (where the moved `ManageModelsViewModelTests` land).
- **`SettingsUI` target** — add dependency `"ModelManagementUI"`. Keep `Intelligence`/`LocalLLM`
  (still used by `SettingsViewModel`). Its `ManageModelsSheet.swift` file is **moved out** (§2).
- **`OnboardingUI` target** — add dependencies: `"ModelManagementUI"`, `"Intelligence"`,
  `.product(name: "LocalLLM", package: "LocalLLM")`. (Keeps existing: AppCore, Calendar, DataStore,
  DesignSystem, Permissions, TranscriptionService.)
- **`OnboardingUITests` target** — add `"Intelligence"`, `.product(name: "LocalLLM", package:
  "LocalLLM")` so VM/state tests build with the model types. (`ModelManagementUI` only if a test
  constructs the sheet — not needed for the VM/state tests.)
- **App**: no `App/project.yml` change — `ModelManagementUI` is a transitive product via
  `AppShellUI → SettingsUI`/`OnboardingUI`, so SPM links it automatically.

## 2. Extract the sheet (`SettingsUI/ManageModelsSheet.swift` → `ModelManagementUI/`)

- **Move** `ManageModelsSheet.swift` to `Sources/ModelManagementUI/ManageModelsSheet.swift`. It
  contains `ManageModelsViewModel` (already `public`), `ManageModelsSheet`, `ModelRowView`, and the
  `ModelBlockedReason.warningText` extension. Imports are unchanged
  (`AppCore`/`DesignSystem`/`Intelligence`/`LocalLLM`/`SwiftUI`).
- Make `ManageModelsSheet` `public` with a `public init` (it's now consumed cross-module).
  `ModelRowView` and the `warningText` extension stay internal to `ModelManagementUI`.
- **Move** the test file `Tests/SettingsUITests/ManageModelsViewModelTests.swift` →
  `Tests/ModelManagementUITests/ManageModelsViewModelTests.swift` (imports already are AppCore /
  BiscottiTestSupport / Intelligence / LocalLLM — add `import ModelManagementUI`).
- **`SettingsUI/SettingsView.swift`** — `import ModelManagementUI` (still builds the sheet exactly as
  today). `SettingsViewModel.swift` only references the sheet in a comment — no code change.
- No behavior change anywhere; Settings presents the identical sheet.

## 3. Scaffold width (`OnboardingUI/OnboardingScaffold.swift`, `OnboardingView.swift`)

- `OnboardingScaffold` gains `var contentMaxWidth: CGFloat = 520` and applies
  `.frame(maxWidth: contentMaxWidth)` instead of the hard-coded 520.
- `OnboardingView` passes `contentMaxWidth: viewModel.currentStep == .modelDownload ? 560 : 520`.
- All other steps are visually unchanged (still 520).

## 4. `OnboardingViewModel` changes (`OnboardingUI/OnboardingViewModel.swift`)

New imports: `Intelligence`, `LocalLLM`.

### 4.1 AppCore exposure (for the sheet)
- Add `public var appCore: AppCore { core }` (read-only), mirroring `SettingsViewModel.appCore`, so
  the view can build `ManageModelsViewModel(core: viewModel.appCore)`.

### 4.2 Sheet presentation state
- `public var showVariantSheet: Bool = false`.

### 4.3 Transcription row (extend existing fields; no new subsystem)
- Keep existing `isDownloading`, `downloadStatus`, `downloadComplete`, `hasSufficientDisk`.
- Add `public private(set) var transcriptionDownloaded: Bool = false` — set from the on-entry probe.
- Rename `startDownload()` → `startTranscriptionDownload()` (update call sites + tests).
- `var transcriptionReady: Bool { transcriptionDownloaded || downloadComplete }`.
- Disk: retarget the existing check to the transcription class size. Keep
  `requiredDiskSpaceMB` (≈1500 for ~1.5 GB; pick the value already used, currently 2000 — confirm or
  set to 1500) and expose `var transcriptionInsufficientDisk: Bool { !hasSufficientDisk }`.

### 4.4 Language row (derived entirely from `core.modelManager`)
- `var languageTargetModelID: String? { core.modelManager.activeModelID ?? core.modelManager.recommendedModelID() }`
  — what the easy-path Download pulls and what the idle row describes.
- `var recommendedLanguageDisplayName: String?` — `LLMModelCatalog.model(id: recommendedModelID())?.displayName`.
- `var languageReady: Bool { core.modelManager.isModelAvailable }`.
- `func startLanguageDownload() { Task { await core.modelManager.downloadModel(id: targetID) } }`
  (guarded by `languageTargetModelID`; `downloadModel` itself enforces runnable/disk/one-at-a-time).
- The in-flight LLM download + per-variant disk/blocked come from `core.modelManager.downloads` and
  `core.modelManager.modelChoices()` (look up the target id's `ModelChoice`).

### 4.5 Row-state computation (the unit-test surface)
Define an internal enum in `OnboardingUI` used by both rows:

```swift
enum RowDownloadProgress: Equatable {
    case indeterminate(status: String?)   // transcription
    case determinate(fraction: Double?)   // language (nil → spinner fallback)
}
enum ModelRowState: Equatable {
    case idle(sizeCaption: String)
    case insufficientDisk
    case downloading(RowDownloadProgress)
    case ready
    case failed(message: String)
}
```

VM provides two computed mappers (pure functions of observable state, so SwiftUI re-renders when
`downloads`/status change):
- `func transcriptionRowState() -> ModelRowState`
  - ready if `transcriptionReady`; else insufficientDisk if `transcriptionInsufficientDisk`;
    else downloading(`.indeterminate(status: downloadStatus)`) if `isDownloading`;
    else failed if a transcription failure flag is set; else `.idle(sizeCaption: "~1.5 GB")`.
- `func languageRowState() -> ModelRowState`
  - Let `choice = modelChoices().first(where: { $0.id == languageTargetModelID })`.
  - ready if `languageReady`; else if `downloads[targetID]` is `.downloading(f)` →
    `.downloading(.determinate(fraction: f))`; else if `.failed(m)` → `.failed(m)`;
    else if `choice?.blockedReason == .insufficientDisk` → `.insufficientDisk`;
    else `.idle(sizeCaption: sizeString(choice.model.approxDownloadBytes))`.

### 4.6 Footer & readiness
- `var bothModelsReady: Bool { transcriptionReady && languageReady }`.
- `footerButton(for: .modelDownload)` → `bothModelsReady ? .continueButton : .skip`
  (replaces the `downloadComplete ?` check).

### 4.7 On-entry preparation
- Add `private func prepareModelStep() async`:
  - `await core.modelManager.refresh()` (idempotent; reflects on-disk truth).
  - `transcriptionDownloaded = await core.transcription.modelsReady()`.
  - `checkDiskSpace()`.
- In `proceed()`, replace the two `checkDiskSpace()` calls (before entering `.modelDownload`) with
  `await prepareModelStep()`.
- `resetForReplay()` resets the new fields (`transcriptionDownloaded = false`, `showVariantSheet = false`).

## 5. View changes (`OnboardingUI`)

### 5.1 `OnboardingStepViews.swift` — rewrite `modelDownloadStep`
- Title unchanged; lead → "One-time download. AI runs locally — nothing leaves your Mac."
- Body → the new `ModelCard` (below) instead of `downloadContent`.
- Footer → existing `footerButton` (now driven by `bothModelsReady`).
- `import ModelManagementUI`; `.sheet(isPresented: $viewModel.showVariantSheet) { ManageModelsSheet(viewModel: ManageModelsViewModel(core: viewModel.appCore)) }`.
- Remove the old `downloadContent` (single Download Now button / COMPLETE tag).

### 5.2 New view(s), in a new file `OnboardingUI/ModelDownloadCard.swift`
(The `RowDownloadProgress`/`ModelRowState` enums are VM output — define them alongside the view model
in the VM-logic phase, e.g. a small `ModelRowState.swift`; these views consume them.)
- `ModelCard` — `VStack(spacing: 0)` of the two rows + `InsetDivider(leadingInset: 48)`, `.homeCard()`,
  `.frame(maxWidth: 560)`. (Chrome identical to `permissionCard`.)
- `ModelDownloadRow` — icon tile (same metrics as `PermissionRow`) + name + why + optional
  recommendation line (language only) + trailing `DownloadControl`. Top-aligned (`.top`). Either a
  small purpose-built view or `PermissionRow` reuse if its generics fit the third line — prefer the
  least code; keep metrics identical.
- `DownloadControl` — switches on `ModelRowState`:
  - `.idle(caption)` → `DownloadPill` + caption (`.biscottiMono(11)`, `.inkTertiary`).
  - `.downloading(.indeterminate(status))` → reuse today's 240×3 sliding sage bar + status text.
  - `.downloading(.determinate(fraction))` → determinate sage capsule bar (fraction) + "Downloading… NN%";
    nil fraction → indeterminate bar + "Downloading…".
  - `.ready` → `GrantedTag("READY")`.
  - `.insufficientDisk` → warning ("Insufficient free space on disk"), no pill.
  - `.failed(message)` → error text + Retry (calls the row's onDownload).
- `RecommendationLine` — grey "Recommended · \(name)" + plain "See all options ›"
  (`chevron.right`) → sets `showVariantSheet = true`. No icon.

### 5.3 Generalize `GrantPill` (`OnboardingUI/PermissionRow.swift`)
- Change `GrantPill` to accept a title + optional leading SF Symbol, defaulting to the current
  behavior so existing call sites (`GrantPill { ... }`) keep compiling:
  ```swift
  struct GrantPill: View {
      var title: String = "Grant"
      var systemImage: String? = nil
      let action: () -> Void
      // Button { action() } label: { HStack { optional Image; Text(title) } }.buttonStyle(JoinRecordButtonStyle())
  }
  ```
  The download pill uses `GrantPill(title: "Download", systemImage: "arrow.down.circle") { ... }`.
  (`GrantedTag` already supports a custom label — pass "READY".)

## 6. Reuse map (what is consumed, not built)

| Need | Source (existing) |
|---|---|
| Recommended variant id / display name | `ModelManager.recommendedModelID()`, `LLMModelCatalog.model(id:)` |
| Active/selected language model | `ModelManager.activeModelID`, `isModelAvailable` |
| Start/track LLM download | `ModelManager.downloadModel(id:)`, `downloads[id]` (`ModelDownloadState`) |
| Per-variant disk/runnable/blocked | `ModelManager.modelChoices()` → `ModelChoice.blockedReason` |
| Variant sheet ("See all options") | `ModelManagementUI.ManageModelsSheet` + `ManageModelsViewModel` (extracted, made public) |
| Transcription download/status | `TranscriptionService.ensureModelsReady(status:)` |
| Transcription readiness probe | `TranscriptionService.modelsReady()` |
| Card chrome / divider | `DesignSystem` `.homeCard()`, `InsetDivider` |
| Icon tile metrics | copy from `PermissionRow` |
| Pills / tags / bars | `GrantPill` (generalized), `GrantedTag("READY")`, existing sage bar idiom |

## 7. Testing

`OnboardingUITests` (uses `BiscottiTestSupport` fakes for `AppCore`/`ModelManager`/transcription):
- **Row-state mapping** — table-driven over inputs (transcription downloaded/ downloading/ disk;
  language: not-downloaded/ downloading(fraction)/ downloaded/ blocked-disk/ failed; low-RAM forcing
  E2B target) → expected `transcriptionRowState()` / `languageRowState()`.
- **Footer** — `bothModelsReady` / `footerButton(.modelDownload)` across the matrix
  (neither ready → skip; one ready → skip; both ready → continue).
- **Target model** — `languageTargetModelID` = recommended when nothing downloaded; = active when a
  model is downloaded/selected.
- **On-entry prepare** — entering `.modelDownload` sets `transcriptionDownloaded` from the
  transcription fake and refreshes `ModelManager` (downloaded fake → row ready, footer continue).
- **Skip/advance** — both advance to `.done` regardless of readiness.
- Existing onboarding tests updated for the `startDownload` → `startTranscriptionDownload` rename and
  the footer rule change.

Build/lint via `hooks-mcp` (`build`, `test`, `lint`); never raw `swift`/`xcodebuild` in-sandbox.

## 8. File-by-file change list

**Add (extraction — §1/§2)**
- `Packages/BiscottiKit/Sources/ModelManagementUI/ManageModelsSheet.swift` — **moved** from SettingsUI;
  `ManageModelsSheet` made `public` (+ `public init`).
- `Packages/BiscottiKit/Tests/ModelManagementUITests/ManageModelsViewModelTests.swift` — **moved** from
  `SettingsUITests` (+ `import ModelManagementUI`).

**Modify**
- `Packages/BiscottiKit/Package.swift` — new `ModelManagementUI` library product + target and
  `ModelManagementUITests` target; `SettingsUI` += `ModelManagementUI`; `OnboardingUI` +=
  `ModelManagementUI`, `Intelligence`, `LocalLLM`; `OnboardingUITests` += `Intelligence`, `LocalLLM`.
- `Packages/BiscottiKit/Sources/SettingsUI/SettingsView.swift` — `import ModelManagementUI`.
- `Packages/BiscottiKit/Sources/OnboardingUI/OnboardingScaffold.swift` — add `contentMaxWidth` param.
- `Packages/BiscottiKit/Sources/OnboardingUI/OnboardingView.swift` — pass 560 for `.modelDownload`.
- `Packages/BiscottiKit/Sources/OnboardingUI/OnboardingViewModel.swift` — §4 (state, computed,
  prepare, footer, rename).
- `Packages/BiscottiKit/Sources/OnboardingUI/OnboardingStepViews.swift` — rewrite `modelDownloadStep`,
  attach the sheet, remove old `downloadContent`.
- `Packages/BiscottiKit/Sources/OnboardingUI/PermissionRow.swift` — generalize `GrantPill`.

**Add**
- `Packages/BiscottiKit/Sources/OnboardingUI/ModelRowState.swift` — `RowDownloadProgress` /
  `ModelRowState` enums (VM-logic phase).
- `Packages/BiscottiKit/Sources/OnboardingUI/ModelDownloadCard.swift` — `ModelCard`,
  `ModelDownloadRow`, `DownloadControl`, `RecommendationLine` (screen-rewrite phase).
- `Packages/BiscottiKit/Tests/OnboardingUITests/…` — row-state/footer/target/prepare tests
  (new file or extend existing).

**No change** (consumed as-is): `Intelligence/ModelManager.swift`, `ModelSuitability`, `ModelPolicy`,
`LocalLLM/*`, `TranscriptionService` (beyond using `ensureModelsReady`/`modelsReady`), the Settings
AI row.

## 9. Risks / notes

- **Layering**: the extraction yields a clean DAG — `ModelManagementUI` is a shared leaf UI module;
  `SettingsUI` and `OnboardingUI` both depend on it (no UI→UI sibling edge). If the repo's top-level
  `architecture.md` documents the module DAG, add `ModelManagementUI` there during/after the build.
- **Observation**: row-state mappers read `core.modelManager.downloads` etc.; since both view models
  are `@Observable`, SwiftUI tracks those reads and re-renders on download progress. Verify the
  language bar animates during a real download in the manual pass.
- **Disk constant**: confirm the transcription disk requirement (the current `requiredDiskSpaceMB =
  2000` vs the ~1.5 GB copy). Align the gate with the copy.
- **No manual-test staleness impact**: this project touches `Packages/BiscottiKit` UI only — not
  `Packages/Transcription`, `Packages/AudioCapture`, or `Packages/LocalLLM` — so the
  `manual_test_results.json` gate is unaffected. (On-hardware verification of the screen is still
  worthwhile but not gated.)
