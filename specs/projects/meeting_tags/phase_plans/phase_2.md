---
status: complete
---

# Phase 2: Display primitives & list

## Overview

Build the read-only display path for meeting tags, end to end: the adaptive
8-swatch colour palette, a `TagPill` component (two sizes), a minimal
`Layout`-based `FlowLayout`, and the compact third-line rendering in the
meeting list. No editing UI (that is Phase 3).

## Steps

1. **Tag-dot palette** in `Color+Theme.swift`: add 8 adaptive `dynamicColor`
   pairs per ui_design.md section 6. Expose `Color.tagSwatches: [Color]` and
   `Color.tagSwatch(slot:)` with modular-arithmetic index wrapping. Slot 4
   (Red) reuses the existing `signalRed` pair.

2. **`TagPill`** in new `DesignSystem/TagPill.swift`: a `View` with a `Size`
   enum (`.detail` / `.compact`) carrying dimensions from ui_design.md section 1.
   HStack of dot circle + text in `neutralChip` rounded rect. Takes `TagData`
   and reads `Color.tagSwatch(slot:)`. Detail size has an optional `onRemove`
   closure; when non-nil, renders a hover-X (opacity on hover state). Compact
   passes `nil` (display-only).

3. **`FlowLayout`** in new `DesignSystem/FlowLayout.swift`: a `Layout`-protocol
   conformance. Left-to-right placement, wrapping to the next line when a child
   exceeds the proposed width. Configurable horizontal and vertical spacing.
   Pure geometry, unit-testable.

4. **Meeting list third line** in `MeetingListView.swift`: add a third VStack
   child after the when-line, rendered only when `meeting.tags` is non-empty.
   `HStack(spacing: 5)` of `.compact` `TagPill`s (first 2, alphabetical) + a
   `+N` `Text` in `.monoBadge` / `.inkSecondary` when `tags.count > 2`. Bump
   the row VStack spacing for tagged rows only (so untagged rows keep height).

## Tests

- **`TagPaletteTests`** (in `DesignSystemTests`): verify `tagSwatches` has 8
  elements; `tagSwatch(slot:)` wraps negative and large indices correctly;
  slot 4 equals `signalRed` in both light and dark.
- **`FlowLayoutTests`** (in `DesignSystemTests`): test single-row layout when
  all children fit; wrapping to 2 rows when width is exceeded; empty children;
  spacing is applied correctly.
