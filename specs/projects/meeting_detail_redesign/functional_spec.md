---
status: complete
---

# Functional Spec: Update Meeting Screen

The redesign of `MeetingDetailView` (in `Packages/BiscottiKit/Sources/MeetingDetailUI`)
— the detail pane for **one past meeting** with a recording and transcript. It
restyles the existing screen toward the design agent's "F · Sage + Pressroom"
identity while staying on native SwiftUI/AppKit controls and our existing
`DesignSystem` palette and fonts.

This is a **UI redesign of existing, working functionality** plus a few small
new behaviors (clickable transcript timestamps, copy transcript, playback speed,
Reveal in Finder). The data model, audio playback engine, transcription
pipeline, calendar association, notes autosave, delete, and version switching
all already exist and are reused — we are re-laying-out and lightly extending
them, not rebuilding.

---

## Decisions locked (from speccing Q&A)

1. **Tabbed body.** Transcript and Notes live behind a native segmented `Picker`;
   only one shows at a time. Default tab: **Transcript**. The calendar card and
   audio player stay pinned above the segmented control.
2. **Title = inline-editable serif field.** Always-editable `TextField` rendered
   in the Newsreader serif display font. **No "Rename…" menu item.**
3. **Transcript = one selectable block.** A single SwiftUI `Text(AttributedString)`
   with `.textSelection(.enabled)` so a drag-selection spans turns. Plus a
   **"Copy Transcript"** copy-all action. No per-turn avatars.
4. **Clickable timestamps** in the transcript jump playback to that time and
   **preserve play/pause state** (maps to the existing `viewModel.seek(to:)`).
5. **Playback speed (P2, included).** A native **Menu** (0.5× / 1× / 1.25× /
   1.5× / 2×) on the transport. Requires adding a `rate` to the playback seam.
6. **Notes fills the pane (≥500pt).** One outer scroll; the Notes editor fills
   the height left below the chrome with a **500pt floor**, scrolling internally
   (Notes.app/Mail pattern) — no double scroll, no `MarkdownEditorUI` change, no
   fixed-340px box. When there's room the chrome looks pinned; when the window is
   too short (or the calendar card is tall/expanded) the pane scrolls so the
   editor keeps its 500pt floor. (Decided after confirming the pinned engine
   exposes no content-height API.)
7. **Version picker** moves next to the Transcript tab (only shown when >1
   version); **"Re-transcribe"** moves into the "…" overflow menu.
8. **Export Transcript is deferred** — not in this project (copy-all covers the
   need). Dropped from the menu.

## Defaults applied — please redline if any are wrong

- **D1. No window-toolbar button.** The design's toolbar "new recording" button
  is **dropped**: the app shell already owns a global Record button in the
  window toolbar; a second one here would duplicate it and isn't what a native
  Mac app would do. This view contributes no toolbar items (consistent with how
  every other detail view works today).
- **D2. Delete moves into the "…" menu** (`role: .destructive`, native red) and
  the standalone "Delete Meeting" button/section is removed. Still guarded by the
  existing `.confirmationDialog`.
- **D3. Calendar (re)association lives in the "…" menu only.** The card has no
  inline Change/Link button. When no event is linked, the menu shows "Link
  Calendar Event…"; when linked, it shows "Change Calendar Event…" (opens the
  existing event-picker sheet) and "Unlink Calendar Event."
- **D4. Attendee avatar stack** (overlapping colored-initial circles) appears in
  the calendar card only — derived from real attendee names. (Transcript turns
  have no avatars per decision 3.)
- **D5. Reading-width cap.** Content is left-aligned in a column capped at ~760pt
  with generous insets, inside the pane's ivory background.
- **D6. Palette & fonts reuse.** Use existing `DesignSystem` colors
  (`.sage`/`.ink`/`.inkSecondary`/`.inkTertiary`/`.paper`/`.cardStroke`/
  `.hairline`/`.neutralChip`/…). Title = `Font.biscottiSerif`; all timestamps /
  durations / dates / URLs / kicker labels = `Font.biscottiMono` with **tabular
  figures**; everything else = system (SF Pro). No new colors; no IBM Plex (we
  use JetBrains Mono).

---

## Screen anatomy (top → bottom)

**Scroll model:** one outer `ScrollView`. The Notes editor is sized to fill the
height left below the chrome (header, calendar card, transport, tab bar) with a
**500pt floor**, scrolling internally; when it fits, the chrome looks pinned and
nothing else scrolls (no double scroll); when the window is too short, the pane
scrolls to preserve the floor. The Transcript tab's single selectable text grows
and the outer scroll handles it. Layout order:

### 1. Header
- **Title** — inline-editable `TextField`, Newsreader serif (~27pt, medium),
  `.ink`, tight tracking. Saves on submit and on disappear (existing
  `saveTitle()` / `editableTitle`). Empty submit keeps the prior title.
- **Trailing "…" overflow `Menu`** (borderless, `ellipsis.circle`):
  - Reveal in Finder (`folder`) — selects **both** source tracks (mic + system)
    in Finder via `NSWorkspace.activateFileViewerSelecting`. Hidden/disabled if
    no audio files are present.
  - Re-transcribe (`arrow.triangle.2.circlepath`) — shown only when
    `canReTranscribe`.
  - — divider —
  - Calendar association (menu-only — the card has no inline control):
    - **Link Calendar Event…** (`calendar.badge.plus`) — when no event is
      linked; opens the event-picker sheet.
    - **Change Calendar Event…** (`calendar`) — when an event is linked; opens
      the event-picker sheet.
    - **Unlink Calendar Event** (`calendar.badge.minus`) — when an event is
      linked; direct remove-association.
  - — divider —
  - Delete Meeting… (`trash`, `role: .destructive`).
- **Meta line** — `Font.biscottiMono`, `.inkSecondary`, middle-dot (`·`)
  separators in `.inkTertiary`:
  - relative date/time (e.g. "Yesterday at 4:18 PM"),
  - duration (e.g. "32 min"),
  - **source pill** — a `Capsule`-clipped `Label(platform, systemImage:
    "video.fill")` with the icon tinted `.sage`, on a `.neutralChip` fill. Shown
    only when a conference platform is known; omitted otherwise.

### 2. Calendar info card (only when an event is linked)
A rounded white-ish card (`Tokens.cardFill` / `.cardStroke` hairline). Contents:
- **Row A** — attendee **avatar stack** (overlapping colored-initial circles) +
  attendee summary text (organizer name in `.ink` medium, others in
  `.inkSecondary`) + `Spacer()` + a soft secondary **"Open in Calendar"** button
  (existing `openInCalendar()`).
- **Divider** (`.hairline`).
- **Row B — `DisclosureGroup` labeled "Description"** (stock control, leading
  triangle, system animation):
  - *Collapsed:* triangle + "Description" + a single truncated preview line of
    the event notes. (If the event has no notes, show the disclosure with the
    definition list but no preview line — or omit the preview gracefully.)
  - *Expanded:* a definition list (`Grid`, fixed ~74pt label column) with
    monospace **kicker** labels (`.kicker()` style, `.inkTertiary`) and values:
    - **WHEN** — date/time range (mono).
    - **WHERE** — conference icon (sage) + platform + mono URL; and/or location.
    - **DESCRIPTION** — wrapped event notes paragraph (`.inkSecondary`).
    - **INVITED** — attendee names ("Steve (organizer) · Alex · Jay · +2").
- **(Re)association** is **not** on the card — it lives in the "…" menu (Link /
  Change / Unlink). When no event is linked, no card is shown at all; the user
  links via the menu's "Link Calendar Event…".

### 3. Audio transport card
A rounded card (transport restyle of the existing `AudioTransport`):
- **Play/pause** — circular button, `.ink` glyph, hover fill `.neutralChip`.
- **Elapsed** — mono, tabular, `.inkSecondary`.
- **Scrubber** — native `Slider`, `.tint(.sage)`, bound to `currentTime`
  (existing `onSeek`).
- **Total** — mono, tabular, `.inkSecondary`. Uses the meeting's stored
  `recordingDuration` when available (existing decode-correction logic).
- **Speed Menu** — soft secondary styled `Menu` showing the current rate (e.g.
  "1×") with options 0.5 / 1 / 1.25 / 1.5 / 2×.
- **Disabled state** — when `!canPlay`, show the existing "Audio not available"
  treatment; the speed menu is disabled too. No download button.

### 4. Segmented control — Transcript | Notes
Native `.segmented` `Picker`, left-aligned, content-width (`.fixedSize()`).
The **version picker** sits beside it on the trailing side, visible only when
`versions.count > 1` (existing `VersionPicker`, restyled to fit).

### 5. Tab content
Below the segmented control, exactly one of:

- **Transcript tab** — switches on the existing transcript display state:
  - *processing* → centered status row / spinner (existing `StatusRow`).
  - *failed* → error `Banner` with optional Retry (existing).
  - *empty* → "No transcript available."
  - *ready* → **the selectable transcript block** (see "Transcript rendering").
  - A **"Copy Transcript"** button is shown in this tab when a transcript is
    ready (placement: trailing, near the segmented control or top of the tab —
    final placement is a UI-design detail).
- **Notes tab** — the `MarkdownEditor` bound to `viewModel.notes` (existing
  debounced autosave) **filling the available height with a 500pt floor** and
  scrolling internally. Placeholder "Add notes…". Transparent background; subtle
  container per design.

---

## Transcript rendering (new)

The ready transcript is built as **one `AttributedString`** and shown in a single
`Text(...).textSelection(.enabled)`, so a cursor drag selects continuously across
speaker turns and ⌘C copies the selection.

Per speaker turn, the attributed content is:
- **Speaker label** — the turn's `speakerLabel` (e.g. "Speaker 1" / a resolved
  name), `.semibold`, tinted by a **stable per-speaker color** mapped from
  `speakerID` into `Tokens.avatarPalette`.
- **Timestamp** — the turn `startTime` formatted `MM:SS` (or `H:MM:SS`),
  `Font.biscottiMono`, `.inkTertiary`, rendered as a **clickable link** (custom
  URL, e.g. `biscotti://seek?t=<seconds>`).
- **Utterance** — the turn `text`, system body (~14pt), `.inkSecondary`, with
  comfortable line spacing.
- Turns are separated by paragraph spacing.

**Timestamp click** is intercepted via an `OpenURLAction` (`.environment(\.openURL,
…)`) that parses the seconds and calls `viewModel.seek(to:)` — which preserves
play/pause state (verified: it only sets `currentTime`). When audio is
unavailable (`!canPlay`), timestamps render as plain mono text (not links).

**Copy Transcript** copies a plain-text rendering of the full transcript to the
pasteboard, one block per turn:

```
<Speaker>  MM:SS
<utterance text>

<Speaker>  MM:SS
...
```

(Exact copy format can be tuned; speaker + timestamp + text, blank line between
turns, is the contract.)

**Performance caveat (accepted):** a single non-virtualized `Text` is fine for
typical meetings (tens of minutes). Very long (multi-hour) transcripts render as
one block; if that proves heavy in practice, the fallback is an NSTextView-backed
view later — out of scope now.

---

## Playback speed (new, P2)

- Add a `rate` to the playback seam: `AudioPlaybackProviding` gains a settable
  `rate` (default 1.0); `AVAudioPlayerWrapper` sets `enableRate = true` and
  applies `rate` to **all** loaded players (mic + system) so both tracks scale
  together.
- The view model exposes the current rate and a setter; the transport's speed
  `Menu` drives it. Changing rate mid-playback applies immediately and does not
  change play/pause state.
- Rate options: 0.5, 1.0, 1.25, 1.5, 2.0. Default 1.0 on load.

---

## Notes sizing

The Notes tab editor **fills the height left below the chrome, with a 500pt
floor** (`max(500, paneHeight − chromeHeight)`), and scrolls internally (the
standard `NSScrollView`-backed editor behavior). This needs **no change to
`MarkdownEditorUI`** — we drop the `maxHeight: 340` frame and give it the computed
height. See `architecture.md` for the single-outer-scroll + chrome-measurement
mechanism that yields "pinned when it fits, scrolls only when squeezed."

> Chosen after confirming the pinned `swift-markdown-engine` v0.7.0 is an
> `NSScrollView`-backed editor with **no public content-height API** (and
> `NativeTextView` is internal). "Grow the outer page" would have meant
> self-measuring the editor height (per-keystroke, drifts on headings/code
> blocks) or forking the pinned dependency — disproportionate effort for this
> redesign. Fill-the-pane gives a large editor and resolves the original
> cramped-box complaint.

---

## Reveal in Finder (new)

A "Reveal in Finder" item in the "…" menu opens Finder with **both** source
tracks selected, using the existing audio file URLs
(`store.audioFileRefs(meetingID:)` → mic/system URLs) via
`NSWorkspace.shared.activateFileViewerSelecting([...])`. Hidden or disabled when
no audio files are present on disk.

---

## States & edge cases

- **No linked calendar event** → no calendar card; meta line omits the source
  pill; the "…" menu shows "Link Calendar Event…" (Change/Unlink hidden).
- **No audio** (`!canPlay`) → transport shows "Audio not available"; speed menu
  disabled; "Reveal in Finder" hidden/disabled; transcript timestamps are plain
  (non-clickable).
- **Transcription processing** → Transcript tab shows the status/spinner; the
  Notes tab remains fully usable; the segmented control is always present.
- **Transcription failed** → Transcript tab shows the error banner + Retry.
- **Empty transcript** → "No transcript available." (Copy Transcript hidden.)
- **Multiple transcript versions** → version picker visible beside the tabs;
  selecting a version swaps the displayed transcript (existing behavior).
- **Untitled / cleared title** → keep prior title; field shows "Meeting title"
  placeholder.
- **Speaker color stability** → same `speakerID` → same palette color within a
  transcript.
- **Long meeting** → see transcript performance caveat above.

---

## Out of scope

- Export Transcript (deferred).
- Summary / Action Items tabs (not implemented; segmented control stays 2-way).
- Custom vocabulary work (blocked upstream; Phases 8/9).
- The "calendar changed → re-transcribe" prompt remains gated/hidden (Phase 9),
  as today.
- Real per-speaker identities in the transcript (diarization yields anonymous
  speaker labels; we only color them).
- Any change to the app-shell toolbar, sidebar, or meeting list.

---

## Constraints

- **Native only.** SwiftUI + stock AppKit (NSViewRepresentable wrappers we
  already use). No custom drawing/rendering, no hand-rolled controls. Where the
  design names a control, use the real Apple control or omit it if Apple
  wouldn't.
- **Apple silicon, macOS 15+.**
- **Reuse the design system** (colors, fonts, tokens, spacing grid). No new
  color or font assets.
- **Testing:** logic changes are covered by `swift test` at the view-model /
  helper level (rate setting, seek-from-timestamp parsing, copy-transcript
  formatting, speaker→color mapping, tab/version state). Pure-visual layout is
  verified by build + manual review; UI snapshot tests are not required.
- **Manual-test staleness:** this work touches `MeetingDetailUI` (BiscottiKit
  module), **not** `Packages/Transcription` or `Packages/AudioCapture`, so the
  manual-test staleness rule does **not** apply (no `ManualTestApp/Results`
  edits needed).

---

## Components touched / added

| Component | Change |
|---|---|
| `MeetingDetailUI/MeetingDetailView` | Rewrite layout: header + "…" menu, calendar card, transport, segmented tabs, transcript/notes tab content, width cap. |
| `MeetingDetailUI/MeetingDetailViewModel` | Add: playback `rate` get/set; seek-from-timestamp entry; copy-transcript text builder; tab selection state; expose menu-action hooks (reveal-in-finder, unlink, delete, re-transcribe — mostly wiring to existing methods). |
| `MeetingDetailUI/AudioPlaybackProviding` + `AVAudioPlayerWrapper` | Add settable `rate` (enableRate; apply to all players). |
| `DesignSystem/AudioTransport` | Restyle to a card; add the speed `Menu`; wire rate. |
| `DesignSystem` (new) | A transcript-attributed-string builder + selectable transcript view; an avatar / avatar-stack (colored initials) view; a source-pill view; possibly a calendar-info-card view (restyle of `CalendarContextBlock`). |
| `DesignSystem/CalendarContextBlock` | Restyle into the card + `DisclosureGroup` definition list (or superseded by a new card view). |
| `DesignSystem/VersionPicker` | Reused; repositioned beside the tabs, restyled to fit. |
| `MarkdownEditorUI/MarkdownEditor` | **No change** — used at fill height (drop the `maxHeight` frame). |
| `DataStore` read-model | Add `eventNotes` to `CalendarContextData` (+ map from `CalendarSnapshot.eventNotes`) for the Description disclosure. |

---

## Open risks

1. **Single-`Text` transcript performance** on very long transcripts — accepted;
   NSTextView fallback noted but out of scope.
2. **Two-player rate sync** — applying `rate` to both AVAudioPlayers should keep
   them aligned; verify no audible drift on hardware (minor).
3. **Pinned-chrome height on short windows** — if the pinned top region (esp. an
   expanded Description) is taller than a very short window, the content area gets
   squeezed; acceptable edge case (Description defaults collapsed).
