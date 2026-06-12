---
status: complete
---

# Phase 2: Meetings Two-Pane UI -- Native List, Date Grouping, Search Mode; Remove SearchUI

## Overview

Converts the interim Phase 1 Meetings screen into the final two-pane UI. Replaces the
`ScrollView`-wrapped `MeetingListView` with a native `List(selection:)` with pinned `Section`
headers, implements the 6-bucket date grouping (`groupByDateBuckets`), adds search-mode rendering
(flat results + matched-fields caption), wires `ContentUnavailableView` empty/no-results states,
and finalizes `HSplitView` pane sizing. Removes the `SearchUI` module entirely (sources, tests,
Package.swift targets, AppShellUI dependency). Migrates useful `SearchViewModelTests` assertions
into existing AppCore search tests where not already covered.

## Steps

1. **Replace `groupByEffectiveDate` with `groupByDateBuckets` in `MeetingListViewModel`.**
   New 6-bucket pure static function: Today / Yesterday / Previous 7 Days / Previous 30 Days /
   `<Month>` (current year) / `<Year>` (prior years). Boundaries use `calendar.startOfDay`.
   Remove `groupByEffectiveDate` and `startOfWeek`. Update `groupedMeetings` to call the new
   function. Add a `mode` computed property (`.browse` vs `.search`).

2. **Add search-mode properties to `MeetingListViewModel`.**
   Expose `results: [SearchHit]`, `isSearching: Bool`, `query: String` as thin passthroughs
   from `core`. Add `matchedFieldsText(_:)` (moved from SearchViewModel, nonisolated static).

3. **Rewrite `MeetingListView` to native `List(selection:)`.**
   Replace `ForEach` + `Button` + hand-rolled highlight with a `List(selection:)` binding.
   Browse mode: sectioned `ForEach` with `.tag`. Search mode: flat `ForEach` with matched-fields
   caption. Empty states via `ContentUnavailableView`. Style: `.listStyle(.inset)`.

4. **Update `AppShellView.meetingsSplit`: remove `ScrollView` wrapper, finalize HSplitView.**
   The `MeetingListView` is now a `List` (its own scrolling container); remove the wrapping
   `ScrollView`. Keep `minWidth/idealWidth/maxWidth` on list, `minWidth` on detail.

5. **Remove `SearchUI` module.**
   Delete `Sources/SearchUI/` (SearchView.swift, SearchViewModel.swift).
   Delete `Tests/SearchUITests/` (SearchViewModelTests.swift).
   Remove `SearchUI` and `SearchUITests` targets from `Package.swift`.
   Remove `SearchUI` from `AppShellUI` target dependencies.
   Remove `import SearchUI` from AppShellView.swift.
   Remove `SearchUI` from `AppShellUITests` target dependencies.

6. **Update `MeetingListViewModel+Preview` with browse/search/empty fixtures.**

7. **Migrate useful `SearchViewModelTests` assertions.**
   `matchedFieldsText` moves to `MeetingListViewModel` -- its formatting tests move to
   `MeetingListUITests`. The search-results/debounce/clear tests are already covered by
   `MeetingsSearchTests` (Phase 1 AppCore tests). Navigation tests are obsoleted by the new
   routing. The `reactivateSearch` tests are for removed code.

8. **Replace `MeetingListGroupingTests` with `groupByDateBuckets` tests.**
   Test each bucket boundary, month/year grouping, empty-bucket omission, flattened-order
   invariant, and edge cases (year boundary, mid-month).

## Tests

- `groupByDateBuckets`: today bucket, yesterday bucket, previous-7-days, previous-30-days,
  month buckets (current year), year buckets (prior year), empty-bucket omission,
  flattened-order-equals-input invariant, empty input, year-boundary edge case
- `mode` returns `.browse` when query empty, `.search` when non-empty
- `results`/`isSearching`/`query` reflect AppCore state
- `matchedFieldsText` formatting (title, people, transcript, notes, empty, combinations)
- `secondLineText` (retained from Phase 1, unchanged)
