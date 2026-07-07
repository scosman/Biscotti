---
status: complete
---

# Phase 1: Data + generation wiring (headless)

## Overview

Persist and thread the editable summary prompt end-to-end so the instruction
sent to the LLM for summaries becomes a parameter instead of a hard-coded
constant. The default must remain byte-identical so existing behavior is
unchanged.

## Steps

1. **`AppSettings.summaryPrompt`** -- add `public var summaryPrompt: String = ""`
   stored property and matching `init` parameter (default `""`).
   File: `DataStore/Models/AppSettings.swift`

2. **`AppSettingsData.summaryPrompt`** -- add `public var summaryPrompt: String`
   property; populate it in `settings()` and wire it through `updateSettings(_:)`.
   Files: `DataStore/DataStore+ReadModels.swift`

3. **`applyGeneratedSummary(_:for:markEdited:)`** -- add `markEdited: Bool = false`
   parameter; use it instead of hard-coded `false`.
   File: `DataStore/DataStore+LLMFeatures.swift`

4. **`IntelligencePrompts.defaultSummaryPrompt`** -- expose the canonical default
   as a public static property aliasing `summaryTaskInstructions`.
   File: `Intelligence/IntelligencePrompts.swift`

5. **Parameterize `summaryOnlyFirstUser`** -- add `summaryInstructions` parameter
   (default `defaultSummaryPrompt`); use it instead of `summaryTaskInstructions`.
   File: `Intelligence/IntelligencePrompts.swift`

6. **Thread through `Intelligence`** --
   - `buildFirstUserContent` gains `summaryInstructions:` parameter.
   - `contextBudgetFollowUps` gains `summaryInstructions:` parameter.
   - `MeetingAnalyzer.Context` gains `summaryInstructions: String` and
     `markSummaryEdited: Bool`.
   - `runSummaryTurn` uses `ctx.summaryInstructions` for both branches, and
     passes `ctx.markSummaryEdited` to `applyGeneratedSummary`.
   - `runAnalysisSession` gains `summaryInstructions:` + `markSummaryEdited:`.
   Files: `Intelligence/Intelligence.swift`, `Intelligence/MeetingAnalyzer.swift`

7. **`AISettings.summaryPrompt`** -- add resolved (never-empty) prompt field.
   `AppCore+Live` resolves empty -> `defaultSummaryPrompt`.
   Files: `Intelligence/EnhancementStatus.swift`, `AppCore/AppCore+Live.swift`

8. **`runAutoEnhancements`** -- pass `settings.summaryPrompt` as
   `summaryInstructions`, `markSummaryEdited: false`.
   File: `Intelligence/Intelligence.swift`

9. **`runAnalysis` override args** -- add `summaryPromptOverride: String? = nil`
   and `markResultEdited: Bool = false`; resolve effective prompt.
   File: `Intelligence/Intelligence.swift`

10. **`AppCore` helpers** -- add `defaultSummaryPrompt`, `effectiveSummaryPrompt()`,
    `saveSummaryPrompt(_:)` with clear-to-default rule.
    File: `AppCore/AppCore.swift`

11. **Update existing constructors in tests/fakes** -- `AISettings` gains
    `summaryPrompt:`, `MeetingAnalyzer.Context` gains new fields; update
    `PreviewAppCore`, `CoreFixture`, all test call sites.

## Tests

- **Default-unchanged guarantee**: `defaultSummaryPrompt == summaryTaskInstructions`;
  `summaryOnlyFirstUser` with default arg produces byte-identical output.
- **Parameterized prompt**: `summaryOnlyFirstUser(... summaryInstructions: "custom")`
  embeds `"custom"` instead of the default.
- **Follow-up threading**: summary follow-up user turn uses threaded instruction.
- **`applyGeneratedSummary(markEdited:)`**: `true` sets `editedSummary = true`;
  `false` sets `editedSummary = false`.
- **`AppSettings.summaryPrompt` round-trip**: write custom, read back; empty
  means default.
- **`AppSettingsData` carries summaryPrompt**: verify projection from AppSettings.
- **`runAnalysis(summaryPromptOverride:)`**: override is used for the summary turn.
- **`runAnalysis` no override**: uses `settingsProvider().summaryPrompt`.
- **`markResultEdited` threading**: `true` -> `editedSummary = true` on the meeting.
- **`saveSummaryPrompt` clear-to-default**: saving text == default stores `""`;
  custom text stores the literal.
- **`effectiveSummaryPrompt`**: empty stored -> default; non-empty stored -> literal.
