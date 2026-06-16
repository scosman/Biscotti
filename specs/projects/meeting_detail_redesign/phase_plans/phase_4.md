---
status: complete
---

# Phase 4: Screen Rewrite (Assembly)

## Overview

Rewrite `MeetingDetailView` to assemble all Phase 1-3 building blocks into the
redesigned layout: pinned-chrome + scrolling-tab-content with 760pt reading cap,
serif inline-editable title, "..." overflow menu, meta line with `SourcePill`,
segmented Transcript|Notes tab bar, version picker + Copy Transcript on the
Transcript tab, and the fill-height Notes editor with 500pt floor.

This phase removes the standalone delete section (moved to the menu), replaces
`CalendarContextBlock` usage with `CalendarInfoCard`, and eliminates the old
linear layout in favor of the chrome-measured scroll model from architecture.md.

## Steps

1. **Add `Tab` enum to `MeetingDetailView`** -- `.transcript` (default),
   `.notes`. Used by `@State private var tab: Tab = .transcript`.

2. **Add `ChromeHeightKey` preference key** -- trivial `PreferenceKey` that
   captures the chrome section's measured height.

3. **Rewrite `MeetingDetailView.body`** -- Replace the existing `ScrollView` /
   `VStack` with the architecture's `GeometryReader` + `ScrollView` + chrome
   measurement + fill/floor layout:
   - Chrome VStack: header (serif title + "..." menu + meta line), calendar info
     card (when linked), audio transport card, tab bar (segmented picker +
     version picker + copy transcript).
   - Below chrome: `Divider`, then switch on `tab`:
     - `.notes` -> `MarkdownEditor` at `frame(height: fill)` (500pt floor).
     - `.transcript` -> existing `stateContent` at `frame(minHeight: fill)`.
   - 760pt max width, 32pt horizontal / 24pt top padding, ivory background.

4. **Rewrite `header`** -- Serif `TextField` (`Font.biscottiSerif(27)`,
   `tracking(-0.27)`), trailing borderless "..." `Menu`
   (`ellipsis.circle`), and meta line (`formattedDate` + duration + `SourcePill`
   when platform known, middle-dot separators in `.inkTertiary`).

5. **Build the "..." overflow menu** -- Reveal in Finder (folder), Re-transcribe
   (arrow.triangle.2.circlepath), divider, calendar Link/Change/Unlink, divider,
   Delete (trash, `.destructive`). Visibility per architecture.md conditions.

6. **Build `tabBar`** -- `HStack` with segmented `Picker` (`.fixedSize()`),
   `Spacer()`, and on Transcript tab: `VersionPicker` (when versions > 1) +
   "Copy" button (when transcript ready).

7. **Replace `calendarSection`** -- Use `CalendarInfoCard(data:onOpenInCalendar:)`
   bound to `vm.calendarCard`. Remove the old `CalendarContextBlock` usage, the
   "Link a calendar event..." prompt (now in the menu), and the standalone
   `openInCalendar` button. Keep the re-transcribe prompt (gated, currently
   hidden).

8. **Remove `deleteSection`** -- Standalone delete button is removed; delete
   now lives in the "..." menu.

9. **Remove `notesSection`** -- Notes are now inlined as a tab; the old section
   header and fixed-height container are replaced by the fill-height tab content.

10. **Update previews** -- Provide realistic previews for the redesigned screen
    showing the transcript tab.

## Tests

No new tests needed for Phase 4 -- this is a pure layout/assembly phase. All
logic (rate, seek, copy, calendar card mapping, etc.) was tested in Phases 1-3.
The visual result is verified by building the app and manual review.

Existing tests must continue passing after the view rewrite (no view model or
logic changes).
