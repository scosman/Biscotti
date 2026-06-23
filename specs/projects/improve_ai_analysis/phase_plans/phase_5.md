---
status: complete
---

# Phase 5: Title Generation

## Overview

Adds a third turn (title) to the analysis conversation, gated to run only when
the meeting still has the default "Untitled Meeting" title and the user has not
renamed it. No LocalLLM changes -- entirely BiscottiKit (DataStore + Intelligence
+ UI).

## Steps

### DataStore

1. Add `public static let defaultTitle = "Untitled Meeting"` to the `Meeting` model.
2. Refactor `RecordingController.autoTitle()` to return `Meeting.defaultTitle`.
3. Add `public let editedTitle: Bool` to `MeetingDetailData` (default `false` in
   memberwise init) and map it in `meetingDetail()`.
4. Add `applyGeneratedTitle(_:for:)` to `DataStore+LLMFeatures.swift` with an
   internal gate (title == defaultTitle && !editedTitle), leaving `editedTitle == false`.

### Intelligence -- Prompts

5. Add `titleTaskInstructions` to `IntelligencePrompts` -- concise title, bare
   line output, no quotes/label/punctuation.
6. Add `titleFollowUpUser` (= `titleTaskInstructions`) for the follow-up case.
7. Add `titleOnlyFirstUser(detail:transcriptNamed:)` for the standalone case.

### Intelligence -- MeetingAnalyzer

8. Add `titleOptions = GenerationOptions(maxTokens: 32, temperature: 0.3,
   thinking: .off)`.
9. Add `doTitle: Bool` to `MeetingAnalyzer.Context`.
10. Add `EnhancementStatus.generatingTitle` case.
11. Refactor `run` for uniform message threading: each turn appends its user
    message and assistant reply to `inout messages`. The title turn then
    appends its own follow-up or first-user content, generates (buffered),
    cleans the result, and calls `applyGeneratedTitle`.
12. Implement pure `cleanTitle(_:)` helper: trim, first non-empty line, strip
    `Title:` prefix, strip matching quotes, trim again, cap length, nil if empty.
13. Emit `.generatingTitle` status at the start of the title turn.

### Intelligence -- Orchestration

14. In `Intelligence.runAnalysisSession`, compute `doTitle` from snapshot:
    `detail.title == Meeting.defaultTitle && !detail.editedTitle`.
15. Relax the early-out guard: `guard doSpeakers || doSummary || doTitle`.
16. Thread `doTitle` into `MeetingAnalyzer.Context`.
17. Generalize `ContextSizing.contextSizeForAnalysis`:
    - `followUpUser: String?` -> `followUpUsers: [String]`
    - `assistantReserveTokens` becomes the sum of prior assistant replies still
      in context.
18. Update `buildFirstUserContent` for the title-only first-user path.

### UI

19. Update exhaustive switches over `EnhancementStatus` in
    `MeetingDetailViewModel` (`isEnhancing`, `pipelineStages`) with
    `.generatingTitle` -> "Generating title..." label.
20. Update SettingsUI caption to mention titles.

## Tests

- `testApplyGeneratedTitle_writesWhenDefaultAndNotEdited`: verifies write and
  `editedTitle == false`.
- `testApplyGeneratedTitle_noOpsWhenNonDefault`: no-op when title != default.
- `testApplyGeneratedTitle_noOpsWhenEditedTitle`: no-op when `editedTitle`.
- `testDefaultTitleConstant`: `Meeting.defaultTitle` matches
  `RecordingController.autoTitle()`.
- `testEditedTitleInMeetingDetailData`: `editedTitle` mapped correctly.
- `testTitleOnlyFirstUser`: includes transcript + title instructions.
- `testTitleFollowUpUser`: is just `titleTaskInstructions`.
- `testCleanTitle_*`: quotes, label prefix, multiline, empty, cap.
- `testMeetingAnalyzer_doTitle_withPriorTurns`: follow-up, no second transcript.
- `testMeetingAnalyzer_doTitle_standalone`: first-user path with transcript.
- `testGating_doTitle_defaultAndNotEdited`: true only when conditions met.
- `testGating_doTitle_independentOfForce`: not affected by force.
- `testContextSizing_followUpUsers`: new array + summed reserve math.
- `testPipelineStages_generatingTitle`: stage appears with correct label.
- `testIsEnhancing_includesGeneratingTitle`: isEnhancing = true.
