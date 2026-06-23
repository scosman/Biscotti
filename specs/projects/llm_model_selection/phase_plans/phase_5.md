---
status: complete
---

# Phase 5: SettingsUI Row + Manage Models Sheet

## Overview

Replace the conditional inline model download row with a permanent "AI Language Model" row and a
new Manage Models sheet. The row shows the active model name + Manage button (or Download... when
none). The sheet lists all catalog models with per-state rendering (Recommended badge,
Download/Delete, Default/"Choose model", warnings, progress, Retry). A new ManageModelsViewModel
owns delete confirmation and action delegation to ModelManager. SettingsViewModel gains
`isModelAvailable`/`activeModelDisplayName` derived properties.

## Steps

1. **Add `activeModelDisplayName` to `SettingsViewModel`.**
   - Computed property: `LLMModelCatalog.model(id: core.modelManager.activeModelID ?? "")?.displayName`.
   - Add `isModelAvailable` computed (already exists as `modelAvailable`; rename for consistency, keep old as alias or replace).

2. **Create `ManageModelsViewModel` (`ManageModelsSheet.swift` or separate file).**
   - `@MainActor @Observable`, holds `core: AppCore`.
   - `var modelChoices: [ModelChoice]` delegates to `core.modelManager.modelChoices()`.
   - Actions: `download(id:)`, `delete(id:)`, `choose(id:)` delegate to `core.modelManager`.
   - Delete confirmation state: `var deleteTarget: ModelChoice?` (triggers `.confirmationDialog`).
   - `confirmDelete()` calls `core.modelManager.deleteModel(id:)` and clears target.
   - `var isDownloading: Bool` — true when any model is `.downloading`.

3. **Create `ManageModelsSheet` view.**
   - Sheet with fixed ~480pt width, title "AI Language Model", subtitle, Done button.
   - Lists `viewModel.modelChoices` as `ModelRowView` instances.
   - `.confirmationDialog` for delete confirmation.

4. **Create `ModelRowView`.**
   - Renders the per-state matrix from `ModelChoice`:
     - Not runnable → greyed, warning "This Mac can't run this model"
     - Runnable, not downloaded, insufficient disk → Download disabled, warning
     - Runnable, not downloaded, enough disk → Download button
     - Downloading → Progress (determinate/indeterminate)
     - Failed → Error + Retry
     - Downloaded, not selected → Delete + "Choose model"
     - Downloaded, selected → Delete + Default indicator
   - Recommended badge (sage capsule).

5. **Replace `modelDownloadRow` with `aiLanguageModelRow` in `SettingsView`.**
   - Remove the `if !viewModel.modelAvailable { modelDownloadRow }` block.
   - Remove the `modelDownloadRow` computed property.
   - Add permanent `aiLanguageModelRow`:
     - Title "AI Language Model", subtitle "The AI model used to summarize meetings"
     - Trailing: active model name (grey) + Manage button, or Download... button
   - Add `@State private var showManageModels = false` and `.sheet` presentation.
   - Toggle keeps `.disabled(!viewModel.modelAvailable)`.

6. **Clean up `SettingsViewModel`.**
   - Remove `modelDownload` (no longer used by the view; download state lives in the sheet).
   - Keep `modelAvailable` / add `activeModelDisplayName`.
   - Keep `startModelDownload()` (used by the Download... button in the settings row, which opens the sheet — actually the Download... button just opens the sheet; remove `startModelDownload` if unused).

## Tests

- `ManageModelsViewModelTests`:
  - `modelChoices delegates to ModelManager`: verify pass-through.
  - `download delegates to ModelManager`: verify id forwarded.
  - `delete sets deleteTarget and confirmDelete calls ModelManager`: verify two-step flow.
  - `choose delegates to ModelManager`: verify id forwarded.
  - `isDownloading reflects ModelManager state`: true when any download in progress.
- `SettingsViewModelTests` (additions):
  - `activeModelDisplayName returns display name when model active`.
  - `activeModelDisplayName returns nil when no model active`.
  - `modelAvailable reflects ModelManager state`.
