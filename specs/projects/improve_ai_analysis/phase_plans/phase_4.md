---
status: complete
---

# Phase 4: Settings & UI Cleanup

## Overview

Replace the two independent AI-settings booleans (`summarizeTranscripts` + `guessSpeakerNames`)
with a single `aiAnalysisEnabled` flag across all layers: SwiftData model, DTO, DataStore
accessors, AppCore bridge, SettingsUI (single toggle), and MeetingDetailUI (pipeline gating
+ empty-state). Remove the Phase 3 interim bridge in `AppCore+Live`. Update all affected tests.

## Steps

1. **Collapse `AppSettings` SwiftData model.**
   - `Models/AppSettings.swift`: replace `summarizeTranscripts: Bool = true` and
     `guessSpeakerNames: Bool = true` with `aiAnalysisEnabled: Bool = true`. Update `init()`.
   - Lightweight migration: new property has a default; old properties are simply dropped.

2. **Update `AppSettingsData` DTO and DataStore accessors.**
   - `DataStore+ReadModels.swift`: replace two bool properties in the struct, the `init`,
     `settings()` return mapping, and `updateSettings()` read/write with single
     `aiAnalysisEnabled`.

3. **Simplify the AppCore bridge.**
   - `AppCore+Live.swift`: replace the interim
     `AISettings(enabled: (s?.summarizeTranscripts ?? true) || (s?.guessSpeakerNames ?? true))`
     with `AISettings(enabled: settings?.aiAnalysisEnabled ?? true)`.

4. **Update `AISettings` doc comment.**
   - `EnhancementStatus.swift`: remove the "Phase 4 will align" TODO; state that the single
     `enabled` flag maps to `AppSettings.aiAnalysisEnabled`.

5. **SettingsUI: single toggle.**
   - `SettingsViewModel.swift`: replace `summarizeTranscripts`/`guessSpeakerNames` properties
     and their `set*` methods with single `aiAnalysisEnabled` property and
     `setAIAnalysisEnabled(_:)` (same optimistic-update-revert pattern). Update `load()`.
   - `SettingsView.swift`: replace two toggle VStacks with one "AI Analysis & Summary" toggle;
     caption: "Generate a summary from the transcript, and guess the names of speakers from
     context." Replace two bindings with single `aiAnalysisEnabledBinding`.

6. **MeetingDetailUI: single-flag gating.**
   - `MeetingDetailViewModel.swift`: replace `summarizeEnabled`/`guessSpeakersEnabled` with
     `aiAnalysisEnabled`. Both pipeline stages ("Inferring participant names" + "Summarizing")
     gated on `aiAnalysisEnabled && modelAvailable`. Summarizing additionally gated on
     `!editedSummary`. Manual regenerate NOT gated by the toggle (explicit user intent).
   - `MeetingDetailView.swift`: update empty-state summary branch to read `aiAnalysisEnabled`.

7. **Update all tests.**
   - `SettingsAIEnhancementsTests.swift`: rewrite two-toggle test suite into single-toggle
     tests (default+persist, revert-on-failure, load-from-store, model availability,
     no-model binding, download state, toggle interaction with model state).
   - `LLMFeaturesTests.swift`: update `SettingsAIFieldsTests` for `aiAnalysisEnabled` default
     and round-trip.
   - `SummaryTabTests.swift`: update load/empty-state tests for `aiAnalysisEnabled`.
   - `PipelineStatusTests.swift`: replace individual toggle-off tests with single-toggle-off
     test (both stages omitted); add `editedSummary` interaction test; update settings-loading
     tests.

## Tests

- `SettingsAIEnhancementsTests`: 11 tests covering toggle default/persist/revert/load,
  model availability gating, no-model binding safety (stored value not corrupted), download
  state, load refresh, download initiation, toggle + model interaction.
- `SettingsAIFieldsTests`: default `aiAnalysisEnabled == true`; round-trip through
  `updateSettings`.
- `SummaryTabTests`: `loadReadsAIAnalysisEnabled`; empty-state when `aiAnalysisEnabled == false`.
- `PipelineStatusTests`: `aiAnalysisEnabled == false` omits both AI stages;
  `editedSummary + AI on` shows speakers but hides summary; `loadReadsAIAnalysisEnabled`;
  `defaultAIAnalysisEnabledTrue`.
