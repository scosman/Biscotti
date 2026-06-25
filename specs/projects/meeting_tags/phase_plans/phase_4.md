---
status: complete
---

# Phase 4: Past Meetings List Restyle (Styling Only)

## Overview

Repaint the middle-pane meeting list (`MeetingListView`) to the Sage + Pressroom identity
per ui_design.md section 10. Strictly styling -- zero behaviour changes. Same rows, sort,
search, `List(selection:)` multi-select binding, `.onDeleteCommand`/backspace-delete,
keyboard arrow-nav, section headers, `.tag(id)`.

## Web Search Findings

### Attempt 1: Pure SwiftUI (rejected)

`.tint(.sage)` on the List does NOT reliably change the selection highlight background on
macOS. The selection highlight color is driven by the system accent color, not by `.tint`.
`.tint` only affected text we explicitly set (the when-line), not the row selection wash.
The AccentColor asset catalog entry helps when the user's system accent is "Multicolour",
but if the user picks a different system accent, it overrides the app's accent. There is no
clean public SwiftUI API to fully override this.

### Attempt 2: AppKit suppression (adopted)

Confirmed via web search:

1. **`NSTableView.selectionHighlightStyle = .none`** suppresses only the *visual drawing*
   of the selection highlight. The selection *model* is unaffected -- keyboard arrow-key
   navigation, shift/cmd multi-select, and the SwiftUI `List(selection:)` binding all
   continue to work normally. The property controls rendering, not selection state.

2. **View hierarchy traversal**: SwiftUI's `List` on macOS is backed by an `NSTableView`
   inside an `NSScrollView`. Walking up the superview chain from an invisible
   `NSViewRepresentable` placed as a `.background()` reliably finds the `NSTableView`
   (typically within ~10-15 levels). This is the same pattern used by SwiftUI-Introspect
   and by our existing `SearchFieldFocuser`.

3. **`.scrollContentBackground(.hidden)`** works reliably on macOS 13+ to remove the
   List's default white surface, letting a custom background color show through.

Sources:
- [Apple: selectionHighlightStyle](https://developer.apple.com/documentation/appkit/nstableview/1526311-selectionhighlightstyle)
- [SwiftUI-Introspect](https://github.com/siteline/SwiftUI-Introspect)
- [TIL: SwiftUI List on macOS](https://blog.eidinger.info/til-swiftui-list-on-macos)
- [SwiftUI List selection highlighting (Apple Forums)](https://developer.apple.com/forums/thread/719507)

## Implementation

### New tokens (`Color+Theme.swift`)

- **`Color.listPaneBackground`** -- a distinct third warm ivory surface (between `paper`
  and `sidebarTint`). Light `#F7F3EB` / dark provisional `#17140D` (marked for Phase 5
  eyeball). Used as the list pane background instead of `Color.paper`.

- **`Color.onAccent`** -- pure white. Primary text on a solid-accent (selected) surface.

- **`Color.onAccentMuted`** -- white @ 72%. Secondary text (when-line) on selected rows.

- **`Color.onAccentChipFill`** -- white @ 18%. Tag pill fill on selected rows.

- **`Color.onAccentChipRing`** -- white @ 50%. A 0.5px ring on coloured tag dots so
  slate/teal/olive stay legible on the solid sage fill.

### Removed tokens

- **`Color.accentRingStrong`** -- was sage @ 22% / @24%, used for the 0.5pt inset ring
  on selected rows. Removed: the solid `accentFill` selection no longer uses a ring.

### Selection: AppKit suppression + solid sage fill

- **`SelectionHighlightSuppressor`** -- a private `NSViewRepresentable` (modeled on
  `SearchFieldFocuser` and SwiftUI-Introspect's `scope: .ancestor` placement) attached
  as a `.background()` on the content **inside** the `List { ... }` closure (on
  `browseContent` / `searchContent`), so its backing `NSView` is a descendant of the
  `NSTableView`. It walks *up* the superview chain to the enclosing `NSTableView` and
  sets `selectionHighlightStyle = .none`. Fires on three triggers:
  `viewDidMoveToSuperview()`, `viewDidMoveToWindow()`, and `updateNSView` (every SwiftUI
  re-render). Because the view is inside THIS list's hierarchy, it targets the meeting
  list's table specifically -- not the detail pane's `TranscriptListView` or any other
  `NSTableView` in the window. The selection model (keyboard nav, multi-select, binding)
  is unaffected.

- **`.listRowBackground(selectionBackground(isSelected))`** on every row (browse + search):
  when selected, a `RoundedRectangle(cornerRadius: 8)` filled with `Color.accentFill`
  (solid sage -- light `#4E7D5C` / dark `#56906A`), with an **8pt** horizontal inset so
  the card doesn't feel too wide. Unselected rows get `Color.clear`. No inset ring.

- **Selected-row text colours** (gated on `isSelected`, NOT `colorScheme`):
  - Title: `.onAccent` (white), weight `.medium`.
  - When-line: `.onAccentMuted` (white @72%), `.monoMeta`.
  - `+N` overflow: `white.opacity(0.70)`, `.monoBadge`.
  - Search-row date + matches line: `.onAccentMuted`.

- **Selected-row tag pills** via `TagPill(onAccent: isSelected)`:
  - Pill fill: `onAccentChipFill` (white @18%).
  - Pill text: `onAccent` (white).
  - Coloured dot: keeps `Color.tagSwatch(slot:)` at full hue, gains a 0.5px
    `onAccentChipRing` (white @50%) ring overlay.
  - Default (`onAccent: false`) is unchanged -- `neutralChip` fill, `ink` text, no dot ring.
  - Detail pills in `MeetingDetailUI` are unaffected (they don't pass `onAccent`).

### List surface

- `.scrollContentBackground(.hidden)` + `.background(Color.listPaneBackground)` (was
  `Color.paper`).

### Unchanged from original Phase 4

- Row title font: `.system(size: 13.5, weight: .medium)`, `.ink` (unselected).
- When-line font: `.monoMeta`, `.inkSecondary` (unselected).
- Section headers: `.kicker()` + `.foregroundStyle(.inkTertiary)`.
- `+N` overflow (unselected): `.monoBadge`, `.inkTertiary`.
- Search rows: matching restyle with `.listRowBackground`.
- Row separators: `.listRowSeparator(.hidden)`.
- Default + hover rows, group headers, pane background, untagged-row behaviour (tag line
  hidden), and the selection-suppressor are unchanged.

## Tests

- All 2,211 existing tests pass (including the `colorScheme` branching ban test).
- No new logic, functions, or data paths introduced -- strictly styling.
- Visual correctness verified by human review (next step).
