---
status: in-review
---

# Phase 4: Speech to Text Model Sheet + Settings

## Overview

Build the Speech to Text Model sheet, extract shared components from ManageModelsSheet, add the Settings row and Custom Vocabulary alert flow. All view state derives from SpeechEngineManager (via AppCore). This phase does NOT include onboarding changes (Phase 5).

## Steps

1. **Extract shared components** (`ModelManagementUI/ModelSheetComponents.swift`): `RecommendedBadge`, `DefaultIndicator`, `WarningChip`. Update `ManageModelsSheet` to use them.

2. **Add `TranscriptionService` dependency to `ModelManagementUI`** in `Package.swift` so the module can import `SpeechEngine`, `EngineDownloadState`, `SpeechEngineManager`, etc.

3. **Build `SpeechEngineRowBuilder`** (`ModelManagementUI/SpeechEngineRowBuilder.swift`): pure row model types (`SpeechEngineSnapshot`, `SpeechEngineRow`, `SpeechEngineRowBuilder`) with all builder rules from ui.md section 2.1.

4. **Build `SpeechModelSheetViewModel`** (`ModelManagementUI/SpeechModelSheetViewModel.swift`): `@MainActor @Observable` class with vocabulary guard logic, alert state, locale setter, and all actions per ui.md section 2.2.

5. **Build `SpeechModelSheet` view** (`ModelManagementUI/SpeechModelSheet.swift`): row view, trait grid, locale picker, progress states, unavailable states, alerts (learn more, turn off vocabulary, delete whisper) per ui.md section 2.3.

6. **Add Settings row** (`SettingsView.swift`): `speechToTextModelRow` between `summaryPromptRow` and `aiLanguageModelRow`, with `@State showSpeechModels` and `.sheet` presentation.

7. **Add `speechTargetReady` and `speechSummaryLabel`** to `SettingsViewModel`; refresh `speechEngines` in `load()`.

8. **Update Custom Vocabulary section** (`SettingsVocabularySection.swift`): attach the "Requires Whisper Transcription" alert (already wired in Phase 3 VM code).

## Tests

- `SpeechEngineRowBuilderTests` (ModelManagementUITests): all row state combinations from ui_design section 6 checklist.
- `SpeechModelSheetViewModelTests` (ModelManagementUITests): vocabulary guard alerts, confirm/cancel, delete message variants, learn-more message, setLocale forwarding.
- `ManageModelsViewModelTests`: existing tests still pass (shared components refactor is non-breaking).
- `SettingsSpeechRowTests` (SettingsUITests): ready vs. not-ready label and button.
