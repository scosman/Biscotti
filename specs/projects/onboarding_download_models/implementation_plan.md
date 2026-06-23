---
status: complete
---

# Implementation Plan: Onboarding — Download Models (V2)

Three phases, each compiling green and reviewable on its own. Details live in `functional_spec.md`,
`ui_design.md`, and `architecture.md` (§8 has the file-by-file list). Decisions D1–D5 are locked in
`functional_spec.md` §9 (D1 asymmetric progress, D2 width 560, D3 extract a shared `ModelManagementUI`
module).

## Phases

- [x] **Phase 1 — Extract `ModelManagementUI` (pure refactor, no behavior change).** Move the Manage
  Models sheet out of `SettingsUI` into a new shared module so both Settings and onboarding can use it.
  - `Package.swift`: add the `ModelManagementUI` library product + target (deps `AppCore`,
    `DesignSystem`, `Intelligence`, `LocalLLM`) and a `ModelManagementUITests` target (deps
    `ModelManagementUI`, `AppCore`, `BiscottiTestSupport`, `Intelligence`, `LocalLLM`); add
    `ModelManagementUI` to `SettingsUI`'s deps.
  - Move `Sources/SettingsUI/ManageModelsSheet.swift` → `Sources/ModelManagementUI/ManageModelsSheet.swift`;
    make `ManageModelsSheet` `public` (+ `public init`). `ManageModelsViewModel` already public;
    `ModelRowView` + `warningText` stay internal.
  - Move `Tests/SettingsUITests/ManageModelsViewModelTests.swift` →
    `Tests/ModelManagementUITests/ManageModelsViewModelTests.swift` (+ `import ModelManagementUI`).
  - `SettingsUI/SettingsView.swift`: `import ModelManagementUI` (no other change; identical sheet).
  - *Green via `hooks-mcp` build + test + lint.* Settings behavior is unchanged — this CR is just the
    move. If the repo's top-level `architecture.md` documents the module DAG, add `ModelManagementUI`.

- [x] **Phase 2 — OnboardingUI view-model logic + reuse seams (no screen rewrite).** Wire the data path
  with the screen still rendering its old body so the package stays green.
  - `Package.swift`: add `ModelManagementUI`, `Intelligence`, `LocalLLM` to `OnboardingUI`; add
    `Intelligence`, `LocalLLM` to `OnboardingUITests`.
  - `OnboardingScaffold.swift`: add `contentMaxWidth` param (default 520; no caller change yet).
  - `PermissionRow.swift`: generalize `GrantPill` to `(title = "Grant", systemImage: String? = nil,
    action)` so existing call sites keep compiling.
  - Add `OnboardingUI/ModelRowState.swift`: `RowDownloadProgress` / `ModelRowState` enums.
  - `OnboardingViewModel.swift` (Arch §4): `appCore` exposure, `showVariantSheet`,
    `transcriptionDownloaded`; rename `startDownload()` → `startTranscriptionDownload()`; add
    `startLanguageDownload()`, `languageTargetModelID`, `recommendedLanguageDisplayName`,
    `languageReady`, `bothModelsReady`; `transcriptionRowState()` / `languageRowState()` mappers;
    change `footerButton(.modelDownload)` to `bothModelsReady`; add `prepareModelStep()` and call it
    from `proceed()` (replacing the `checkDiskSpace()` calls); update `resetForReplay()`; align the
    transcription disk constant with the ~1.5 GB copy.
  - Tests (`OnboardingUITests`, Arch §7): row-state mapping (table-driven), footer matrix, target
    model, on-entry prepare, advance/skip; update existing tests for the `startDownload` rename.
  - *Green via `hooks-mcp` build + test + lint.* (The old `modelDownloadStep` body still renders this
    phase; the new footer rule may transiently sit on "Skip" until Phase 3 wires the language row —
    acceptable at a phase boundary.)

- [x] **Phase 3 — Screen rewrite + sheet wiring.** Replace the step body with the two-row card and
  present the extracted sheet.
  - Add `OnboardingUI/ModelDownloadCard.swift`: `ModelCard` (560-wide, `.homeCard()`, inset divider),
    `ModelDownloadRow` (icon tile + name + why + optional recommendation line, top-aligned),
    `DownloadControl` (switch on `ModelRowState`: idle pill+caption / indeterminate (transcription) /
    determinate %+bar (language) / READY tag / insufficient-disk warning / failed+Retry),
    `RecommendationLine` (grey "Recommended · <model>" + "See all options ›", no icon).
  - Rewrite `modelDownloadStep` (`OnboardingStepViews.swift`): `import ModelManagementUI`, new lead
    copy, render `ModelCard`, keep the shared `footerButton`, attach
    `.sheet(isPresented: $viewModel.showVariantSheet) { ManageModelsSheet(viewModel: ManageModelsViewModel(core: viewModel.appCore)) }`;
    remove the old `downloadContent`.
  - `OnboardingView.swift`: pass `contentMaxWidth: 560` for `.modelDownload` (else 520).
  - Use `GrantPill(title: "Download", systemImage: "arrow.down.circle")` and `GrantedTag("READY")`.
  - Verify: idle→downloading→READY for both rows; concurrent downloads; "See all" opens the sheet and
    choices reflect back; both-ready→Continue; Skip advances; Reduced Motion (no springs/pulsing);
    per-row insufficient-disk warning.
  - *Green via `hooks-mcp` build + test + lint.* On-hardware visual confirmation is worthwhile
    (non-gating; no `manual_test_results.json` impact — see Arch §9).
