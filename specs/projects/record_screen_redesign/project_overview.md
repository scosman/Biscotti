---
status: complete
---

# Record Screen Redesign

Update the active-recording screen and related controls — both functionally and
visually. A design agent produced the detailed visual description below; it is
strong on design but tends toward "web-like" styling rather than native
SwiftUI/macOS idioms, and it sometimes names tokens/fonts that differ from our
existing design system. The goal is to honor the *spirit* of the design while
fitting our technical goals, SwiftUI patterns, and existing code (e.g. reuse
`signalRed` rather than a new "alert red," JetBrains Mono rather than IBM Plex
Mono, our `biscottiSerif` for titles).

## Technical Goals

- **Sidebar "RECORDING NOW" section** — when actively recording, show a
  "RECORDING NOW" section in the sidebar with a light-red background, the active
  recording's title, and **no "Google Meet" badge** (despite the design).
- **Header recording button — lighter "recording" state** — the top-right record
  button currently fills solid red while recording, which reads like an error.
  Change it to a lighter button: red text, recording symbol, and red outline, on
  a light fill. Also make the button **bigger** while in the recording state.
- **Recording screen — all-new design**
  - Show the meeting name, and allow editing it while in the meeting (the **same
    inline-edit control we use in the meeting pane — extract it into a shared
    control**).
  - A new, nicer design overall.
  - Show **time remaining** when we have it, including a **yellow/amber warning**
    when there are fewer than 5 minutes left.
  - Show **minimal calendar info** when we have it (see the design).
  - An **"Add Notes" section**.
- **Notes section**
  - A textbox + "Add Note" button for taking notes during a meeting. It's a list
    of notes, each with the timestamp of when it was added (when "Add Note" was
    clicked or Enter pressed).
  - You can click a past note to edit it (editing does **not** update the
    timestamp — only the content).
  - You can remove a note with a hover + X (or the native SwiftUI affordance).
- **Notes data (no persisted-model change)**
  - While recording, keep an **in-memory** list of during-meeting notes: note
    text + timestamp.
  - When the meeting ends, generate markdown from these and **seed the existing
    `notes` field** of the meeting (the current `Meeting.notes: String`) — no
    SwiftData schema change. Note the markdown uses a *different sort* (oldest
    first) than the on-screen list (newest first):

    ```
    ### Notes During Meeting

    [0:42](meeting_time://42.0)
    Whatever they typed at 42s

    [1:42](meeting_time://102.2)
    Whatever they typed at 1m42s

    etc
    ```

- **`meeting_time://` link handler** — add a handler for the notes control so
  that tapping a `meeting_time://<seconds>` link jumps to the transcript ("time
  script") panel at that timestamp and highlights the transcript entry closest to
  that time (the closest entry *before* the time, not after).

## Design from the Design Agent

> A spec for the coding agent describing the **Active Recording** content pane —
> the screen shown while a meeting is being captured. It replaces the bare-bones
> "label + giant timer + Stop" placeholder with a calm, document-style surface
> whose one real job is **let me name the recording and jot timestamped notes**,
> while keeping the live status quietly legible.
>
> This is the **chosen direction: "E · Quiet, refined"** from the explorations.
>
> Platform: SwiftUI, macOS Tahoe, light only. Identity: **F · Sage + Pressroom**
> (warm ivory paper, sage primary, alert-red recording, Newsreader serif titles,
> IBM Plex Mono for numbers/kickers). Icons are SF Symbols. Units are points.

### 0. Scope & principles

- **Only the main content pane is new.** The sidebar and top app-bar (header)
  are the app's standard chrome — with **two small state changes** noted in §7.
- **Calm over loud.** Small controls, light button weights, generous
  whitespace. No giant timer, no progress ring, no heavy filled buttons.
- **Time is present but not the hero.** Elapsed and remaining are shown as two
  quiet chips, not a centerpiece.
- **Red is reserved.** Alert-red means *recording* (and errors) only. The
  end-of-meeting countdown warning uses **amber**, never red.
- **One feature, done well: notes.** Plain timestamped text. No highlights, no
  action items, no flags, no live transcript.

### 1. Layout

Single centered column over the ivory content background.

- **Column:** `maxWidth 600`, horizontally centered, `40pt` top/bottom padding,
  `30pt` pane side padding.
- **Vertical centering that scrolls:** the column is **vertically centered when
  its content is shorter than the pane**, and as notes accumulate it grows,
  fills the pane, and then the pane **scrolls from the top** (no clipping).

Column contents, top to bottom:

1. **Status row** — RECORDING badge (left) · `Stop & Save` (right)
2. **Title** (editable)
3. **Submeta** (calendar info — conditional)
4. **Time chips** (Elapsed · Left)
5. **Hairline divider** (`0.5pt`, separator color)
6. **Note composer**
7. **Notes list** (only when ≥ 1 note exists)

### 2. States

| Condition | Effect |
|---|---|
| **Has calendar event** | Title prefilled; submeta shows schedule + source + "Open in calendar"; "Left" chip present. |
| **Ad-hoc (no event)** | Title = "Untitled recording" (muted, still editable); submeta = "Started {clock} · No calendar event"; **omit the "Left" chip**. |
| **No notes yet** | Composer shown; no notes list, no placeholder/hint text below it. Column vertically centered. |
| **Has notes** | Notes list under the composer, **most-recent-first**. Column grows / scrolls. |
| **≤ 5 min remaining** | "Left" chip switches to the amber warning treatment (§5). |

Roughly half of recordings are ad-hoc — both the event and no-event cases must
look intentional.

### 3. Components

**3.1 RECORDING badge** — red dot with a slow radar-halo ripple, then the word
RECORDING (mono, uppercase, alert color).

**3.2 Stop & Save — light button** — the only primary control. White fill,
height ~34pt, radius ~9pt; hairline alert outline @ 32%; a small alert "stop"
square mark; label "Stop & Save" in deep red. Not a solid red fill.

**3.3 Title — editable in place** — serif, ~26pt; inline-editable while
recording (renaming ad-hoc captures); pencil affordance on hover; sage focus
ring while editing; "Untitled recording" in secondary ink when empty.

**3.4 Submeta (calendar info — conditional)** — a single quiet line: has-event →
`{10:00 – 10:30 AM} · {Google Meet} · Open in calendar` (mono secondary, sage
link with trailing `arrow.up.right`); ad-hoc → `Started 10:02 AM · No calendar
event`. Dot separators in tertiary ink.

**3.5 Time chips — Elapsed + Left** — two soft pills replacing any progress bar.
Each stacks a mono kicker (ELAPSED / LEFT) + a mono tabular value. "Left" default
= neutral grey. Ad-hoc / no scheduled end → render only the Elapsed pill.

**3.6 Note composer** — a light input row. No live/counting timestamp inside it;
the timestamp is stamped when **Add note** is pressed. Leading `plus` glyph,
"Add a note…" placeholder, trailing soft sage **Add note** button.

**3.7 Notes list** — simple timestamped text entries, newest first. Each row is a
2-column grid `[timestamp] [text]`, hairline separators between rows. Timestamp
in mono sage; text in SF Pro.

### 4. Tokens

Reuse F · Sage + Pressroom tokens. Surfaces/ink unchanged; sage for links, note
timestamps, "Add note", focus ring; alert red for RECORDING + Stop & Save
outline/mark + errors only; **amber** for the "Left" chip in the last 5 minutes
(never red).

### 5. The 5-minute warning

When remaining ≤ 5:00, the **Left** chip (only) turns amber (fill, kicker,
value) and appends a small pulsing amber dot. It stays amber through the end of
the scheduled time. Do not use red. Elapsed pill never changes.

### 6. Interactions

| Action | Behavior |
|---|---|
| Edit title | Inline-editable text; commits on blur/return. Works mid-recording. |
| Add note | Stamp the current elapsed `mm:ss`, prepend the entry to the list (newest-first), clear the field. |
| Stop & Save | End capture and persist the recording + notes. |
| Open in calendar | Open the source calendar event (only when an event exists). |

### 7. Standard-chrome changes (sidebar + header)

**7.1 Header recording control — light style** — while recording, the top-right
control uses the app's light button style (white fill, alert outline, whisper
shadow, leading slow-pulse alert dot, "REC {mm:ss}" in mono deep red). This is
the single place the live timer + animation lives.

**7.2 Sidebar — recording row** — the in-progress meeting appears under a
"RECORDING NOW" section header. Its row shows the meeting title + a "Recording"
subtitle in alert color. No timer, no pulsing dot, no "Google Meet" badge on
this row. Selected-row background uses an alert tint.

### 8. Motion

Reserved for the live state and quiet: RECORDING badge radar-halo ripple +
header dot pulse; amber warning dot pulse; composer caret blink. **Honor reduced
motion** — disable all of the above (show steady states). Nothing animates at
rest.
