---
status: complete
---

# UI Design: Meeting Tags

Reconciles the design-agent notes to the real design system (`DesignSystem` module).
All values below use **real tokens**; literal hexes from the notes are replaced by the
nearest existing token, except the tag-dot palette (which is new, §6).

Key token map: `ink` (primary text), `inkSecondary` (secondary), `inkTertiary`
(tertiary/chevrons), `sage` (accent `#4E7D5C`/`#86C295`), `neutralChip` (ink-wash pill
fill `~6%`), `softSageFill` (sage `~12%`), `cardFill`/`cardStroke`/`controlShadow`
(popover surface). Mono face is **JetBrains Mono** (`biscottiMono`, `.monoBadge`,
`.kicker()`); serif is Newsreader (`biscottiSerif`). New colours must be adaptive
(`dynamicColor`); views never branch on `colorScheme`.

---

## 1 · The tag atom (`TagPill`)

A neutral pill carrying a single coloured **dot**; the **text is never coloured** — only
the dot. One component, two sizes:

| Property | `.detail` | `.compact` (list) |
|---|---|---|
| Height | 22 | 17 |
| Horizontal padding | 9 | 7 |
| Corner radius | 6 (`meetChipRadius`) | 5 |
| Dot diameter | 7 | 6 |
| Gap dot→text | 6 | 5 |
| Font | `.system(size: 11.5, weight: .medium)` | `.system(size: 10.5, weight: .medium)` |
| Fill | `Color.neutralChip` | `Color.neutralChip` |
| Text colour | `.ink` | `.ink` |
| Shape | `RoundedRectangle(cornerRadius:)` | same |
| Text truncation | single line, tail | single line, tail |

Construction mirrors `SourcePill` (a `Label`-style HStack with a leading dot circle).
`.detail` pills are interactive (hover-✕, §3); `.compact` pills are display-only.

```
●  Customer        ●  Important          ← .detail, dot = tag colour, text = ink
```

---

## 2 · Detail pane — tags row

Inserted in `MeetingDetailView.chrome` **between `header` and the calendar card**
(VStack child spacing is already `Tokens.spacingMD` = 16, so the row sits 16pt under the
meta line and 16pt above the card — matches the notes' intent without a manual margin).

- A **wrapping** horizontal flow of `.detail` `TagPill`s in alphabetical order, followed
  always by the **Add affordance** (§4). Inter-item spacing 6.
- Wrapping needs a flow layout (no native wrap on a plain `HStack`). Use a small
  `Layout`-protocol `FlowLayout` (added in `DesignSystem` if one doesn't already exist).
- The row is always present on the detail pane (even with zero tags — it shows just the
  empty-state Add affordance, which is the entry point to tagging).

```
Polarity Labs Dive                                   ⊙
Yesterday at 4:18 PM · 32 min · ▣ Google Meet
●  Customer   ●  Important   ＋ Add tag                 ← tags row
┌─ calendar info card ─────────────────────────────┐
```

---

## 3 · Detail pill — hover to remove

Follows the existing note-row hover pattern (`RecordingNotesView.NoteRowView`):

- `@State` per-pill `hovered` and `xHovered`.
- A trailing **✕** (`xmark`, `.system(size: 8.5)`) appears on the right of the pill,
  `opacity(hovered ? 1 : 0)`, colour `xHovered ? .signalRed : .inkTertiary`.
- The ✕ occupies layout space only while shown is acceptable to *reserve* (prevents text
  reflow on hover); reserve ~13pt trailing for it inside the pill, or fade it in over the
  padding. Implementer's choice — no text reflow on hover.
- Click removes the application immediately (no confirm); list + detail refresh.

---

## 4 · Add affordance (`TagAddButton`)

A ghost pill matching `.detail` dimensions (height 22, radius 6). Three states:

| State | Border | Text/glyph | Hover |
|---|---|---|---|
| **Has tags** | 1pt dashed, `ink.opacity(0.26)` | "＋ Add tag", `.inkSecondary` | fill `neutralChip`, border → `ink.opacity(0.4)` |
| **Empty** (0 tags) | 1pt dashed, `sage.opacity(0.55)` | "Add tags" + tag glyph, `.sage` | faint fill `softSageFill` |
| **Picker open** | 1pt solid, `.sage` | same as current, `.sage` | (already active) |

- Dashed border via `RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))`.
- Glyph: `tag` SF Symbol (empty state) / `plus` (has-tags). Font `.system(size: 11.5, weight: .medium)`.
- Clicking toggles the picker popover (§5). The button is the popover anchor.

---

## 5 · Tag picker popover

Built on the **`PersonPickerPopover` pattern** (search field + sectioned list + inline
add + keyboard nav). Attached to the Add button via
`.popover(isPresented:, arrowEdge: .bottom)`, toggled by a `@State pickerOpen` (same
open/close idiom as `openPopoverSpeakerID`).

**Surface:** width **260**, `VStack(spacing: 0)`, default popover chrome (the system
provides the card/shadow; no custom background needed — matches `PersonPickerPopover`).

**Contents, top → bottom:**

1. **Search / create field** — plain `TextField`, placeholder "Add or create a tag…",
   `.system(size: 13)`, padded `Tokens.spacingSM`, **auto-focused** on appear. A leading
   `magnifyingglass` (`.inkTertiary`) may prefix it. Filters the list live by
   case-insensitive **contains**.
2. `Divider()`.
3. **Kicker** "TAGS" — `.kicker()` modifier (`.monoKicker`, uppercase, tracking).
4. **Catalogue list** — alphabetical rows, each a plain `Button`:
   `HStack { dot(7) · name(.system(size:13), .ink) · Spacer() · ✓ }`. The trailing **✓**
   (`checkmark`, `.sage`) shows only when the tag is applied to this meeting. Click
   **toggles** the application (immediate, persisted) and **keeps the popover open**.
   Highlighted row uses `sage.opacity(0.15)` background (keyboard nav / hover).
5. **Create row** — shown only when trimmed query is non-empty **and** no tag matches it
   case-insensitively: a `Button` `＋ Create "<query>"` in `.sage`, full `softSageFill` on
   hover/highlight. Creates (next round-robin colour) + applies + clears the query; popover
   stays open.

**Keyboard nav** (carried from `PersonPickerPopover`): ↑/↓ move the highlight across
[catalogue rows…, create row]; ↩ commits the highlight (toggle or create); ⎋ dismisses.
Unlike the person picker, committing a catalogue row **toggles and stays open** rather
than closing.

**Empty catalogue:** field + "TAGS" kicker only; the create row appears as soon as the
user types.

---

## 6 · Tag-dot palette (new adaptive colours)

A fixed, ordered palette of **8 swatches**, each an adaptive `dynamicColor` (light = the
notes' hue; dark = a lighter/less-muddy variant for the near-black paper). Sage is
**reserved** and absent. Assigned round-robin by creation order; stored as a stable slot
index on the tag. **Dark values below are starting proposals — a human eyeballs them on
hardware** (per the dark-mode project's review practice).

| Slot | Name | Light | Dark (proposed) | Notes |
|---|---|---|---|---|
| 0 | Blue | `#3E6DA8` | `#6E9AD0` | |
| 1 | Clay | `#B5683E` | `#D08A5E` | |
| 2 | Violet | `#7A6AAE` | `#A395D0` | |
| 3 | Slate | `#6B7B86` | `#9AAAB5` | |
| 4 | Red | `#B23320` | `#E5604A` | reuse `signalRed`'s light/dark pair |
| 5 | Teal | `#2A8C7E` | `#4FB3A3` | |
| 6 | Amber | `#A8843A` | `#CBA85E` | |
| 7 | Olive | `#5E8C3A` | `#8AB861` | |

Exposed as an ordered `[Color]` (e.g. `Color.tagSwatch(slot:)` / a `TagPalette` array)
defined in `Color+Theme.swift` via `dynamicColor(light:dark:)`. Slot 4 reuses the existing
`signalRed` token pair rather than redefining it.

---

## 7 · Meeting list — third line

In `MeetingListView.meetingRow`, add a third child to the row `VStack` after the
when-line, **only when the meeting has tags** (no empty reserve):

- `HStack(spacing: 5)` of `.compact` `TagPill`s, **alphabetical**, capped at the **first 3**.
- If more than 3, a trailing `+N` in `.monoBadge` (JetBrains Mono Medium 9pt),
  `.inkSecondary`.
- Top spacing ~6 under the when-line. Bump the row `VStack` spacing only for the tagged
  rows so untagged rows keep their current height.

```
Polarity Labs Dive
Jun 11 · 32m
●  Customer   ●  Important   +1            ← compact, only when tagged
```

**Selection legibility:** the selected row already uses the system's light sage selection
wash (a tint, `accentWashStrong`), not a solid fill, so coloured dots stay legible. No
change required; just don't override the dots' colour on selection.

---

## 8 · UX rationale

- **Discoverability:** the empty-state sage "Add tags" affordance turns the otherwise-blank
  tags row into a visible call-to-action, so users find tagging without hunting.
- **Low cognitive load:** colour lives only in the dot, so a row of pills stays calm against
  the ivory paper and scans by hue; the list caps at 3 + `+N` to keep row height stable.
- **Consistency:** the picker reuses the speaker-mapping popover's exact interaction model,
  so users meet a pattern they already know; pills reuse `SourcePill`'s construction and
  the `neutralChip` fill shared by every chip in the app.
- **Progressive disclosure:** catalogue management (rename/recolour/delete) is intentionally
  absent from V1 (see functional spec §10); the picker shows only create + apply, the two
  actions a user needs in the moment.

---

## 9 · New / touched views

- **New:** `TagPill` (DesignSystem), `TagAddButton` (DesignSystem or MeetingDetailUI),
  `TagPickerPopover` (MeetingDetailUI), tag-dot palette in `Color+Theme.swift`, a
  `FlowLayout` helper if none exists.
- **Touched:** `MeetingDetailView.chrome` (insert tags row), `MeetingListView.meetingRow`
  (insert third line).

---

## 10 · Past Meetings list restyle (Phase 4 — styling only)

Repaint the middle-pane meeting list (`MeetingListView`) to the **Sage + Pressroom**
identity. This is the reconciliation of an external "design agent" style spec (which had no
codebase access and assumed hard-coded hexes, a plain-white `List`, and IBM Plex Mono) to
our real design system. **The codebase wins**; every value below is an existing adaptive
token (so dark mode is a pure swap, no `colorScheme` branching).

> **Strictly styling — no behaviour changes.** Same rows, sort, search, multi-select,
> ⌫-delete, and keyboard nav. We **keep the native `List(selection:)`** (Q1 decision).

### 10.1 Approach: native first, AppKit shim as fallback

macOS `List` selection is system-blue and there is no clean public SwiftUI API to repaint it
to a soft wash. **First attempt a pure-SwiftUI re-skin** and review it on screen before going
further:

- `.tint(.sage)` — recolours the system selection from blue to sage.
- `.scrollContentBackground(.hidden)` — drops the `List`'s own surface so the pane's ivory
  `paper` shows through (the column background is already `Tokens.contentBackground = paper`;
  the white the design spec saw was the `List` surface, **not** the column).
- `.listRowSeparator(.hidden)` / restyled separators as needed.

The implementer **must web-search to confirm the current best-practice** macOS-15 approach
for (a) recolouring/suppressing `List` selection and (b) `scrollContentBackground` before
coding — these APIs are version-sensitive.

The design **intent** is a soft sage **wash** (`accentWashStrong`, sage @14% / @16%) + a
0.5pt sage **inset ring** (never a solid fill), with the selected row's when-line turning
sage. Native `.tint` yields a more solid selection than that wash — **that gap is exactly
what the pre-CR visual review judges.** If `.tint` is "good enough," ship it. **If not, stop
and escalate** to the documented fallback: an AppKit bridge setting
`NSTableView.selectionHighlightStyle = .none` plus a `.listRowBackground` that paints
`accentWashStrong` + a `.sage.opacity(0.22/0.24)` inset ring (add a token
`accentRingStrong` mirroring the existing `recordingOutlineStrong`) keyed off `selectedIDs`.

> **Decision (visual review #1 — native rejected).** The pure-SwiftUI attempt (`.tint(.sage)`)
> did **not** recolour the selection — macOS drives `List` selection from the *system accent*,
> so the highlight stayed system-coloured (`.tint` only affected text we set ourselves). The
> background also needs its own surface (below). We are therefore implementing the **AppKit
> suppression path now**: an `NSViewRepresentable` (model on the existing `SearchFieldFocuser`)
> that walks to the enclosing `NSTableView` and sets `selectionHighlightStyle = .none`, then a
> `.listRowBackground` keyed off `selectedIDs` paints `accentWashStrong` + a 0.5pt
> `accentRingStrong` inset ring. This makes the sage wash show **regardless** of the user's
> system accent. Then back to visual review (still before CR).

> **Decision (visual review #2).** Two fixes: (a) the suppressor must attach **inside** the
> `List` (e.g. a `.background` on the List's content / a row) and walk **up** to the
> `NSTableView` — attaching it as a sibling `.background()` of the List leaves the table in a
> parallel branch, so the system blue kept drawing on top. (b) The selected-row when-line
> does **not** turn sage — sage *text* is rejected; the when-line stays `.inkSecondary` in all
> states. Colour on selection lives only in the wash + ring, never the text.

> **Decision (visual review #3 — SOLID sage, not a wash).** The selected Past Meetings row
> becomes a **solid** sage fill (`accentFill` — light `#4E7D5C` / dark `#56906A`, the deeper
> *fill* sage, NOT the bright text sage `#86C295`) with **white** text — replacing the wash +
> ring entirely (the `accentRingStrong` token is now obsolete → removed). Radius 8, horizontal
> gutter widened to **8pt** (the selection was too wide). Title → white `.medium`; when-line →
> white @72% (mono); `+N` → white @70%. On a selected row **only**, tag pills switch to a
> white @18% fill + white text, each coloured dot keeping full hue but gaining a 0.5px white
> ring so slate/teal/olive don't muddy on sage (new `TagPill(onAccent:)` flag). Default + hover
> rows, group headers, fonts, and the pane background are unchanged. Dark mode stays a token
> swap: adaptive `accentFill` + appearance-independent white. White-on-accent values live in
> new semantic tokens (`onAccent`, `onAccentMuted`, `onAccentChipFill`, `onAccentChipRing`) so
> views stay literal-free.

### 10.2 Token map (design-spec hex → our token)

| Element | Design-spec value | Our token |
|---|---|---|
| Pane background | a distinct **third** warm ivory `#F7F3EB` (NOT `paper`/`sidebarTint`) | **new token** `Color.listPaneBackground` — light `#F7F3EB`, dark **provisional** `#17140D` (eyeball in Phase 5); via `.scrollContentBackground(.hidden)` + `.background(...)` |
| Right border (list ↔ detail) | `#1A1813 @ 11%` hairline | `Color.hairline` (0.5pt; only if NavigationSplitView's own divider is insufficient) |
| Selection fill | **solid** sage — light `#4E7D5C`, dark `#56906A` | `Color.accentFill` via `.listRowBackground`: `RoundedRectangle(cornerRadius: 8)`, **8pt** horizontal inset (solid fill, no ring) |
| Selected-row text | title pure **white** `.medium`; when-line **white @72%**; `+N` **white @70%** | white opacities (`onAccent` / `onAccentMuted`), appearance-independent, `isSelected`-gated |
| Selected-row tag pills | fill white @18%, text white, dot keeps hue + 0.5px white ring | `TagPill(onAccent: isSelected)` (`onAccentChipFill` / `onAccent` / `onAccentChipRing`) |
| Row title | SF Pro 13.5 `.medium`, `label` | `.system(size: 13.5, weight: .medium)`, `.ink` (today `.body`) |
| When-line (date · duration) | mono 11.5, `label2` | `.monoMeta` (JetBrains Mono), `.inkSecondary` (today SF Pro `Tokens.metadataFont`) |
| Group / section header | mono 10.5 uppercase tracked, `label3` | `.kicker()` / `.monoKicker`, `.inkTertiary` |
| `+N` overflow | mono, `label3` | `.monoBadge`, `.inkTertiary` (today `.inkSecondary`) |
| Hover (unselected) | `#1A1813 @ 4.5%` | `Color.neutralChip`-class ink wash (as native `List` allows) |
| Tag pill (unselected) | neutral fill + coloured dot | **unchanged** — `TagPill(.compact)`, `neutralChip` + `Color.tagSwatch`; cap **3** + `+N` |
| Tag pill (selected) | white @18% fill, white text, dot keeps hue + 0.5px white ring | `TagPill(onAccent: isSelected)` — `onAccentChipFill`, `onAccent`, `onAccentChipRing` |

**Rules carried over verbatim:** colour lives **only** in the tag dot; the eight dot hues
stay full saturation on both ivory and the sage fill; **no serif anywhere in the list**;
the tag line stays hidden when a meeting has no tags. Dark mode changes nothing
structurally — the tokens above resolve per appearance and the dots are identical across
light/dark.

### 10.3 Touched view

- **Touched:** `MeetingListView` (list/scroll background, selection treatment, `meetingRow`
  title/when-line fonts, section-header styling). No data, view-model, or behaviour changes.
