---
status: complete
---

# Functional Spec: Record Screen Redesign

Redesign the active-recording experience — the main content pane shown while a
meeting is being captured — plus its two pieces of standard chrome (the header
record button and a sidebar "RECORDING NOW" row), and add timestamped
during-meeting notes that seed the meeting's notes field on stop.

This spec defines *behavior*. Visual values are in `ui_design.md`; component
placement and data wiring are in `architecture.md`.

## Token reconciliation (applies throughout)

The design agent named values that differ from our existing design system. We
favor the existing system:

- "alert red `#C9402B`" → reuse **`signalRed` (#B23320)** (our unified
  recording/error red).
- "IBM Plex Mono" → reuse **JetBrains Mono** (`Font.biscottiMono`).
- "Newsreader serif" → **`Font.biscottiSerif`** (already NewsreaderDisplay).
- "amber `#E8A13A` / `#996A12` / `#7D540A`" → reuse the existing unified
  **`warningOchre` (#C6891E)** token for the under-5-minutes warning, with
  background/foreground derived from it (no new amber palette). It must remain
  visually distinct from `signalRed`.

## Scope

**In scope**

1. The active-recording **content pane** (`RecordingView`) — full redesign.
2. The **header record button** recording-state restyle (lighter + bigger).
3. A sidebar **"RECORDING NOW"** section/row while recording.
4. **During-meeting notes**: a timestamped notes capture UI on the recording
   pane, kept in memory while recording.
5. On stop, **seed** the meeting's existing `notes` String with generated
   markdown (no SwiftData schema change).
6. A **meeting deep-link handler** (`biscotti://meeting/{id}?time=…`) for
   timestamp links in the meeting-detail Notes tab, via a registered URL scheme.
7. **Extract** the inline editable-title control into a shared component reused
   by the meeting-detail pane and the recording pane.
8. An on-pane **"Auto-stopping soon"** countdown section (decreasing bar + Keep
   Recording) that surfaces the existing detection-driven auto-stop countdown.

**Out of scope**

- Live transcript during recording, action items, note highlights/flags/pinning.
- Any change to the persisted data model / SwiftData schema.
- Incremental on-disk persistence of notes during recording (notes are
  in-memory until stop; see "Crash / abnormal termination").
- Changing the **idle** state of the header record button (stays sage "Record").
- Restructuring the transcript view (the `meeting_time://` jump uses the
  existing seek + tab switch only — see §6).

---

## 1. The active-recording content pane

A calm, centered, document-style surface. Replaces the current "label + giant
timer + Stop" placeholder. Shown when `route == .recording`.

### 1.1 Layout (behavioral)

A single centered column. When content is shorter than the pane it is vertically
centered; as notes accumulate the column grows and the pane scrolls from the top
(no clipping). Top-to-bottom:

0. **Auto-stopping soon** countdown section — conditional; pinned above the
   status row while an auto-stop countdown is active (§1.4).
1. Status row: **RECORDING** badge (left) · **Stop & Save** button (right).
2. **Title** (editable).
3. **Submeta** line (calendar info) — conditional.
4. **Time chips** — Elapsed (always) + Left/Over (conditional).
5. Hairline divider.
6. **Note composer**.
7. **Notes list** — only when ≥ 1 note exists.
8. The existing **system-audio warning** banner is retained (shown when
   `showSystemAudioWarning`), with its "Fix…" action opening System Settings.

### 1.2 States

| Condition | Behavior |
|---|---|
| **Has calendar event** | Title prefilled from the event; submeta shows schedule + source + "Open in calendar"; the Left/Over chip is present. |
| **Ad-hoc (no event)** | Title shows the meeting's current title (the default "Untitled Meeting"), rendered like any other title and editable in place; submeta = "Started {clock} · No calendar event"; **no Left/Over chip** (no scheduled end). |
| **No notes yet** | Composer shown; no notes list and no hint/placeholder text below it. Column vertically centered. |
| **Has notes** | Notes list rendered under the composer, **newest first**. Column grows/scrolls. |
| **≤ 5:00 remaining** | The Left chip switches to the amber warning treatment (§3). |
| **Past scheduled end** | The chip becomes an **overtime count-up** ("OVER" + `+m:ss`), amber (§3). |
| **Auto-stop countdown active** | The "Auto-stopping soon" section appears prominently at the top with a decreasing bar + Keep Recording; auto-stops at 0 (§1.4). |

Roughly half of recordings are ad-hoc; both the event and no-event cases must
look intentional.

### 1.3 Status row

- **RECORDING badge**: a `signalRed` dot with a slow radar-halo ripple, then the
  word "RECORDING" (mono, uppercase, `signalRed`). The ripple honors reduced
  motion (steady dot when reduced).
- **Stop & Save** button: the only primary control. Light treatment (white fill,
  hairline `signalRed` outline, small `signalRed` stop-square mark, deep-red
  label) — **not** a solid red fill. Tapping it ends capture and persists the
  recording and notes (existing `stop()` path), then navigates to the new
  meeting's detail (existing behavior).

### 1.4 Auto-stopping soon (countdown)

Biscotti has an **auto-stop**: when all external microphone users stop — i.e. the
meeting app releases the mic ("mic shuts down") — `AppCore` starts a short
countdown and then stops the recording. This applies to **any** in-progress
recording, however it was started (a recent `main` merge made auto-stop
mic-driven rather than detection-driven). Today that countdown surfaces **only**
as a system notification with a "Keep Recording" action; this project **also
surfaces it on the recording pane**, driven by the *same* countdown (single
source of truth).

- **Trigger:** the `.allMicUsersStopped` detector event (external mic users go
  ≥1 → 0) while a recording is in progress.
- **Duration:** **10 seconds** (`AppCore.autoStopSeconds`, already 10 after the
  merge — no change needed). The on-screen section and the notification read the
  same countdown; cancelling via either cancels both.
- **Presentation:** a dedicated, prominent section pinned at the **top of the
  column** (above the status row) while the countdown is active:
  - A heading "Auto-stopping soon" and the seconds remaining.
  - A **countdown bar that visibly decreases** from full to empty over the 10s.
  - A **Keep Recording** button.
- **Keep Recording:** cancels the countdown; the section disappears and recording
  continues. Identical effect to the notification's "Keep Recording" action.
- **On reaching 0:** the recording **auto-stops** via the existing
  `stopRecording()` path (persists, seeds notes, navigates to the meeting
  detail); the section disappears as the recording ends.
- **Navigating away:** the countdown keeps running in `AppCore`; returning to the
  pane shows the section if it's still active.
- **Motion / reduced motion:** the decreasing bar is the affordance and is always
  shown; under Reduce Motion the bar steps each second without a smooth tween (no
  other animation).

---

## 2. Title (shared editable control)

- The title is editable **in place while recording** (primary use: naming ad-hoc
  captures). Same interaction as the meeting-detail title: click to edit, select
  all, commit on Return or click-away, truncate with tail ellipsis when not
  editing, sage focus ring while editing.
- This control is **extracted into a shared component** and used by both the
  meeting-detail pane and the recording pane (see `architecture.md`). Behavior
  must remain identical to today's meeting-detail title.
- **Save semantics:** the meeting already exists in the data store while
  recording (created on start). Editing the title commits to that `Meeting`
  immediately via the existing title-save path (sets `editedTitle = true`), so
  the title is correct on the detail screen after stop and is reflected live in
  the sidebar "RECORDING NOW" row and header.
- The recording pane binds to the meeting's title and renders it exactly like
  the meeting-detail title — no special muted/"Untitled recording" treatment. The
  default "Untitled Meeting" shows as ordinary editable text. (The shared
  control's empty-state placeholder is unused here since the title is never
  empty.)

---

## 3. Time chips (Elapsed + Left/Over)

Two quiet pills replacing any progress bar/ring. Each shows a mono uppercase
**kicker** above a mono tabular **value**.

- **Elapsed** (always shown): counts up from recording start (`mm:ss`, or
  `h:mm:ss` past an hour). Driven by the existing recording elapsed clock. Never
  changes color.
- **Left** (only when a scheduled end is known): `remaining = scheduledEnd −
  now`, shown `mm:ss`. Default neutral grey, same as Elapsed.
  - **≤ 5:00 remaining:** the Left chip turns amber (`warningOchre`-derived fill,
    kicker, value) and shows a small pulsing amber dot. Reduced motion → steady
    dot.
  - **Past scheduled end (remaining ≤ 0):** the chip stays present as an
    **overtime count-up** — kicker "OVER", value `+m:ss` (time elapsed since the
    scheduled end), amber. (Chosen over hiding the chip; meetings routinely run
    long and the recorder should reflect that.)
- **Ad-hoc / no scheduled end:** render **only** the Elapsed chip.
- Both chips update once per second (same tick as Elapsed).

**Scheduled-end source:** the calendar event linked to the in-progress meeting
(its snapshot/end time). If the meeting has no linked event or no end time, treat
as no scheduled end (Elapsed-only).

---

## 4. Submeta (calendar info)

A single quiet line beneath the title.

- **Has event:** `{startTime – endTime}` · `{Platform}` · **Open in calendar**.
  - The time range and platform are mono, secondary ink; dot separators in
    tertiary ink.
  - Platform shown only when known (e.g. "Google Meet"); omitted otherwise.
  - "Open in calendar" is a sage text link with a trailing `arrow.up.right`; it
    opens the source event via the existing `CalendarDeepLink` helper. Shown only
    when an event is linked.
- **Ad-hoc:** `Started {clock} · No calendar event` (mono, secondary/tertiary
  ink). No "Open in calendar".

---

## 5. During-meeting notes

### 5.1 In-memory model

- While recording, the app holds an **in-memory ordered list** of notes. Each
  note has: stable id, **text**, and **timestamp** = the recording elapsed
  (`TimeInterval`) at the moment it was added.
- This list lives in the recording layer (`RecordingController`) so it **survives
  navigating away** from the recording pane while recording continues, and is
  available to the stop/seed path. (Placement detailed in `architecture.md`.)
- The list is reset to empty when a new recording starts.

### 5.2 Composer

- A light single-line input row with a leading `plus` glyph and placeholder
  "Add a note…". No live/counting timestamp is shown inside the composer.
- Submitting (pressing **Return** or clicking **Add note**) stamps the **current
  elapsed time**, creates a note, **prepends** it to the on-screen list
  (newest-first), and clears the field. Focus stays in the composer for rapid
  entry.
- **Empty/whitespace-only** input does nothing (no empty notes).

### 5.3 Notes list (newest-first)

- Each row: a timestamp (mono, sage, `m:ss`) + the note text (wrapping, primary
  ink). Hairline separators between rows.
- **Edit:** clicking a note's text makes it editable in place. Editing changes
  **only the content** — the timestamp is unchanged. Commit on Return or
  click-away; Escape cancels and restores the prior text. Empty result after edit
  deletes the note (see Edge cases).
- **Delete:** each row reveals a small **✕** affordance on hover; clicking it
  removes the note. (Native list swipe-to-delete is not used because the list is
  a custom layout, not a `List`.)

### 5.4 Seeding the meeting notes on stop

When the meeting ends (Stop & Save, auto-stop, or any normal stop), generate
markdown from the in-memory notes and write it into the meeting's existing
`notes` String (via the existing notes-save path). Ordering is **oldest-first**
(the reverse of the on-screen list).

Generated markdown (the `{id}` is the meeting's UUID, so each link is
self-contained and resolvable without relying on which meeting is open):

```
### Notes During Meeting

[0:42](biscotti://meeting/{id}?time=42.0)
Whatever they typed at 42s

[1:42](biscotti://meeting/{id}?time=102.2)
Whatever they typed at 1m42s
```

Rules:

- Heading: `### Notes During Meeting`. (The design's "Durring" is a typo; we use
  "During".)
- Each note: a link line `[{m:ss}](biscotti://meeting/{id}?time={seconds})` then
  the note text on the following line(s), with a blank line between notes.
- Display text in the link is the elapsed formatted `m:ss` (or `h:mm:ss` past an
  hour). The link target `{seconds}` is the raw elapsed seconds (one decimal,
  e.g. `42.0`, `102.2`); the handler tolerates integer or fractional values.
- If there are **no notes**, write nothing (don't add an empty section).
- If the meeting's `notes` already has content (not expected for a fresh
  recording, but possible), **append** the section after a blank line rather than
  overwriting.

---

## 6. `meeting_time://` link handler (meeting-detail Notes tab)

The seeded notes render in the meeting-detail **Notes** tab (the existing
`MarkdownEditor`). The link is a registered app URL scheme
`biscotti://meeting/{id}?time={seconds}`. Because the editor is the third-party
engine's `NSTextView`, the click escapes via `NSWorkspace.open`, and macOS routes
it back to the already-running app's URL handler (no visible relaunch). The
handler:

1. Resolves the meeting `{id}` and **selects it** if it isn't already the open
   meeting (route to the meetings detail for that id).
2. Switches that meeting's body to the **Transcript** tab.
3. **Seeks the audio playhead** to `{seconds}` (existing `seek(to:)` path),
   matching how tapping a transcript timestamp behaves.

There is **no** scroll-to or per-entry highlight (the transcript remains the
existing single selectable text block; the highlight-closest-entry behavior from
the original write-up is intentionally dropped to avoid restructuring the
transcript).

Edge cases:

- `{seconds}` beyond the audio/transcript length → clamp to the end (seek to
  duration).
- `{id}` not found (e.g. meeting deleted) → no-op (optionally surface nothing).
- The in-SwiftUI transcript timestamp links (`biscotti://seek?t=…`) are still
  handled in-process by `OpenURLAction` and never reach the app URL handler; the
  app handler only acts on the `meeting` host.
- Registering the `biscotti` scheme is additive; existing in-app URL behavior is
  unchanged.

---

## 7. Header record button — recording state

- **Idle (unchanged):** sage-filled "Record" button.
- **Recording (restyled):** a **lighter, bigger** button — white fill, hairline
  `signalRed` outline, whisper shadow, a leading `signalRed` dot with a **slow
  pulse**, and a compact label "REC {m:ss}" in mono deep red. A solid red fill is
  explicitly avoided (reads like an error). Tapping it navigates to the recording
  pane (does **not** stop) — unchanged behavior.
- This button is the **single place** the live timer + animation live. Reduced
  motion → steady dot.

---

## 8. Sidebar — "RECORDING NOW" section

- While recording, a **"RECORDING NOW"** section header appears in the sidebar
  (kicker style), above the existing sections.
- It contains one row for the in-progress meeting: the meeting **title** + a
  **"Recording"** subtitle in `signalRed`.
- The row has a **light-red wash background** (signalRed-tint) to signal it is
  live. **No** platform badge (no "Google Meet"), **no** timer, **no** pulsing
  dot (the live indicator already lives in the header).
- Clicking the row navigates to the recording pane (`route = .recording`). It is
  the selected/active row while the recording route is shown (selection uses a
  slightly stronger signalRed-tint).
- The row's title updates live as the user edits the title on the recording pane.
- The section disappears when recording stops.

---

## 9. Motion & accessibility

- Animations are reserved for the live state and are quiet: RECORDING badge
  radar-halo ripple, header dot slow pulse, amber warning dot pulse, composer
  caret blink (system default).
- **Honor Reduce Motion**: disable the ripple/pulses (show steady states).
  Nothing animates at rest.
- The title control, composer, Add-note, note edit/delete, and links are all
  keyboard reachable and operable.

---

## 10. Edge cases

- **Detection-started recordings:** a recording started from a detected calendar
  event behaves as "Has event" (title prefilled, schedule/remaining shown).
- **Navigating away mid-recording:** the recording continues; the in-memory notes
  persist (held in `RecordingController`); returning to the pane shows the same
  notes and the live timer.
- **Editing a note to empty:** committing an empty edit deletes that note
  (equivalent to delete).
- **Stop while a note edit/compose is in progress:** commit the in-progress
  composer/edit text first (if non-empty), then seed.
- **Crash / abnormal termination during recording:** in-memory notes are lost
  (acceptable for this project; no incremental persistence). The recording's
  audio/orphan recovery is unchanged.
- **Very long note text:** wraps; the row grows; the pane scrolls.
- **No calendar end but event linked:** treat as no scheduled end (Elapsed-only).
- **Clock/locale:** the submeta "Started {clock}" and event time range use the
  user's locale time formatting.

---

## 11. Acceptance criteria

1. Recording pane renders the new layout for both has-event and ad-hoc cases,
   vertically centered when short and scrolling-from-top when long.
2. Title is editable in place during recording using the shared control; edits
   persist to the meeting and appear in the sidebar row and header live.
3. Elapsed always shows; Left shows only with a scheduled end; ≤ 5:00 turns
   amber with a (reduced-motion-aware) pulsing dot; past end shows amber overtime
   count-up.
4. Submeta shows schedule + platform + working "Open in calendar" for events, and
   "Started … · No calendar event" for ad-hoc.
5. Notes: add (Return or button) prepends with the correct elapsed stamp; edit
   changes content only (timestamp preserved); hover-✕ deletes; empty input
   ignored.
6. On stop, the meeting's `notes` contains the `### Notes During Meeting` section
   with oldest-first entries in the exact link format
   (`biscotti://meeting/{id}?time={seconds}`); no section when there are no notes.
7. Tapping a notes `biscotti://meeting/{id}?time=…` link selects that meeting (if
   needed), switches to the Transcript tab, and seeks audio to that time (clamped
   to duration); the `biscotti` URL scheme is registered.
8. Header record button recording-state is lighter + bigger with red
   text/outline/dot and "REC {m:ss}"; idle is unchanged.
9. Sidebar shows a "RECORDING NOW" row (light-red bg, title + red "Recording"
   subtitle, no badge) that navigates to the recording pane and disappears on
   stop.
10. When external mic users stop during a recording, the "Auto-stopping soon"
    section renders with a decreasing 10s bar + Keep Recording; Keep Recording
    cancels and recording continues; reaching 0 auto-stops; the notification and
    on-screen countdowns stay in sync.
11. Reduce Motion disables all live animations; nothing animates at rest.
12. No SwiftData schema change; existing tests stay green.
