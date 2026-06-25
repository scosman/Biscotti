---
status: complete
---

# UI Design: Custom Summary Prompt

**Approach:** keep the design spec's **layout and UX** as-is; substitute only the
**non-standard visual styling** for native design-system equivalents. Concretely we
swap: Newsreader → `biscottiSerif`, IBM Plex Mono → the app's JetBrains Mono
(`kicker()` / `monoKicker`), hardcoded hex → semantic color tokens, the sage
*gradient* button → a flat `.borderedProminent.tint(.sage)`, the `#fff` card + custom
border → `.cardFill` + `.cardStroke`, and the amber Markdown-heading tint → the
`MarkdownEditor`'s own theming. We do **not** restructure the screen.

Components/tokens reused (all exist today): `MarkdownEditor` (`MarkdownEditorUI`),
`FlowLayout` + `kicker()` + `biscottiSerif` + color tokens (`DesignSystem`), and the
existing sheet/footer button convention.

---

## 1. Settings row (entry — Global mode)

In `SettingsView.aiEnhancementsSection`, between **AI Analysis & Summary** and **AI
Language Model**, a row mirroring `aiLanguageModelRow`:

```
Summary Prompt                                       [ Customize… ]
Customize the instructions used to write meeting summaries.
```

- `HStack { VStack(alignment:.leading, spacing: spacingXS){ Text("Summary Prompt"); Text(subtitle).font(metadataFont).foregroundStyle(secondaryText) }; Spacer(); Button("Customize…"){…}.buttonStyle(.bordered).controlSize(.small) }`.
- No chevron / accent tint — same chrome as "Manage".
- Disabled (`.disabled(!aiAnalysisEnabled)`) when AI Analysis & Summary is off.
- Presents the editor sheet (Global mode) via `.sheet(item:)` driven by `summaryPromptModel`.

---

## 2. The editor sheet — shared layout

One reusable view, two modes (Global / Per-meeting). Standard modal `.sheet`, fixed
width **720** (the design's editor width), height fits content up to the window height,
the editor scrolls internally. Outer `VStack(alignment:.leading, spacing: spacingMD)`,
padding `spacingLG`. Top → bottom, **matching the design spec's order**:

1. **Header** — kicker · serif title · subtitle (+ meeting reference chip in
   Per-meeting mode).
2. (Per-meeting only, when `editedSummary`) **Replace warning** — inline
   warning icon (`exclamationmark.triangle.fill`, `.warningOchre`) + caption.
3. **Editor** card — `MarkdownEditor`.
4. (empty-prompt caption, when empty)
5. **`ADD SECTION`** field label.
6. **Section chips** — wrapping `FlowLayout` row.
7. (Per-meeting only) **Also-save checkbox**.
8. **Footer** — Restore Default · spacer · Cancel · primary.

```
┌──────────────────────────────────────────────────────────────────────┐  width 720
│  MEETING SUMMARY                                                       │  kicker(), .sage
│  Summary Prompt                                                        │  biscottiSerif(27), .ink
│  These are the instructions Biscotti sends the on-device model to      │  .system(size:13), .inkSecondary
│  write each meeting summary. Edit them directly. Changes apply to      │  (max width ~560)
│  every future summary.                                                 │
│  ⚠ Regenerating will replace the summary you edited for this meeting.  │  (per-meeting only, when edited)
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐ │  MarkdownEditor
│  │ Next produce a clear, well-organized markdown summary of the      │ │  native scrolling,
│  │ meeting. ...                                                       │ │  bounded ~340pt,
│  │ ▏                                                                  │ │  .cardFill / .cardStroke
│  └──────────────────────────────────────────────────────────────────┘ │  / cardRadius
│  The prompt can't be empty.                  (only when empty)         │  metadataFont, .signalRedText
│                                                                        │
│  ADD SECTION                                                           │  kicker(), .inkTertiary
│  [ + Slack recap ] [ + Meeting feedback ] [ + Decisions ]             │  FlowLayout of chips
│  [ + Key quotes ] [ + Sentiment ]                                     │
│                                                                        │
│  ────────────────────────────────────────────────────────────────────│  Divider
│  ↺ Restore Default                    ⟨spacer⟩    [ Cancel ] [ Save ]  │  footer
└──────────────────────────────────────────────────────────────────────┘
```

### 2.1 Header
- Kicker: `Text("MEETING SUMMARY").kicker().foregroundStyle(.sage)` (the `kicker()`
  modifier supplies JetBrains Mono 10.5 / uppercase / tracking; caller sets the color).
- Title: `Text("Summary Prompt").font(.biscottiSerif(27)).tracking(-0.27).foregroundStyle(.ink)`.
- Subtitle: `.font(.system(size: 13)).foregroundStyle(.inkSecondary)`, `frame(maxWidth: ~560, alignment:.leading)` (2pt larger than `Tokens.metadataFont`).

### 2.2 Field label (`ADD SECTION`)
- `Text("ADD SECTION").kicker().foregroundStyle(.inkTertiary)` — the design's small mono
  field label, rendered with the app's kicker style. The `PROMPT` label above the editor
  was removed (duplicative with the main title).

### 2.3 Editor
- Reuse `MarkdownEditor` (decided — it trumps a bespoke monospace box; it renders the
  `##` structure and matches how Notes/Summary are edited).
- **Native scrolling** (NOT fits-content): a fixed comfortable height (~**340pt**) with
  internal scrolling, so long prompts scroll inside the card rather than growing the sheet.
- **Editable-field affordance (new for this context).** Elsewhere the editor sits flush
  in a page; here it must *read as an editable input*: a field-like background
  (e.g. `.elevatedFill`), a 0.5pt `.cardStroke` border, and `Tokens.cardRadius` rounded
  corners, with comfortable text insets. We don't style it this way elsewhere, but this is
  a different UI. **Implementation note → architecture:** this likely needs new options on
  the `MarkdownEditor` SwiftUI wrapper (background / corner radius / border / bounded-scroll
  height), or — if `MarkdownEditor` adds nothing we need here — using the underlying
  third-party `NativeTextViewWrapper` directly.
- **Font (P2, a merge not a divergence):** if it's a simple setting, render this editor in
  JetBrains Mono (the app's mono) to suit raw-prompt editing; otherwise the default body
  font is fine. `MarkdownEditor`'s markdown theming takes priority over strict monospace.
- Markdown headings styled by the editor itself (no custom amber tint).
- `documentId` stable per context (e.g. `"summary-prompt"` Global; meeting-scoped per-meeting).

### 2.4 Empty-prompt caption
- When working text is empty/whitespace: `Text("The prompt can't be empty.").font(Tokens.metadataFont).foregroundStyle(.signalRedText)` under the editor; primary disabled (§2.6). Hidden otherwise.

### 2.5 Section chips (visible, wrapping)
- A `FlowLayout` row of chip buttons, one per section: `+ Slack recap`,
  `+ Meeting feedback`, `+ Decisions`, `+ Key quotes`, `+ Sentiment`,
  `+ Make No Mistakes`.
- **Chip styling (token-based, not TagPill):** a `Button` with a small `HStack` (a
  `plus`/`checkmark` SF Symbol + label, system ~11.5 medium), `chipRadius`/`buttonRadius`
  corner, `.buttonStyle(.plain)`.
  - **Default state:** `.neutralChip` fill, `.ink` label, leading `plus` glyph.
  - **Added state** (block already present): `.accentWashStrong` (sage wash) fill,
    `.sage` label, leading `checkmark` glyph; click is a **no-op**. (Mirrors the design's
    "added" affordance using sage *tokens*, no gradient.)
- Clicking a not-added chip **appends** its block (`\n\n` + block) to the end of the
  editor text and reveals it if practical (§5 of functional spec).

### 2.6 Footer
- `Divider()` then `HStack`:
  - **Left:** `Button { confirmRestore() } label: { Label("Restore Default", systemImage:"arrow.counterclockwise") }.buttonStyle(.borderless).foregroundStyle(.inkSecondary)`. Disabled/no-op when working text already equals the factory default.
  - `Spacer()`.
  - **Cancel:** `Button("Cancel"){ attemptCancel() }.keyboardShortcut(.cancelAction)`.
  - **Primary:** `.buttonStyle(.borderedProminent).tint(.sage).keyboardShortcut(.defaultAction).disabled(workingIsEmpty)` — **flat sage, no gradient**. Label per mode.

### 2.7 Confirmations (standard `.confirmationDialog`)
- **Restore Default** (editor ≠ default): "Restore the default summary prompt? Your current edits in this editor will be replaced." → Restore / Cancel.
- **Cancel with unsaved changes** (working ≠ initial): "Discard your changes?" → Discard / Keep Editing. No changes → dismiss immediately. (Esc routes through this.)

---

## 3. Mode differences

| | **Global** (Settings) | **Per-meeting** (Regenerate) |
|---|---|---|
| Kicker | `MEETING SUMMARY` | `RE-SUMMARIZE` |
| Title | `Summary Prompt` | `Re-summarize this meeting` |
| Subtitle | "These are the instructions Biscotti sends the on-device model to write each meeting summary. Edit them directly. Changes apply to every future summary." | "Re-summarize this meeting with AI, optionally changing the prompt." |
| Meeting chip | — | read-only reference chip below the subtitle: `waveform` glyph · meeting title · date (· duration if available), styled `.neutralChip` / `metadataFont` / `.inkSecondary` |
| Initial text | effective saved prompt | effective saved prompt |
| Extra control | — | `Toggle("Also save these changes as my default", isOn:)` default **off**, above the Divider |
| Replace warning | — | when `editedSummary == true`: warning icon (`exclamationmark.triangle.fill`, `.warningOchre`) + caption "Regenerating will replace the summary you edited for this meeting." (`metadataFont`, `.inkSecondary`), directly under the subtitle at the top of the sheet body |
| Primary | `Save` | `Regenerate` |
| On primary | persist (clear-to-default rule) · dismiss | regenerate this meeting · optional save · dismiss · switch to Summary tab |

The reference chip mirrors the design spec's §4 "meeting reference chip"; the Per-meeting
mode otherwise reuses the same full editor (the approved unification of the two design
sheets), differing only by the rows noted above.

---

## 4. Per-meeting entry point

`MeetingDetailView.overflowMenu`'s existing **Regenerate Summary** item keeps its label
and enablement (transcript present + model downloaded), but now presents the editor sheet
in Per-meeting mode instead of running the old confirm/regen path. The sheet's
**Regenerate** button performs the run; the Summary tab's existing streaming/progress/error
UI shows it after dismissal. First-run **Generate Summary** (Summary tab) is unchanged
(direct generation with the saved prompt). Sheet presented via the existing meeting-detail
sheet pattern (as the Speaker mapping sheet).

---

## 5. States, accessibility, platform

- **Generation feedback:** none new in the sheet; on Regenerate it dismisses and the
  Summary tab shows the run as today.
- **Dark mode / reduced motion:** inherited — all colors are dynamic tokens, the editor
  adapts, standard sheet presentation. Nothing feature-specific.
- **Keyboard / VoiceOver:** standard controls (Button, Toggle, the editor, chip buttons);
  Return = primary, Esc = Cancel (through the unsaved-changes confirm). Restore Default and
  chips are neither default nor cancel actions.
