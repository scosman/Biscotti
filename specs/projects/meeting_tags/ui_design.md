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

- `HStack(spacing: 5)` of `.compact` `TagPill`s, **alphabetical**, capped at the **first 2**.
- If more than 2, a trailing `+N` in `.monoBadge` (JetBrains Mono Medium 9pt),
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
  the ivory paper and scans by hue; the list caps at 2 + `+N` to keep row height stable.
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
