---
status: complete
---

# UI Design: LLM Features

macOS app, SwiftUI. All new UI reuses the existing `DesignSystem` (`Tokens`, `MarkdownEditor`, `StatusRow`, `Banner`, sheet patterns like `EventPickerSheet`) and follows current conventions. Five surfaces:

1. **Summary tab** (new, first tab on meeting detail)
2. **"Regenerate Summary"** item in the meeting-detail "…" overflow menu (+ confirm dialog)
3. **Speaker names in the transcript** + clickable speaker → **Speaker mapping sheet** (new)
4. **"AI Enhancements"** section in Settings + **model-download row**
5. **Subtle auto-run status** indicator on meeting detail

---

## 1. Summary tab (meeting detail)

### Placement
A new first segment in the existing `tabBar` segmented picker: **`Summary` | `Transcript` | `Notes`** (new `MeetingDetailViewModel.Tab.summary` declared first so `allCases` orders it first). The tab content area is the same single-scroll region used by Notes/Transcript.

### States

**(a) Has content (default editable view)** — reuse `MarkdownEditor`, identical to Notes:
```
┌───────────────────────────────────────────────┐
│ ## Summary                                     │  ← rendered/edited markdown
│ The team reviewed Q3 numbers and agreed to …   │     (MarkdownEditor, isEditable,
│                                                │      documentId "<id>-summary")
│ ## Action Items                                │
│ - [ ] Daniel to send the revised deck          │
│ - [ ] Priya to confirm vendor pricing          │
└───────────────────────────────────────────────┘
```
- Edits autosave with the same debounce-then-flush as notes; the **first real user edit sets `editedSummary = true`**.
- Fills available height (`minHeight: max(100, fill)`), like Notes.

**(b) Generating (streaming)** — the editor is **read-only** while tokens stream in; markdown grows live. A subtle header line above the editor: a small spinner + `Generating summary…`. No buttons (Regenerate is disabled during the run). When the stream finishes, the editor becomes editable.

**(c) Empty — model available, never generated** — centered call-to-action:
```
        ✦  No summary yet
   [ Generate Summary ]      ← primary button; generates from the
                               currently selected transcript version
```

**(d) Empty — feature off OR no model** — centered hint (no Generate button), with a button that navigates to Settings:
- No model: `An AI model is needed to summarize. ` + **`Open Settings`** (→ download).
- Model present but "Summarize Transcripts" off: `Turn on AI summaries in Settings to generate one automatically.` + **`Open Settings`**.

**(e) No transcript yet** — the meeting is still recording/processing or has no transcript: Summary tab shows the same muted `No transcript available.` placeholder logic the Transcript tab uses (a summary needs a transcript first). No Generate button.

**(f) Error** — a quiet inline `Banner(style: .error, actionLabel: "Retry")` at the top of the tab: `Couldn't generate the summary.` + **Retry**. The rest of the detail view is unaffected. Any previously saved summary remains shown below the banner.

### Copy
`canCopy` extends to `.summary` (copies the markdown source); the existing tab-bar Copy button works on the Summary tab too.

---

## 2. "Regenerate Summary" (overflow "…" menu)

Add a `Button` to `overflowMenu`, grouped with the AI/transcript actions (just under **Re-transcribe**), shown when a transcript exists **and** a model is available:
```
Label("Regenerate Summary", systemImage: "sparkles")
```
- **Disabled** while any AI run is in progress for this meeting (and while transcribing).
- Regenerates from the **currently selected transcript version** (`activeVersionID`), streaming into the Summary tab (auto-switches to the Summary tab on tap).
- **Confirm dialog** only when `editedSummary == true`:
  > **Replace your edited summary?** — "This will overwrite the summary you edited with a new AI-generated one."  [Replace] [Cancel]
  (`.confirmationDialog`, destructive **Replace**.) When the summary is empty or auto-generated, regenerate immediately with no dialog.
- After success, `editedSummary` resets to `false`.

The empty-state **Generate Summary** button (1c) and this menu item share one code path.

---

## 3. Transcript: speaker names + mapping

### 3.1 Name replacement (display-layer)
In `TranscriptContent.attributedString()`, each segment's speaker span shows the **assigned person's name** when the transcript's speaker→person map has an entry for that segment's `speakerID`; otherwise the original `Speaker N`. Per-speaker **color stays keyed on the numeric speaker ID**, so a speaker keeps the same color whether shown as "Speaker 1" or "Priya". Stored `speakerLabel` is never mutated.

### 3.2 Clickable speaker → sheet
The speaker name span becomes a **link** (a `biscotti://speaker?...` URL handled in `SelectableTranscriptView`'s `openURL`, mirroring the `SeekLink` timestamp pattern). Because the transcript is a single selectable `Text(AttributedString)`, the affordance is lightweight and **inline-only** (no helper tip, no separate button):
- Speaker spans already render **semibold + colored**; as links they also get the app tint behavior and a **pointing-hand cursor on hover**.

Clicking any speaker opens the **Speaker mapping sheet** (focused on that speaker).

### 3.3 Speaker mapping sheet (new — `SpeakerMappingSheet`)
A reusable sheet (DesignSystem-style, like `EventPickerSheet`), presented via `.sheet` on the detail view. Works on the **currently displayed transcript** and **does not require a model** (pure manual assignment).

```
┌──────────────────────────────────────────────┐
│ Rename speakers                                │
│ Match each detected speaker to a person.       │
│                                                │
│ ● Speaker 0   [ Daniel Lee            ▾ ]      │
│ ● Speaker 1   [ Priya                 ▾ ]      │
│ ● Speaker 2   [ Unassigned            ▾ ]      │
│                                                │
│                                  [ Done ]      │
└──────────────────────────────────────────────┘
```
- One row per diarization speaker (Speaker 0…N for this transcript). The leading **● color dot** matches the transcript color for that speaker ID.
- The assignment control is a **`Menu`/dropdown** (searchable for long lists) with grouped options:
  - **Invitees** — meeting invitees first (organizer + `calendarContext.attendees`), each `name` (+ email shown muted).
  - **People** — all other known people (`DataStore.allPersonData()`), deduped against invitees.
  - **Add person…** — opens an inline text field; typing a name + confirming creates a **name-only** `Person` and assigns it.
  - **Unassigned** — clears the speaker back to "Speaker N".
- Selecting/clearing updates the transcript's speaker→person map immediately (or on **Done**); the transcript re-renders with new names. (Apply-on-change is fine; **Done** just dismisses.)
- Empty/edge: if a meeting has no invitees and no people yet, the dropdown shows only **Add person…** and **Unassigned**.

---

## 4. Settings → "AI Enhancements"

A new `Section` in the existing grouped `Form` (`SettingsView`), placed after **General** (above Notifications). Standard toggle-with-subtitle rows (the established `VStack(spacing: Tokens.spacingXS){ Toggle; subtitle Text }` pattern), bound through `SettingsViewModel` → `AppSettings`.

### 4.1 Model present
```
AI Enhancements
AI runs locally on your Mac.

  Summarize Transcripts                          [ ●]
  Automatically generate a summary of your meetings.

  Guess Speaker Names                            [ ●]
  Use information from the transcript to assign speaker names.
```
- Both toggles enabled; reflect stored values (defaults **on**).

### 4.2 No model downloaded
```
AI Enhancements
AI runs locally on your Mac.

  Summarize Transcripts                          [○ ] (disabled)
  Automatically generate a summary of your meetings.

  Guess Speaker Names                            [○ ] (disabled)
  Use information from the transcript to assign speaker names.

  Download Local Language AI Model?
  Several GB · runs entirely on your Mac.        [ Download ]
```
- Both toggles **disabled and shown off** regardless of stored value.
- **Download row** states:
  - **Idle:** subtitle with size hint + **`Download`** button.
  - **Downloading:** a determinate `ProgressView(value:total:)` bar with `NN%` (or bytes when total unknown) and a muted `Downloading…`. Button hidden/disabled.
  - **Failed:** inline error text + **`Retry`** button.
  - **Completed:** the download row disappears; the two toggles become **enabled** and reflect their stored defaults (on). (Optional brief "Model installed" confirmation.)
- Model presence is observed live so the section flips from 4.2 → 4.1 when the download finishes (no app restart).

---

## 5. Subtle auto-run status (meeting detail)

A small, non-modal status **pill in the `tabBar` row, trailing side** (next to the version picker / Copy affordance), shown only while an AI run is active for the open meeting:
```
[ Summary | Transcript | Notes ]              ✦ Enhancing…  ⟳
```
- Tiny spinner + label that reflects the active phase: `Identifying speakers…` then `Summarizing…` (or just `Enhancing…`). Muted `metadataFont`, `inkSecondary`.
- **Speaker labels stay "Speaker N" during the run** (no per-label spinners); they switch to names when speaker-ID completes and the detail reloads.
- The **Summary tab's own streaming** (1b) is the primary feedback once summarizing starts; this pill covers the whole run (including the speaker-ID phase that has no other UI).
- On completion the pill disappears; on failure it disappears and the relevant quiet error (Summary banner) shows. (List-row–level indicators are out of scope; this is detail-view only.)

---

## 6. Resolved choices

1. **Auto-run status location** — tab-bar trailing pill (§5). *(Superseded by §7.1 — moved to a main-area pipeline control; pill removed.)*
2. **Speaker-rename entry** — **inline clickable speaker labels only** (no tip line, no separate button) (§3.2).
3. **Sheet apply timing** — apply each change immediately; **Done** just dismisses.

Everything else follows existing components/styles; no new visual language is introduced.

---

## 7. Polish Revisions (Round 2)

Screen-level refinements added after on-screen review. These **supersede** the noted earlier sections. See `functional_spec.md` §13 for behavior and `implementation_plan.md` Phases 7–11.

### 7.1 Processing-pipeline status in the Summary tab (supersedes §5)
The trailing tab-bar pill (§5) is **removed**. While a meeting is processing, the Summary tab's main content area shows a **stacked stage list** (replacing the old "No transcript available." placeholder):
```
   ✓  Transcribing
   ⟳  Inferring participant names        ← active (small spinner)
   ◦  Summarizing                         ← pending (depends on the two above)
```
- One row per stage that will run; **leading glyph** = done (✓/checkmark, `inkSecondary`), active (small `ProgressView`), or pending (dim circle, `inkTertiary`). Labels in the standard muted `monoMeta`/secondary style — no new visual language.
- Stages are gated (§13.1): no model or both toggles off → only **Transcribing** shows. The summary row reads as gated on the first two.
- Uses the existing small-spinner idiom already used by `summaryStreamingContent` (the "Generating summary…" affordance) — reuse, don't reinvent.
- **Auto-jump:** detail view switches to the Summary tab once when the pipeline goes active (so this control, then the streaming summary, are in view).
- When summarizing begins, the existing **streaming view (§1b)** takes over the tab; the pipeline control is the pre-summary signal.

### 7.2 Summary completion — no flash / scroll retained (refines §1a/§1b)
Render streaming and final summary through **one `MarkdownEditor`** (single `documentId`, flip `isEditable`), and populate the editable text atomically as streaming clears — no transient empty/Generate frame, scroll offset preserved across the last token.

### 7.3 Settings — header caption + section order (supersedes §4)
- "AI runs locally on your Mac." renders as **muted text trailing the section header** rather than as a section footer:
  ```
  AI Enhancements                       AI runs locally on your Mac.
  ```
  (header row: title · `Spacer()` · `inkSecondary` caption in `metadataFont`).
- **Section order:** General → **Permissions** → AI Enhancements → Notifications → Calendars (Debug last).

### 7.4 Shared speaker color (supersedes §3.1)
When multiple speaker IDs are assigned to the **same person**, they share that person's color (color keyed on `Person.id` when assigned; speaker-ID key only when unassigned). The mapping sheet's leading **● color dot** follows the same rule.

---

## 8. Speaker mapping sheet — filterable person picker (Round 3)

Refines the per-row assignment control in `SpeakerMappingSheet`. **Supersedes §3.3's `Menu` dropdown.** See `functional_spec.md` §14 for behavior and `implementation_plan.md` Phase 13.

### 8.1 Closed control (essentially unchanged)
Each speaker row keeps its leading **● color dot**, the "Speaker N" label, and a pill showing the current assignment + chevron:
```
● Speaker 0   [ Daniel Lee            ▾ ]
● Speaker 1   [ Unassigned            ▾ ]
```

### 8.2 Sheet title + Done
The sheet title reads **"Assign Speaker Names"** (was "Rename speakers"). The footer **Done** button is rendered larger/more prominent (e.g. `.controlSize(.large)`), as the sheet's primary affordance.

### 8.3 Open control — clicking the pill opens a filterable popover
```
● Speaker 0   [ Jeff Lebowski         ▾ ]
            ┌──────────────────────────────────┐
            │ 🔍 Jeff L▏                        │ ← auto-focused, blinking cursor
            ├──────────────────────────────────┤
            │ ⊘  Unassign                       │ ← only when assigned; hidden
            │                                    │    when already unassigned
            │ INVITEES                           │
            │   Jeff Lebowski   jeff@acme.com    │
            │ ALL PEOPLE                         │
            │   Jeff Lin        jl@corp.com      │
            │ ＋ Add "Jeff L"                    │ ← appears: query non-empty,
            │                                    │    no exact name match
            │ + 38 more — type to filter         │ ← status row (people > shown)
            └──────────────────────────────────┘
```
- **Auto-focus:** the search field is focused on open (`@FocusState`), cursor blinking; typing filters **instantly** per keystroke.
- **Sections:** **Invitees** then **All People** (renamed from "People"), standard muted section headers; rows show `name` + muted `email` (the existing `personLabel` style).
- **Unassign** (verb) is a pinned action at the top of the list (not a person row), **shown only when the speaker currently has an assignment**; hidden when already unassigned.
- **Add row** uses the `plus` glyph + `Add "<query>"`; it is the **only** add affordance (the separate "Add person…" text-field popover from §3.3 is removed).
- **Status row** is muted `metadataFont`/`inkSecondary`, non-interactive.
- **At most 15 person rows** render (the Unassign and Add actions don't count); the user narrows by typing rather than scrolling a long list (§14.4 windowing).
- **No scrolling:** the popover **sizes to its content** and grows to its full natural height — it does not scroll internally (the 15-row cap bounds the height).
- **Keyboard:** within the popover, ↑/↓ highlight, Return commits the highlight (or Adds when nothing is highlighted and the Add row is present), Esc closes (§14.5). Across the sheet, **Tab moves between the speaker rows' pickers** and the Done button.

### 8.4 Styling
Reuse existing `DesignSystem` tokens, the current row/`personLabel` styling, the small section-header treatment, and the popover idiom already used by the sheet — **no new visual language**. The popover is sized to a fixed comfortable width (≈ the current label width) and grows to fit up to 15 rows + the pinned/status rows (no internal scroll).
