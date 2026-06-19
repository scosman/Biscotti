---
status: complete
---

# Phase 3: "See All" as the list's last row

## Overview

Move "See All" from the `HomePastSection` header into the bottom row of the past-meetings card. The header should contain only the "PAST MEETINGS" kicker label. The new row sits after the last `pastRow`, separated by an `InsetDivider()`, with left-aligned "See All" text, a grey total count before the chevron, and the same padding/hit-area as `pastRow`. Hidden when there are no past meetings (the "No recordings yet" empty card stands alone).

## Steps

1. **Add `pastMeetingsCount` to `HomeViewModel`** (`HomeUI/HomeViewModel.swift`):
   - Add `public var pastMeetingsCount: Int { core.summaries.count }` — exposes the total meeting count for the "See All" row badge.

2. **Remove "See all" from the header** (`HomeUI/HomeView.swift`, `HomePastSection.body`):
   - Strip the trailing `Button` (lines ~314-325) from the header `HStack`. The header becomes just `HomeSharedViews.groupLabel("PAST MEETINGS")` (no `HStack`/`Spacer` needed).

3. **Add "See All" row to `pastCard`** (`HomeUI/HomeView.swift`, `HomePastSection.pastCard`):
   - After the `ForEach` of `pastRow`s, add an `InsetDivider()` followed by a `seeAllRow` view.
   - `seeAllRow`: a `Button(.plain)` calling `viewModel.showMeetings()` whose label is an `HStack` with `Text("See All")` (left), `Spacer`, `Text("\(viewModel.pastMeetingsCount)")` in `.inkSecondary`, and `Image(systemName: "chevron.right")` styled like the existing row chevrons. Padding matches `pastRow` (`.padding(.vertical, Tokens.rowVerticalPadding)`, `.padding(.horizontal, Tokens.rowHorizontalPadding)`).

## Tests

- **`pastMeetingsCount` reflects total summaries count**: create N meetings, verify `pastMeetingsCount == N` (distinct from `recentMeetings.count` which caps at 3).
- **`pastMeetingsCount` is zero when no meetings exist**: verify `pastMeetingsCount == 0`.
