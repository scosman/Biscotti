---
status: complete
---

# Phase 7: Sidebar upcoming-meeting cells

## Overview

Fix two interaction/layout issues in the sidebar's upcoming-meeting cells:
1. Make cells clickable across their full width (currently only the intrinsic content width is tappable).
2. Right-align the meeting-type badge (e.g. "Google Meet") to the trailing edge of the cell.

Both fixes are in `UpcomingEventRow` (DesignSystem), which is a shared component used by the sidebar and HomeView. The `twoLine: true` layout is affected — the one-line layout already has correct behavior (full-width HStack with Spacer + badge at trailing edge).

## Steps

1. **`UpcomingEventRow.twoLineLayout`** — In `Packages/BiscottiKit/Sources/DesignSystem/UpcomingEventRow.swift`:
   - Add `frame(maxWidth: .infinity, alignment: .leading)` to the outer `VStack` so it fills available width, making `contentShape(Rectangle())` cover the full row.
   - Add `Spacer()` between `timeLabel` and `badgeLabel` in the second-line `HStack` to push the badge to the trailing edge.

## Surfaces affected

`UpcomingEventRow` with `twoLine: true` is used in:
- **Sidebar** (`AppShellView.upcomingSection`) — the primary target of this feedback.
- **HomeView** (upcoming section) — same layout, same fix applies and is appropriate.

The one-line layout (used by menu bar) already has correct full-width + trailing-badge behavior via its existing `Spacer()`.

## Tests

- No new unit tests warranted — this is a pure visual/interaction change (frame sizing and spacer placement) with no logic or view-model behavior involved. The existing tap action wiring (sidebar `viewModel.selectEvent(event.id)`, HomeView `viewModel.selectEvent(event.id)`) is unchanged. Verified via precommit checks (lint + test + build).
