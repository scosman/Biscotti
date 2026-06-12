---
status: complete
---

# Phase 1: AppCore Meetings State Machine + DataStore

## Overview

Introduces the `.meetings` route and centralizes all Meetings-screen state in AppCore: selection,
search query, results, debounced search, auto-select-top, select-next-on-delete, and
`neighborID`. Updates `Route` (remove `.meeting(UUID)`/`.search`, add `.meetings`), refactors
`select`/`stopRecording`/`deleteMeeting`/navigation, adds `DataStore.meetingSummaries(limit: nil)`
for uncapped fetch, and builds the bulk of unit tests. Provides a minimal interim UI in
AppShellView so the build stays green (Phase 2 finalizes the Meetings UI).

## Steps

1. **Route enum**: Remove `.meeting(UUID)` and `.search`; add `.meetings`. Update `Route.swift`.

2. **AppCore state**: Add `meetingsSelection`, `meetingsQuery`, `meetingsResults`,
   `isSearchingMeetings`, `meetingsSearchTask`. Remove `searchReturnRoute`, `summaryLimit`.
   Load summaries uncapped.

3. **AppCore navigation API**: Replace `select(_:)` with new version (clears search, sets
   selection, routes `.meetings`). Add `selectFromList(_:)` (preserves query). Add
   `showMeetings()`. Remove `presentSearch()`, `dismissSearch()`.

4. **AppCore search**: Add `setMeetingsQuery(_:)` with 300ms debounce via `scheduler` seam,
   `autoSelectTopResult()`, `cancelMeetingsSearch()`, `rerunMeetingsSearchNow()`.

5. **AppCore delete**: Refactor `deleteMeeting` to compute `neighborID`, select-next in both
   browse and search order, stay on `.meetings` instead of routing home.

6. **AppCore stopRecording**: Replace `route = .meeting(meetingID)` with `select(meetingID)`.

7. **`neighborID` static function**: Pure, unit-tested.

8. **DataStore**: Make `meetingSummaries(limit:)` accept optional `Int?` (nil = all). Update
   `AppCore.reloadSummaries` to call without limit. Remove `summaryLimit` from init.

9. **CoreFixture**: Remove `summaryLimit` parameter (default now uncapped). Update all test
   callers.

10. **MeetingListViewModel**: Update `selectedMeetingID` to read from `core.meetingsSelection`.
    Update `select` to call `core.selectFromList`. Keep `groupByEffectiveDate` (Phase 2
    replaces with 6-bucket).

11. **AppShellView interim UI**: Route `.meetings` to a basic `HSplitView` with the meeting
    list + placeholder/detail. Remove `.meeting(UUID)` and `.search` cases. Remove
    `emptyPlaceholder`. Remove search-focus/dismiss plumbing. Add minimal query sync via
    `.onChange`.

12. **AppShellViewModel**: Remove `searchViewModel` property, search-related methods. Add
    `meetingsSelection` passthrough, `selectFromList`, `showMeetings`, `setMeetingsQuery`,
    `meetingsQuery` passthrough. Remove `import SearchUI`.

13. **Update all tests**: Fix AppCoreTests, AppShellViewModelTests, MeetingListViewModelTests
    for new API. Migrate useful SearchViewModelTests assertions into AppCore search tests.
    Update MenuBarViewModelTests (select now routes `.meetings`).

## Tests

- `neighborID` table tests: after-target, before-if-last, nil-if-only, nil-if-not-found
- `select(_:)` sets route `.meetings` + `meetingsSelection` + clears query
- `selectFromList(_:)` sets selection, preserves query/route
- `showMeetings()` clears query, keeps selection, sets route `.meetings`
- `setMeetingsQuery` debounced search via FakeScheduler: results arrive after advance,
  cancellation on rapid-fire, empty clears
- `autoSelectTopResult`: keeps surviving selection, picks top otherwise, nil on empty
- `deleteMeeting` select-next in browse order (middle, last, only)
- `deleteMeeting` select-next in search order
- `stopRecording` routes `.meetings` with selection
- `meetingSummaries(limit: nil)` returns all meetings
- `meetingSummaries(limit: 2)` still caps
- MeetingListViewModel `selectedMeetingID` reads from `core.meetingsSelection`
- MeetingListViewModel `select` calls `selectFromList`
