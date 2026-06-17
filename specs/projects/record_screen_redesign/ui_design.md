---
status: complete
---

# UI Design: Record Screen Redesign

Visual/layout contract for the recording pane and its chrome. Behavior is in
`functional_spec.md`; wiring in `architecture.md`. All values are points. Light
appearance only. Reuse `DesignSystem` (`Tokens`, `Color+Theme`, `Font+Theme`)
everywhere; new tokens are listed in §2.

The design agent's mock (identity "F · Sage + Pressroom") is the north star, but
we translate its web-ish values to the existing system: `signalRed` (#B23320) for
the alert role, JetBrains Mono (`biscottiMono`) for numbers/kickers,
`biscottiSerif` for the title, and `warningOchre` (#C6891E) for the amber warning.

## 1. Surfaces & column

- Pane background: `Tokens.contentBackground` (paper, already applied by the
  router).
- Centered single column, `maxWidth 600`, page padding **40 vertical / 32
  horizontal** (`spacingXL`).
- **Vertical-center-then-scroll:** a `ScrollView` whose content container has
  `frame(minHeight: viewportHeight)` with `Spacer(minLength: 0)` above and below
  the column. Spacers collapse once content exceeds the viewport, so a short
  screen is centered and a long one scrolls from the top (no clipping).
- Inter-section vertical rhythm: `spacingLG` (24) between major blocks; tighter
  (`spacingXS`–`spacingSM`) within a block (title→submeta = 8).

## 2. New design tokens (add to `DesignSystem`)

All derived from existing `signalRed` / `warningOchre` / `sage`, kept as named
tokens so the recording pane, header button, sidebar row, and buttons share one
definition.

| Token | Value | Used by |
|---|---|---|
| `recordingTintSoft` | `signalRed` @ 0.08 | sidebar RECORDING NOW row fill; auto-stop card wash |
| `recordingTintStrong` | `signalRed` @ 0.12 | selected sidebar recording row fill |
| `recordingOutline` | `signalRed` @ 0.32 | light Stop/REC button hairline |
| `recordingOutlineStrong` | `signalRed` @ 0.20 | selected recording row inset stroke |
| `recordingHoverFill` | `signalRed` @ 0.05 | light Stop/REC button hover |
| `warningChipFill` | `warningOchre` @ 0.16 | Left chip amber fill (≤5 min / overtime) |
| `warningChipText` | `warningOchre` | Left chip amber kicker + value |
| `softSageFill` | `sage` @ 0.12 | "Add note" button _(Keep Recording moved to `neutralChip` per Phase 4 UI review)_ |

(If `Tokens.warningBackground` already equals `warningOchre @ ~0.16`, reuse it for
`warningChipFill` rather than adding a duplicate.)

## 3. Typography roles

| Element | Font |
|---|---|
| Title | `biscottiSerif(26)`, tracking `-0.27` |
| RECORDING badge label | `biscottiMono(12.5, .medium)`, uppercase, tracking ~1.5, `signalRed` |
| Submeta (time/platform) | `biscottiMono(12.5)` (`.monoMeta`), `inkSecondary` |
| "Open in calendar" link | `.body` / system, `sage`, trailing `arrow.up.right` |
| Time-chip kicker | `biscottiMono(9.5, .medium)`, uppercase, tracking ~1.4, `inkTertiary` |
| Time-chip value | `biscottiMono(14, .medium)` tabular, `ink` |
| Note timestamp | `biscottiMono(11.5)`, `sage` |
| Note text | system `13.5`, `ink`, line spacing ~3 |
| Composer placeholder | system `13.5`, `inkTertiary` |
| "Add note" label | system `13`, weight 600, `sage` |
| "Keep Recording" label | system `13`, weight 600, `ink` _(Phase 4 UI review: neutral grey, not sage)_ |
| Header REC label | `biscottiMono(12.5, .medium)`, `signalRed` |
| Sidebar "RECORDING NOW" kicker | `.kicker()` tinted `signalRed` |
| Sidebar row title / subtitle | `.body` `ink` / `.monoMeta` `signalRed` |

## 4. Recording pane — section specs

### 4.0 Auto-stopping soon (conditional, top)

A prominent full-width card, only while a countdown is active.

- Container: `cardFill` over a `recordingTintSoft` wash, `cardStroke` hairline +
  a `recordingOutline` 0.5pt border, `cardRadius` (12), padding `spacingMD`.
- Row 1: `"Auto-stopping soon"` (system 15, semibold, `ink`) · `Spacer` · `"{n}s"`
  (`biscottiMono(14, .medium)`, `signalRed`).
- Row 2: **countdown bar** — a `Capsule` track (`neutralChip`, height 8) with a
  `signalRed` `Capsule` fill whose width = `remaining / total`. The fill width
  **decreases each second**; animate width linearly (`.linear(duration: 1)`)
  unless Reduce Motion (then step, no tween).
- Row 3 (right-aligned): **Keep Recording** button — `neutralChip` fill,
  `hairline` 0.5pt border, `ink` label weight 600, `buttonRadius`. Right-aligned
  (trailing edge) within the card. _(Phase 4 UI review: changed from sage-green
  to neutral grey -- green-on-red read poorly; right-aligned to balance the card.)_

### 4.1 Status row

`HStack`: RECORDING badge (leading) · `Spacer` · Stop & Save (trailing).

- **RECORDING badge**: `Circle` 11pt `signalRed` + 1–2 expanding ring ripples
  (stroke `signalRed`, scale ~0.6→2.6, fade to 0, ~2s loop) behind it; then the
  label. Reduce Motion → steady dot, no ripple.
- **Stop & Save** (light button style, see §6): white `cardFill`, height 34,
  radius ~9, horizontal padding 15, `recordingOutline` 0.5pt border, whisper
  shadow; leading 9pt `signalRed` rounded-square mark (SF `stop.fill` tinted
  `signalRed` is fine); label "Stop & Save" (system 13, weight ~550, `signalRed`).
  Hover fill `recordingHoverFill`.

### 4.2 Title

The shared `EditableMeetingTitle` control (see `architecture.md`) with
`biscottiSerif(26)`. The title binds to the meeting's title and renders like the
meeting-detail title (the default "Untitled Meeting" shows as ordinary `ink`
text — no muted/placeholder treatment). Sage focus ring + white fill while
editing; tail-truncation + pencil-on-hover affordance when not editing (identical
interaction to the meeting-detail title).

### 4.3 Submeta (8pt below title)

Single line, dot-separated (`·` in `inkTertiary`):

- Has event: `{10:00 – 10:30 AM}` · `{Platform}` · `Open in calendar`. Time range
  + platform mono `inkSecondary`; "Open in calendar" `sage` with trailing
  `arrow.up.right`.
- Ad-hoc: `Started {clock}` · `No calendar event` (mono, `inkSecondary` /
  `inkTertiary`). No link.

### 4.4 Time chips

`HStack(spacing: 9)` of soft pills. Each pill: height 34, radius 10, padding
`0 14`, fill `neutralChip`; an `HStack(spacing: 6)` of kicker beside value
(side-by-side layout, e.g. "ELAPSED 2:34"). _Originally specified as a
`VStack` (kicker over value); changed to `HStack` per Phase 3 UI review._

- **ELAPSED** — always; kicker `inkTertiary`, value `ink`. Never recolors.
- **LEFT** — only with a scheduled end; default same neutral treatment.
  - **≤ 5:00:** fill → `warningChipFill`; kicker + value → `warningChipText`;
    append a 6pt pulsing `warningOchre` dot (with a faint ring). Reduce Motion →
    steady dot.
  - **Overtime (≤ 0):** kicker "OVER", value `+m:ss`, same amber treatment.
- Ad-hoc: render only the ELAPSED pill.

### 4.5 Hairline divider

`InsetDivider` / 0.5pt `hairline`, `spacingMD` vertical margin, before the
composer.

### 4.6 Note composer

A light input row: `cardFill`, radius 11, `cardStroke` 0.5pt, padding ~11.
Leading `plus` glyph (`inkTertiary`); placeholder "Add a note…"; trailing **Add
note** button (`softSageFill`, `sage` label weight 600, height 30,
`buttonRadius`). Focus/hover: border shifts to `sage` @ ~0.4.

### 4.7 Notes list (newest-first)

Shown only when ≥ 1 note. Each row: a 2-column layout `[timestamp 46pt] [text]`,
gap 14, vertical padding ~13, with a 0.5pt `hairline` separator between rows
(none after the last).

- Timestamp: `biscottiMono(11.5)`, `sage`, `m:ss`.
- Text: system 13.5, `ink`, wrapping.
- **Hover affordance:** a trailing `xmark` (SF `xmark`, `inkTertiary` →
  `signalRed` on hover) appears on row hover to delete.
- **Edit:** clicking the text swaps it for an inline `TextField` (same metrics);
  sage focus ring; commit on Return/click-away; Esc cancels.

### 4.8 System-audio banner

Unchanged `Banner(style: .warning)` with "Fix…", `maxWidth 400`, placed at the
bottom of the column (retained from today).

## 5. Header record button

In the toolbar `ToolbarItemGroup`, to the right of the search field.

- **Idle (unchanged):** `ToolbarRecordButtonStyle(fill: .sage)`, `record.circle`
  + "Record".
- **Recording (new light style, bigger):**
  - White `cardFill`, `recordingOutline` 0.5pt border, whisper shadow.
  - Leading 8pt `signalRed` dot with a **slow pulse** (~1.6s); Reduce Motion →
    steady.
  - Label "REC {m:ss}" in `biscottiMono(12.5,.medium)`, `signalRed`.
  - **Larger** than idle: increase horizontal padding (~12→~16) and height so it
    reads as the active, tappable status (the single live timer + animation).

## 6. Light button style

Stop & Save and the recording-state header button share a **light alert button**
treatment (white fill, `recordingOutline` hairline, whisper shadow, `signalRed`
content, `recordingHoverFill` on hover). Factor this into a reusable
`ButtonStyle` (name in `architecture.md`) so both stay consistent.

## 7. Sidebar — RECORDING NOW

Placed **above the Upcoming section** (after the Home/Past Meetings rows and
divider); only while recording. _(Phase 8 review: moved from above Home to above
Upcoming to match standard sidebar section placement.)_

- Section kicker `"RECORDING NOW"` (`.kicker()`, `inkSecondary`), `spacingMD`
  leading / `spacingXS` bottom (matching the UPCOMING section). _(Phase 8
  review: uses standard section-title color, not `signalRed`.)_
- One row (two-line, like `UpcomingEventRow`): title (`.body`, `ink`, 1 line) +
  "Recording" subtitle (`.monoMeta`, `signalRed`). **No** platform badge, timer,
  or dot.
- Row background: `recordingTintSoft` always (live); when `route == .recording`,
  `recordingTintStrong` fill + a 0.5pt inset `recordingOutlineStrong` stroke,
  `RoundedRectangle(cornerRadius: 4)` (matching other sidebar rows).
- A `Divider` below the section (matching UPCOMING).

## 8. Motion summary

| Element | Motion | Reduce Motion |
|---|---|---|
| RECORDING badge | radar-halo ripple ~2s | steady dot |
| Header REC dot | slow pulse ~1.6s | steady dot |
| LEFT amber dot | gentle pulse ~1.7s | steady dot |
| Auto-stop bar | linear width decrease (1s steps) | stepped, no tween |
| Composer caret | system blink | system |

Nothing animates at rest; no decorative/infinite animation on content.
