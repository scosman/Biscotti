---
status: complete
---

# Phase 2: SummaryPromptUI module + the editor field

## Overview

Build the reusable, callback-driven `SummaryPromptSheet` view and its backing
`SummaryPromptModel` observable, plus the `MarkdownPromptField` engine control
in `MarkdownEditorUI`. No entry points are wired (Phase 3). The module is
tested for pure model logic and includes SwiftUI previews for visual
verification.

## Steps

1. **Add `SummaryPromptUI` target to `Package.swift`.**
   New library product + target (deps: `DesignSystem`, `MarkdownEditorUI`) and
   test target `SummaryPromptUITests`.

2. **`MarkdownPromptField` in `MarkdownEditorUI`.**
   A new public `View` that wraps `NativeTextViewWrapper` with the `.biscotti()`
   theme but `.scrolls` height behavior (bounded, internal scrolling). Uses the
   engine's clear background so host chrome shows through. Accepts `text`
   binding, `documentId`, and optional `monospace` flag.

3. **`SummaryPromptMode` enum + `MeetingReference` struct + `PromptExample`
   struct in `SummaryPromptUI`.**
   - `SummaryPromptMode`: `.global` and `.perMeeting(reference:summaryWasEdited:)`.
   - `MeetingReference`: `Sendable` struct with `title`, `date`, optional
     `duration`.
   - `PromptExample`: `name` and `block`; static list of the five examples from
     functional spec.

4. **`SummaryPromptModel` (`@Observable`) in `SummaryPromptUI`.**
   Public `@MainActor @Observable` class with `workingText`, `initialText`,
   `defaultText`, `mode`, `alsoSaveAsDefault`. Pure helper computed
   properties/methods: `isEmpty`, `hasUnsavedChanges`, `isDefault`,
   `added(_:)`, `append(_:)`, `restoreDefault()`.

5. **`SummaryPromptSheet` View in `SummaryPromptUI`.**
   Per `ui_design.md` layout: header (kicker/serif title/subtitle/meeting
   chip), PROMPT label, `MarkdownPromptField` with field chrome, empty caption,
   ADD EXAMPLE chips in `FlowLayout`, per-meeting toggle + replace warning,
   footer (Restore Default / Cancel / primary), confirmation dialogs.

6. **SwiftUI previews** for `SummaryPromptSheet` (Global + Per-meeting) and
   `MarkdownPromptField`.

7. **Unit tests for `SummaryPromptModel`.**
   Exercise all pure logic: `isEmpty`, `hasUnsavedChanges`, `isDefault`,
   `added`/`append` (no duplicates), `restoreDefault`.

## Tests

- `testIsEmpty_whitespaceOnly`: model with whitespace-only `workingText` reports
  `isEmpty == true`.
- `testIsEmpty_nonEmpty`: model with content reports `isEmpty == false`.
- `testHasUnsavedChanges_modified`: changed `workingText` != `initialText` =>
  `true`.
- `testHasUnsavedChanges_unmodified`: `workingText` == `initialText` => `false`.
- `testIsDefault_matchesTrimmed`: `workingText` matches `defaultText` with
  trailing whitespace => `true`.
- `testIsDefault_different`: custom text => `false`.
- `testAdded_blockPresent`: `added(example)` returns `true` when block is in
  `workingText`.
- `testAdded_blockAbsent`: `added(example)` returns `false` when block is not
  present.
- `testAppend_addsBlock`: `append(example)` appends `\n\n` + block.
- `testAppend_noDuplicate`: second `append` of same example is a no-op.
- `testRestoreDefault`: `restoreDefault()` sets `workingText` to `defaultText`.
