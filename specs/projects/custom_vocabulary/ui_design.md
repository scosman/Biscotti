---
status: complete
---

# UI Design: Custom Vocabulary

Three surfaces: a Settings section, a term-editor sheet, and an alert. All follow existing
`DesignSystem` tokens and mirror patterns already in `SettingsUI` and `SummaryPromptUI`.

## 1. Settings section

Placed directly after **AI Enhancements**, before **Calendars**.

```
┌─ AI Enhancements ─────────────────────────────────────────────┐
│ … existing rows …                                               │
└─────────────────────────────────────────────────────────────────┘
┌─ Custom Vocabulary ────────────────────────────────────  Beta ─┐
│ ☐ Custom Vocabulary                                             │
│   Help Biscotti recognize uncommon words you use, like names    │
│   or technical terms.                                           │
│                                                                 │
│ Vocabulary List                              [ Edit List (7) ]  │
│   Words to watch for in every meeting.                          │
│                                                                 │
│ ☑ Add Words from Calendar Events                                │
│   Pull uncommon words from the event's title, description,      │
│   and attendee names. English only.                             │
└─────────────────────────────────────────────────────────────────┘
┌─ Calendars ────────────────────────────────────────────────────┐
```

**Structure.** A `Section` in the existing grouped `Form`, with three rows and a custom `header:`
closure — an `HStack` of the title, a `Spacer`, and a muted `Beta` caption, mirroring the
`AI runs locally on your Mac.` caption on the AI Enhancements header. The master toggle is off by
default while the feature is in beta (see `functional_spec.md` §5.0), so the two rows below it are
hidden until the user opts in.

- **Row 1 — master toggle.** `Toggle` + a `Tokens.metadataFont` / `Tokens.secondaryText` subtitle
  beneath, wrapped in a `VStack(alignment: .leading, spacing: Tokens.spacingXS)`. This is exactly the
  "AI Analysis & Summary" row pattern in `aiEnhancementsSection`.
- **Row 2 — Vocabulary List.** `HStack` of a title/subtitle `VStack`, a `Spacer()`, and a trailing
  `Button("Edit List (N)")` with `.buttonStyle(.bordered)` and `.controlSize(.small)`. This is the
  `summaryPromptRow` pattern. `N` is the stored term count and updates live.
- **Row 3 — calendar toggle.** Same shape as row 1.

**Rows 2 and 3 are hidden, not disabled, when the master toggle is off.** This is what the brief
asked for. Note the divergence from the neighbouring AI Enhancements section, which *disables*
dependent rows (`summaryPromptRow` uses `.disabled(!viewModel.aiAnalysisEnabled)`). Hiding keeps the
section compact when the feature is off; disabling would keep the feature's capabilities visible.
The section collapses to a single row when off, so the header still advertises the feature.

**Implementation gotcha.** `SettingsView.sectionTitles` is a positional array and section headers are
read as `sectionTitles[N]`. "Custom Vocabulary" sits at index 4, between AI Enhancements (3) and
Calendars (5). Every `sectionTitles[N]` reference must match these indices, and the existing
`SettingsUI` tests that assert on titles must be updated.

## 2. Vocabulary list editor (sheet)

Opened by **Edit List (N)**. Modeled on `SummaryPromptSheet`: a `VStack` with `Tokens.spacingLG`
padding and a fixed width, but narrower — this is a simple list, not a prose editor.

```
┌──────────────────────────────────────────────────────────┐
│  SETTINGS                                    ← kicker     │
│  Vocabulary List                             ← serif 27   │
│  Words to watch for in every meeting.        ← 13pt       │
│                                                           │
│  ┌─────────────────────────────────┐  ┌──────┐            │
│  │ Add a word or phrase…           │  │ Add  │            │
│  └─────────────────────────────────┘  └──────┘            │
│  "Acme" is already in your list.             ← inline err │
│                                                           │
│  ┌───────────────────────────────────────────────┐        │
│  │ Acme Corp                                 ⊖   │        │
│  │ Scosman                                   ⊖   │        │
│  │ Kubernetes                                ⊖   │        │
│  │ …                                             │  ← scrolls
│  └───────────────────────────────────────────────┘        │
│                                                           │
│  ─────────────────────────────────────────────────────    │
│                                            [ Done ]       │
└──────────────────────────────────────────────────────────┘
```

- **Width** ~520pt, list area capped at ~320pt tall then scrolling.
- **Header**: kicker `SETTINGS` (`.kicker()`, `.sage`), serif title `Vocabulary List`, 13pt
  `.inkSecondary` subtitle — matching `SummaryPromptSheet.headerSection`.
- **Add field**: a `TextField` with placeholder `Add a word or phrase…` plus an `Add` button.
  Return in the field also commits. The field is focused when the sheet opens. It clears on a
  successful add and keeps focus, so several terms can be typed in a row.
- **Inline validation message** appears under the add field and clears on the next keystroke:
  - duplicate (case-insensitive): `"<term>" is already in your list.`
  - over 60 characters: `Keep terms under 60 characters.`
  - whitespace-only input is ignored silently — no message, no add.
- **Term rows**: each is an editable `TextField` bound to that term (click to edit in place, commit on
  Return or focus loss) with a trailing remove control. Editing applies the same trim/duplicate/length
  validation; an edit that would duplicate another term reverts. Order is insertion order and is not
  reorderable.
- **Empty state** replaces the list area:
  `No words yet. Add names, company names, or technical terms Biscotti should listen for.`
- **Footer**: a `Divider()` and a right-aligned `Done` button (`.keyboardShortcut(.defaultAction)`).
  There is no Cancel — changes autosave as they are made, matching the rest of Settings.
- **No budget warning.** Per the functional spec, a list longer than 12 terms shows nothing special;
  the `Edit List (N)` count is the only signal.

## 3. Re-transcribe alert

A standard SwiftUI `.alert` on the meeting detail view, fired after an association is attached or
changed. It reuses the already-present `showReTranscribeAfterCorrection` flag and its
`reTranscribeAfterCorrection()` / `dismissReTranscribePrompt()` actions.

```
        ┌────────────────────────────────────────────────┐
        │  Re-transcribe with keywords from this event?  │
        │                                                │
        │  We'll use this event's title, description     │
        │  and attendee list to improve transcription    │
        │  accuracy.                                     │
        │                                                │
        │                       [ Cancel ]  [   OK   ]   │
        └────────────────────────────────────────────────┘
```

- `OK` is the default action; `Cancel` has `role: .cancel`.
- The alert appears **only** when every precondition in functional spec §6 holds — including that the
  recomputed vocabulary actually differs from what the existing transcript used. It never appears as a
  no-op offer.
- Accepting routes into the existing re-transcribe path, so progress and error surfacing are unchanged.

## 4. UX notes and rejected alternatives

- **Sheet over inline list.** An inline add/remove list in Settings (as sketched in
  `specs/projects/stage_c/ui_design.md`) would make the section grow without bound and unbalance the
  grouped form. A count-bearing button into a sheet keeps Settings scannable and matches the
  neighbouring `Summary Prompt → Customize…` row.
- **No search or import.** A list this size (a dozen or so terms that matter) does not need either.
- **No per-term "source" display.** Automatically-derived terms are not shown anywhere in V1 — see
  functional spec §11. If auto-extraction proves noisy in real use, the natural follow-up is a
  read-only "words used" row in meeting detail, driven by the already-persisted
  `TranscriptRecord.vocabularyUsed`.
