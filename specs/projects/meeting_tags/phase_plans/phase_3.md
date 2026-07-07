---
status: complete
---

# Phase 3: Detail-pane editing

## Overview

Adds the tag editing experience to the meeting detail pane: the `TagAddButton` (three visual states), the `TagPickerPopover` with keyboard navigation, pure `computeTagPickerResult` function (unit tested), `MeetingDetailViewModel` tag methods (`toggleTag`, `createAndApply`, `removeTag`), and the wrapping tags row inserted into `MeetingDetailView.chrome`.

## Steps

1. **`TagPickerLogic.swift`** (new, `MeetingDetailUI/`) -- pure function `computeTagPickerResult(catalogue:applied:query:) -> TagPickerResult` mirroring `computePersonPickerResult`. Returns filtered rows (each with `isApplied` flag) and optional `createOption`.

2. **`TagAddButton.swift`** (new, `MeetingDetailUI/`) -- ghost pill with three states (has-tags, empty, picker-open). Dashed border via `StrokeStyle(dash:)`, sage/neutral styling per ui_design.md SS4.

3. **`TagPickerPopover.swift`** (new, `MeetingDetailUI/`) -- popover anchored to `TagAddButton`. Search field (auto-focused) + "TAGS" kicker + catalogue rows (dot + name + checkmark if applied) + create row. Keyboard nav (up/down/return/escape). Toggle keeps popover open (differs from person picker).

4. **`MeetingDetailViewModel`** -- add `catalogueTags: [TagData]` state, load in `refreshData()`. Add `toggleTag`, `createAndApply`, `removeTag` methods (each calls actor, then `refreshData()` + `core.reloadSummaries()`). Expose `appliedTagIDs` computed set.

5. **`MeetingDetailView.chrome`** -- insert tags row (FlowLayout of detail TagPills with onRemove + TagAddButton with popover) between `header` and `reTranscribePrompt`/calendar card.

6. **`TagPickerLogicTests.swift`** (new) -- unit tests for `computeTagPickerResult`: contains-filter, `isApplied` flags, `createOption` visibility (non-nil iff trimmed query non-empty AND no catalogue tag equals it case-insensitively), nil for whitespace-only.

## Tests

- `testContainsFilter`: query "cus" matches "Customer" but not "Important"
- `testCaseInsensitiveFilter`: query "CUS" matches "customer"
- `testIsAppliedFlags`: applied tags flagged correctly
- `testCreateOptionShownForNewName`: query "NewTag" with no match -> createOption = "NewTag"
- `testCreateOptionHiddenForExactMatch`: query "Customer" with existing "Customer" -> createOption = nil
- `testCreateOptionCaseInsensitiveMatch`: query "customer" with existing "Customer" -> createOption = nil
- `testCreateOptionNilForEmptyQuery`: empty query -> createOption = nil
- `testCreateOptionNilForWhitespaceOnly`: whitespace query -> createOption = nil
- `testCreateOptionTrimmed`: query "  NewTag  " -> createOption = "NewTag"
- `testAlphabeticalOrdering`: rows sorted alphabetically
- `testEmptyCatalogue`: empty catalogue with query -> createOption shown
