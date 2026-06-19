---
status: complete
---

# Phase 5: AppCore behavior fixes (search top-select + upcoming cap)

## Overview

Two targeted behavior changes from human review feedback:
1. **Search always selects the top result** when results load, instead of preserving a previously-selected meeting that happens to still be in the results. This eliminates the confusing state where the user can see a selection below the fold in the list.
2. **Raise the upcoming meetings cap from 5 to 6** in both the sidebar (`AppShellViewModel`) and home screen (`HomeViewModel`).

## Steps

### Item A: Search auto-selects top result

1. **`AppCore.swift`** -- modify `autoSelectTopResult()` to always set `meetingsSelection = meetingsResults.first?.id` (remove the early-return that preserves a surviving selection).

2. **`MeetingsSearchTests.swift`** -- update and add tests:
   - Update `keepsCurrentSelectionInResults` test: now expects the top result to be selected even when the current selection survives in results. Rename to reflect new behavior.
   - Verify: results load -> top selected.
   - Verify: results change -> selection moves to new top.
   - Verify: empty results -> no selection (already covered, kept).

### Item B: Upcoming meetings cap to 6

3. **`AppShellViewModel.swift`** -- change `upcomingEvents` from `prefix(5)` to `prefix(6)`.

4. **`HomeViewModel.swift`** -- change `upcomingPreview` from `prefix(5)` to `prefix(6)`.

5. **Update existing tests:**
   - `AppShellViewModelTests.swift`: change the "upcomingEvents capped at 5" test to assert cap of 6.
   - `HomeViewModelTests.swift`: change the "upcomingPreview returns first 5 events" test to assert cap of 6.

## Tests

- `autoSelectsTopResult`: search with no selection -> top result auto-selected (existing, kept).
- `searchAlwaysSelectsTopResult`: search when current selection survives in results -> still selects top result (replaces the old "keeps current selection" test).
- `searchResultsChangeSelectsNewTop`: search query refines -> selection moves to new top result.
- `noResultsSetsNilSelection`: empty results -> nil selection (existing, kept).
- `upcomingEventsCappedAt6` (AppShellViewModel): >6 candidates -> exactly 6 surfaced.
- `upcomingPreviewCappedAt6` (HomeViewModel): >6 candidates -> exactly 6 surfaced.
