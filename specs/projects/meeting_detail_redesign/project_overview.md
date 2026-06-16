---
status: complete
---

# Update Meeting Screen

Update the single **meeting detail view** — a past meeting with a recording and
transcript. This is the trailing/detail pane of the meetings layout
(`MeetingDetailView` in `Packages/BiscottiKit/Sources/MeetingDetailUI`).

A design agent produced a visual-design spec (reproduced below). It owns visual
design; **we own code quality, functionality, and consistency.** The job is to
balance the *spirit* of that design with our technical goals — not to follow it
literally where it conflicts with native macOS conventions or our existing code.

## Technical goals

- Continue to use very native SwiftUI controls, and Apple HIG–compliant app
  design. A "use control X" below doesn't mean "use control X even though Apple
  never would."
- We want more style, but using the mechanisms Apple provides/uses: highlight
  colors, background colors, etc. Not getting into building custom controls,
  custom rendering, etc.
- Ask questions when the spec below conflicts with "what Apple would do in a
  native macOS app."
- In some areas, we went into more detail in code than the design spec did. So
  when to follow spec vs. when to follow existing code is not trivial. Expect
  lots of confirmations/questions during the speccing phase to get the right
  answers in, for any conflicts.

## Notes / requirements

- **Playback speed is P2.** Do it if easy, but not if not.
- **Clicking a timestamp in the transcript** should jump the playback control to
  that time. It should preserve playing state (if playing, keep playing; if
  paused, stay paused).
- **The transcript must be copyable** — either by dragging a cursor over a
  section of text and using the usual copy keyboard shortcut, or a copy-all
  button (design TBD).
- **The notes section should grow**, making the whole screen grow/scroll. Not
  the current window-bounded solution.
- **Colors: use our shared color palette.** You shouldn't need to define new
  colors. (Our palette is `Color.paper`/`.ink`/`.sage`/`.inkSecondary`/… in
  `DesignSystem`; it already maps to the design's `Pal` tokens.)

---

## Design reference (from design agent)

> The agent does visual design; we own code quality and functionality and
> consistency. Below is its spec verbatim, as a reference for the *spirit* of the
> redesign.

### Meeting Detail Pane — visual identity

The trailing column of the meetings layout, showing **one past meeting**. Visual
identity: **F · Sage + Pressroom type** — warm ivory paper, sage accent,
Newsreader serif title, monospace for every timestamp. All measurements in points.

### Design tokens (proposed by the design agent)

```
accent   = sage  (#4E7D5C)
label    = warm near-black ink (#1A1813)
label2   = ink @ 54%
label3   = ink @ 34%
content  = ivory paper (#FBFAF5)   // pane bg
card     = white
cardBdr  = warm dark @ 10%
sep      = ink @ 11%
fill     = ink @ 6%                 // soft control fill
```

> NOTE (ours): these map onto our existing `DesignSystem` palette
> (`.sage`, `.ink`, `.inkSecondary`, `.inkTertiary`, `.paper`, `.cardStroke`,
> `.hairline`, `.neutralChip`). We use the existing palette, not a new `Pal` enum.

**Fonts — three roles:** Serif display (Newsreader, medium) for the H1 title and
nothing else; Monospace (tabular figures) for every timestamp, duration, date,
URL, and uppercase kicker label; System (SF Pro) for all other body text,
buttons, menus, transcript prose.

> NOTE (ours): our bundled monospace is **JetBrains Mono** (via
> `Font.biscottiMono`), not IBM Plex Mono. Serif is **NewsreaderDisplay** (via
> `Font.biscottiSerif`).

Pane background ivory, content left-aligned in a column **capped at 760pt max
width**, insets ~`top 24, leading/trailing 30`.

### 1 · Toolbar
A single trailing item — a **new recording** button (`record.circle`, sage
tint). No back/forward, no share. The title is **not** in the toolbar (it lives
in the body as a serif H1).

### 2 · Header row — title + overflow menu
- **Title** — Newsreader medium ~27pt, near-black ink, tight tracking.
- **Meta line** — monospace ~12.5pt, middle-dot separators:
  relative date/time · duration · **source pill** (e.g.
  `Label("Google Meet", systemImage: "video.fill")` as a sage-tinted capsule).
- **Trailing "…" overflow menu** (borderless `Menu`, `ellipsis.circle`):
  Rename… · Reveal in Finder · Export Transcript… · — · Unlink Calendar Event ·
  — · Delete Meeting… (`role: .destructive` → native red).
  Reveal in Finder selects **both** source tracks (mic + system) in Finder.

### 3 · Calendar info card
A `GroupBox`-style rounded card (white fill, hairline stroke). Inside:
- **Row A** — overlapping attendee avatar stack + attendee summary (organizer
  bolded) + a soft "Open in Calendar" secondary button.
- **Divider.**
- **Row B** — a stock **`DisclosureGroup`** labeled "Description": collapsed
  shows triangle + "Description" + one truncated preview line of the event
  notes; expanded shows a definition list (`Grid`) with monospace kicker labels:
  **WHEN** (date/time range), **WHERE** (conference icon + platform + monospace
  URL), **DESCRIPTION** (wrapped notes), **INVITED** (attendee names).
  (Named "Description" — not "Notes" — to avoid colliding with the Notes tab.)

### 4 · Audio player
A QuickTime-style transport bar in a rounded card: play/pause (circular, fills
on hover) · elapsed (monospace) · native `Slider` scrubber (sage tint) · total
(monospace) · **speed control** (Menu or click-to-cycle: 0.5 / 1 / 1.25 / 1.5 /
2×). No download button — file access is only via *Reveal in Finder*. Two tracks
(mic + system) present as one timeline.

### 5 · Segmented control — Transcript / Notes
A native `.segmented` `Picker` with **only two segments** (Transcript, Notes),
left-aligned and content-width. (Summary / Action Items intentionally omitted.)

### 6 · Tab content
- **Transcript** — `LazyVStack` of speaker turns; each turn = avatar circle +
  speaker name (semibold) + monospace timestamp + selectable utterance prose.
- **Notes** — a `TextEditor`/markdown editor bound to the note text, transparent
  background.

### State & behaviors
- `DisclosureGroup` animates with the system default.
- The whole pane scrolls as one `ScrollView`; the toolbar stays pinned.
- Delete → `.confirmationDialog` with a destructive button.
- Everything monospaced (times, dates, URL, kicker labels) uses **tabular
  figures** so digits don't jitter during playback.

### Open question (from the design agent)
The **speed control** is spec'd as a `Menu`. It could instead be a click-to-cycle
button (1× → 1.25× → 1.5× …) that advances an index.
