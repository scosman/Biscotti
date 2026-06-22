---
status: complete
---

# Phase 13: Speaker mapping sheet — filterable person picker

## Overview

Replace the native `Menu` dropdown on each speaker row in `SpeakerMappingSheet` with a filterable person-picker popover. The new control opens a popover anchored to the pill, with an auto-focused search field, pinned Unassigned action, sectioned Invitees/All People results (capped at 15 person rows), an inline "Add" action, a `+ N more` status row, and keyboard navigation. The old separate "Add person..." text-field popover is removed.

The core windowing/filtering/add-option computation is extracted into a pure, unit-tested helper function, independent of any view code.

## Steps

### 1. Create `PersonPickerLogic.swift` — pure windowing/filter helper

New file at `Packages/BiscottiKit/Sources/MeetingDetailUI/PersonPickerLogic.swift`.

```swift
/// Result of the person-picker windowing computation.
public struct PersonPickerResult: Sendable, Equatable {
    public let invitees: [PersonData]
    public let allPeople: [PersonData]
    public let hiddenCount: Int
    public let addOption: String?
}

/// Pure function: given the full invitee and all-people lists, a search
/// query, and a display limit, compute the capped sections, hidden count,
/// and optional "Add" label.
public func computePersonPickerResult(
    invitees: [PersonData],
    allPeople: [PersonData],
    query: String,
    limit: Int = 15
) -> PersonPickerResult
```

Logic:
- Trim query. If non-empty, filter both lists by case-insensitive substring match on `name` OR `email`.
- Fill up to `limit` rows: invitees first (up to `limit`), then allPeople with remaining capacity.
- `hiddenCount = totalMatching - shown`.
- `addOption`: non-nil when trimmed query is non-empty AND no person in the *full* (unwindowed) matching set has a name that equals the query case-insensitively. Value is the trimmed query string.

### 2. Rewrite `SpeakerMappingSheet.swift` — popover-based picker

Replace the `assignmentMenu(for:)` `Menu` and its content/label, plus the separate `addPersonPopover`, with a new popover-based person picker.

- **Closed state**: keep the existing pill (`assignmentMenuLabel`), but change it from a `Menu` label to a `Button` that toggles a `@State` dict tracking which speaker's popover is open.
- **Popover content** (`personPickerPopover(for row:)`):
  - `TextField("Filter people...", ...)` with `@FocusState` auto-focus.
  - Pinned "Unassigned" button (disabled when `row.assigned == nil`).
  - Invitees section (if non-empty): section header "INVITEES", person rows.
  - All People section (if non-empty): section header "ALL PEOPLE" (renamed from "People").
  - "Add \"<query>\"" action (when `addOption` is non-nil).
  - Status row `+ N more — type to filter` (when `hiddenCount > 0`).
- Remove `addPersonText`, `showingAddField`, and the `addPersonPopover` helper entirely.
- Selecting a person row calls `onAssign`, Add calls `onAddPerson`, Unassigned calls `onUnassign` — all close the popover.
- Keyboard: ↑/↓ moves a highlight index through selectable items, Return commits highlighted (or Add if nothing highlighted and Add is available), Esc closes.

### 3. Remove the old `addPersonPopover` and related state

The `@State private var addPersonText: [Int: String]` and `@State private var showingAddField: Int?` are removed. The `.popover` modifier for the old add-person flow is removed. The `addPersonPopover(speakerID:)` method is deleted.

### 4. Add unit tests for `PersonPickerLogic`

New test file or add to existing `SpeakerMappingTests.swift`. Test cases:

- `test15InviteesOnly`: ≥15 invitees → shows 15 invitees, 0 allPeople, correct hiddenCount.
- `testInviteesPlusAllPeopleFillTo15`: e.g. 5 invitees, 20 allPeople → 5 invitees + 10 allPeople = 15, hiddenCount = 10.
- `testZeroInvitees15AllPeople`: 0 invitees, 20 allPeople → 15 allPeople, hiddenCount = 5.
- `testFilterNameCaseInsensitive`: query matches by name substring, case-insensitively.
- `testFilterEmailMatch`: query matches by email substring.
- `testFilterAcrossBothSections`: filter hits in both invitees and allPeople, cap to 15.
- `testAddOptionShownForNonEmptyQuery`: non-empty query with no exact name match → addOption present.
- `testAddOptionSuppressedOnExactMatch`: query exactly matches a person name (case-insensitive) → addOption nil.
- `testAddOptionSuppressedForEmptyQuery`: empty/whitespace query → addOption nil.
- `testHiddenCountZeroWhenAllFit`: small lists that fit within 15 → hiddenCount 0.
- `testSectionRenameFromPeopleToAllPeople`: (structural — verified by the section header in the view, but the helper uses the label "All People" implicitly via the two-section split).

## Tests

- `testWindowing15Invitees`: ≥15 invitees caps to 15, no All People shown, correct hiddenCount.
- `testWindowingFillToLimit`: <15 invitees fills remainder from All People.
- `testWindowingZeroInvitees`: All People fills to 15.
- `testFilterByNameCaseInsensitive`: substring match across name.
- `testFilterByEmail`: substring match across email.
- `testFilterBothSections`: filter applies to both sections independently.
- `testAddOptionPresent`: non-empty query, no exact name match.
- `testAddOptionSuppressedExactMatch`: exact name match suppresses add.
- `testAddOptionSuppressedEmptyQuery`: whitespace-only → no add.
- `testHiddenCountCorrect`: difference between total matching and shown.
- `testAllFitNoHiddenCount`: ≤15 total → hiddenCount 0, no status row needed.
