---
status: complete
---

# Phase 7: Multi-select + Delete

## Overview

Migrate the meetings list from single-select (`UUID?`) to multi-select (`Set<UUID>`) so macOS native shift/cmd-click range/toggle selection works. Add a Delete key handler and confirmation alert for batch deletion. Two sub-items, intended as two commits (7a, 7b).

## Steps

### 7a: Selection model migration

1. **AppCore.swift** -- change `meetingsSelection: UUID?` to `Set<UUID>`. Update:
   - `select(_:)` -- sets a single-element set (`[meetingID]`).
   - `selectFromList(_:)` -- takes `Set<UUID>` instead of `UUID?`.
   - `autoSelectTopResult()` -- sets `[first.id]` or `[]`.
   - `stopRecording()` -- calls `select(meetingID)` (already sets a single-element set via the updated `select`).
   - `deleteMeeting` neighbor resolution -- computes neighbor, sets to `[neighbor]` or `[]`.
   - Deep-link `handleDeepLink` -- calls `select(meetingID)` (unchanged interface).

2. **MeetingListViewModel.swift** -- change `selectedID: UUID?` to `selectedIDs: Set<UUID>`. Change `select(_: UUID?)` to `select(_: Set<UUID>)`.

3. **MeetingListView.swift** -- `List(selection: Binding<Set<UUID>>)` with get/set through `viewModel.selectedIDs` / `viewModel.select(_:)`.

4. **AppShellViewModel.swift** -- change `meetingsSelection: UUID?` to `meetingsSelection: Set<UUID>`.

5. **AppShellView.swift (MeetingsSplitView)** -- detail routing:
   - `count == 1` -> `MeetingDetailView` for the single ID.
   - `count > 1` -> "N meetings selected" placeholder with a Delete button.
   - `count == 0` (empty) -> existing "No Meeting Selected" placeholder.

6. **Update all test assertions** that compare `meetingsSelection` against a bare `UUID` or `nil` to use `Set<UUID>` or `.isEmpty`.

### 7b: Delete key + confirmation + multi-delete

1. **MeetingListView.swift** -- add `.onDeleteCommand { viewModel.requestDeleteSelection() }` to trigger deletion of the current selection set.

2. **MeetingListViewModel.swift** -- add:
   - `var showDeleteConfirmation: Bool` (drives the alert).
   - `var deleteConfirmationCount: Int` (for singular/plural copy).
   - `func requestDeleteSelection()` -- guards empty selection, sets the alert state.
   - `func confirmDelete()` -- calls `core.deleteMeetings(selectedIDs)`.
   - `func cancelDelete()` -- dismisses.

3. **MeetingListView.swift** -- `.alert` / `.confirmationDialog` for delete confirmation with singular/plural text.

4. **AppCore.swift** -- add `deleteMeetings(_ ids: Set<UUID>)`:
   - Guard empty set.
   - Compute surviving neighbor via `batchNeighborID(in:removing:)` --
     scans forward from the last deleted index, then backward from the
     first, returning the first ID not in the removal set.
   - Extract shared file/DB logic into `deleteSingleMeetingInternal(meetingID:)`,
     called by both `deleteMeeting` and `deleteMeetings`.
   - Refresh summaries + search, set selection to neighbor or empty.

5. **Multi-select placeholder Delete button** -- the "N meetings selected" placeholder's Delete button triggers the same `requestDeleteSelection()` via the view model (passed down from the split view).

6. **Tests**: batch-delete of 2+ meetings, empty selection no-op, singular/plural confirmation count, existing single-delete from detail menu unchanged.

## Tests

- `testSelectMigrationSingleElement` -- `select(id)` sets `[id]`.
- `testSelectFromListSet` -- `selectFromList([a, b])` sets a multi-element set.
- `testAutoSelectTopResultSetsOneElementSet` -- search auto-select uses `[topID]`.
- `testDeleteNeighborResolutionWithSet` -- after delete, selection is `[neighbor]`.
- `testMultiSelectDetailPaneShowsPlaceholder` -- `selectedIDs.count > 1` shows placeholder (verified via view model state, not SwiftUI).
- `testDeleteMeetingsBatchRemovesAllAndSelectsNeighbor` -- batch delete of 2 meetings removes both, selects neighbor.
- `testDeleteMeetingsEmptySetIsNoOp` -- calling `deleteMeetings([])` does nothing.
- `testRequestDeleteSelectionGuardsEmpty` -- `requestDeleteSelection()` with empty selection does not show alert.
- `testDeleteConfirmationCountSingularPlural` -- count matches selected set count.
