---
status: complete
---

# UI Design: Markdown (Notes Editor)

The only user-facing surface in this project is the **meeting notes editor** inside
`MeetingDetailView`. No new screens or navigation. This doc covers the editor's layout, visual
styling, and interaction.

## Placement

Unchanged structurally from today: the notes block sits between the audio transport and the delete
section in the meeting-detail `ScrollView` (`MeetingDetailView.swift:281–297`).

```
┌─ Meeting Detail (page ScrollView) ──────────────┐
│  Title / date                                    │
│  ── divider ──                                   │
│  Calendar context                                │
│  Audio transport                                 │
│  ── divider ──                                   │
│  Notes                          ← section header │
│  ┌────────────────────────────────────────────┐ │
│  │  ## Agenda          ← '##' dimmed while editing│ │  ← bounded markdown
│  │  Ship Q3 plan        ← styled italic, H2     │ │     editor box
│  │  - [ ] follow up with Sam                   │ │     (min ~120 / max ~340pt,
│  │  - [x] send recap                           │ │      scrolls internally)
│  │                                             │ │
│  └────────────────────────────────────────────┘ │
│  ── divider ──                                   │
│  Delete                                          │
│  Transcript …                                    │
└──────────────────────────────────────────────────┘
```

## Layout

- **Section header**: keep the existing "Notes" label — `Tokens.sectionHeaderFont` (mono kicker), `Tokens.secondaryText`.
- **Editor box (bounded inline)**:
  - `minHeight ≈ 120`, `maxHeight ≈ 340` (final values tuned on a real run). Comfortably bigger than today's `minHeight: 60` since markdown notes are a richer surface.
  - The editor (an `NSScrollView`) scrolls **internally** when content exceeds the box; the page scroll handles everything else. Nested scroll is bounded and predictable.
  - **Container affordance**: a subtle rounded rectangle (`Color.cardStroke` hairline, ~8pt radius) around the editor so the editable region is discoverable against the `paper` background. Light, not a heavy input box. (Tunable; can drop to borderless if it feels heavy.)
  - **Inner padding**: small text insets (~8pt) so text/markers don't sit flush against the border.
  - Editor background is **clear** — the warm `paper`/card surface shows through.
- **Overscroll**: the engine's default overscroll (up to 450pt of trailing whitespace) is wrong for a small box — reduce it to a few points so the bounded box doesn't show a large empty tail.

## Visual styling (F Sage)

| Element | Treatment |
|---|---|
| Body text + caret | `ink` |
| **Syntax markers** (`*`, `**`, `~~`, `#`, `>`, list bullets) | **dimmed ink** (`inkSecondary` — clearly lighter than body), visible while the caret is on the token (hide-on-blur) |
| Headings | enlarged via the engine's level multipliers off the base notes size (H1≈2.0×, H2≈1.5×, H3≈1.17×); the `#` markers dimmed while editing |
| Italic / bold / strikethrough spans | rendered styled; their markers dimmed and visible while editing the span, hidden when caret moves away |
| Links | `sage`, underlined per engine default |
| Inline / fenced code | monospaced (system mono), not colorized |
| Task checkboxes | native rendered glyph; completed-item text struck through (`inkSecondary`) |
| Tables | engine default grid, ink text on clear background |
| Find matches | `accentWashStrong` (sage wash); focused match a stronger sage |
| Placeholder | "Add notes…" in dimmed ink, shown only while empty |

Base body font: the app's **system body font** at the notes size (≈14pt — tuned), so headings scale
off it. (Serif is reserved for headlines, mono for metadata; notes prose stays system body.)

## Interaction

- **Type to edit, live styling** — markers render as you type; while the caret is on a token its markers are visible & dimmed, and hide when the caret moves away (standard live-preview behavior). Spans style in place.
- **Task checkboxes** are clickable to toggle `[ ]` ⇄ `[x]`.
- **Lists** auto-continue on Return and indent/outdent with Tab/Shift-Tab.
- **Auto-close bracket pairs is disabled** for notes (prose-friendly — typing `(` should not auto-insert `)`).
- **Standard editing**: selection, copy/cut/paste (paste = plain text), system **undo/redo** (scoped per meeting), **spell-check/grammar** squiggles (on), in-document **Find** (⌘F).
- **Focus**: the box takes focus on click; caret is ink. No custom focus ring beyond the system default.

## States

- **Empty** → placeholder "Add notes…"; first keystroke clears it. Saved value `""`.
- **Legacy plain-text notes** → render as a normal paragraph; no reformatting.
- **Long notes** → internal scroll within the bounded box; autosave still debounced.
- **Read-only** (not used by notes, but supported) → live-rendered, caret-less.

## Accessibility

The editor is a native `NSTextView`, so it inherits macOS text-editing accessibility (VoiceOver text
navigation, system text size honoring via the base font). The "Notes" header labels the region.

## Deferred alternatives (considered, not chosen)

- **Auto-grow-to-content** (editor expands, single page scroll): nicer but needs intrinsic-height bridging from the engine's `NSScrollView`. Deferred.
- **Dedicated notes pane** (notes as a primary, separately-scrolling region): larger restructure; revisit if notes become a headline feature.
