---
status: complete
---

# Improvement Pass: Summary Prompt Editor

Post-implementation refinement pass on Phases 1-3 of the summary_prompt_editor project.

## Changes

### 1. [P1 BUG] Race when opening prompt sheet from Settings
The `Customize...` button in Settings fires a `Task` that awaits `loadEffectivePrompt()`,
builds the `SummaryPromptModel`, and then sets `showSummaryPrompt = true`. Because the
model and presentation flag are separate `@State` vars, the sheet can present before the
model is populated (the `.sheet` content reads `summaryPromptModel` which may still be nil
on the first open). Fix: ensure the model is fully built before setting the presentation
flag. Also check the per-meeting `presentResummarizeSheet` path for the same race.

### 2. Sheet subtitle font too small
Bump the subtitle font in `SummaryPromptSheet.headerSection` from `Tokens.metadataFont`
to a size 2pt larger.

### 3. Remove the "PROMPT" label
Delete the `promptLabel` view and its reference from the sheet body. The editor card
remains.

### 4. Shorten per-meeting subtitle
Change the per-meeting subtitle to exactly: "Re-summarize this meeting with AI, optionally
changing the prompt."

### 5. Rename "ADD EXAMPLE" to "ADD SECTION"
Update the user-facing label string from "ADD EXAMPLE" to "ADD SECTION".

### 6. Move per-meeting replace warning to top with warning icon
Move the "Regenerating will replace..." text from `perMeetingControls` to directly under
the subtitle in the header. Add the app's standard warning icon
(`exclamationmark.triangle.fill` in `.warningOchre`) to its left, matching the existing
permission-row warning style.

### 7. Align default prompt and section blocks
- Replace `summaryTaskInstructions` with the cleaned default prompt text.
- Differentiate the prompt for `summaryOnlyFirstUser` (no "Next" prefix) vs
  `summaryFollowUpUser` ("Next" prefix).
- Rewrite the five built-in example/section blocks to match the `## Heading` +
  one-line-description format.
- Update tests that assert the old default text.
- Update spec docs to reflect the changes.
