---
status: complete
---

# Phase 3: Wire Entry Points

## Overview

Wire the SummaryPromptSheet (built in Phase 2) into both host surfaces: Settings (Global mode) and Meeting Detail (Per-meeting mode). Add `SummaryPromptUI` as a dependency of `SettingsUI` and `MeetingDetailUI`. Replace the old regenerate-confirm path with the sheet-based flow. Add view-model wiring tests for the `markEdited` computation across the three cases.

## Steps

1. **Package.swift**: Add `"SummaryPromptUI"` to the `dependencies` arrays of both `SettingsUI` and `MeetingDetailUI` targets.

2. **SettingsViewModel**: Add `showSummaryPrompt: Bool` state property. Add `summaryPromptModel: SummaryPromptModel?` computed/loaded property. Add `saveSummaryPrompt(_ text: String)` async method that calls `core.saveSummaryPrompt(text)` and reloads. Add `loadEffectivePrompt() async -> String` helper that calls `core.effectiveSummaryPrompt()`.

3. **SettingsView**: In `aiEnhancementsSection`, insert a `summaryPromptRow` between the AI Analysis toggle and the `aiLanguageModelRow`. Add `.sheet(isPresented: $viewModel.showSummaryPrompt)` presenting `SummaryPromptSheet` with `.global` mode. Import `SummaryPromptUI`.

4. **MeetingDetailViewModel**: Add `showResummarizeSheet: Bool` state property. Add `summaryPromptModel: SummaryPromptModel?` property. Add `regenerate(withPrompt:alsoSave:)` method implementing the markEdited logic. Replace `generateSummary()`'s current regenerate-confirm path: the overflow Regenerate now sets `showResummarizeSheet = true` and prepares the model. Keep the first-run Generate Summary unchanged. Remove the now-unused `showRegenerateConfirm` property and `confirmRegenerate()` method.

5. **MeetingDetailView**: Import `SummaryPromptUI`. Add `.sheet(isPresented: $viewModel.showResummarizeSheet)` presenting `SummaryPromptSheet` with `.perMeeting` mode. Remove the `.confirmationDialog` for `showRegenerateConfirm`. Update the overflow menu Regenerate button to call the new sheet-based path.

6. **Tests**: Add `SummaryPromptWiringTests` in `MeetingDetailUITests` verifying `regenerate(withPrompt:alsoSave:)` computes `markEdited` correctly across three cases:
   - No edit (prompt == effective global prompt, alsoSave false): `markResultEdited = false`
   - Edited, alsoSave off (prompt != effective, alsoSave false): `markResultEdited = true`
   - Edited, alsoSave on (prompt != effective, alsoSave true): `markResultEdited = false`

## Tests

- `regenerateWithDefaultPromptMarksEditedFalse`: prompt == effective, alsoSave false -> markResultEdited = false
- `regenerateWithCustomPromptNoSaveMarksEditedTrue`: prompt != effective, alsoSave false -> markResultEdited = true
- `regenerateWithCustomPromptAndSaveMarksEditedFalse`: prompt != effective, alsoSave true -> markResultEdited = false
