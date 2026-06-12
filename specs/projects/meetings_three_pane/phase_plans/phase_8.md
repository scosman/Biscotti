---
status: complete
---

# Phase 8: Right pane & layout

## Overview

Three visual fixes to the three-pane layout: adjust default column widths so the sidebar is narrower and the meetings list is wider, fix the "No meeting selected" placeholder so it fills the full detail pane height, and move the Delete button from the bottom of the detail view to above the transcript section.

## Steps

### 1. Adjust default column widths

**Before:**
- Sidebar: `frame(minWidth: 180, idealWidth: 220)` in `AppShellView.sidebar`
- Meetings-list pane: `frame(minWidth: 220, idealWidth: 280, maxWidth: 420)` in `MeetingsSplitView`

**After:**
- Sidebar: `frame(minWidth: 100, idealWidth: 110)` (50% of the current 220 ideal)
- Meetings-list pane: `frame(minWidth: 180, idealWidth: 220, maxWidth: 420)` (takes the sidebar's old default width of 220)

Files: `Packages/BiscottiKit/Sources/AppShellUI/AppShellView.swift`

### 2. Fix empty-detail placeholder height

The `ContentUnavailableView` placeholder for "No Meeting Selected" sits in a `Group` that only has `.frame(minWidth: 360, maxWidth: .infinity)` — no height constraint. The `MeetingDetailView` already has `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`, so it fills correctly. The placeholder needs matching `maxHeight: .infinity` and center alignment.

Fix: Add `.frame(maxWidth: .infinity, maxHeight: .infinity)` to the placeholder `ContentUnavailableView` so it fills the entire detail area, not just its intrinsic content height.

Files: `Packages/BiscottiKit/Sources/AppShellUI/AppShellView.swift`

### 3. Move Delete button above the transcript

Currently in `MeetingDetailView.body`, the order is: header → calendar → audio → notes → stateContent (transcript) → deleteSection. Move `deleteSection` to appear immediately before `stateContent`, so the delete button sits above the transcript.

Files: `Packages/BiscottiKit/Sources/MeetingDetailUI/MeetingDetailView.swift`

## Tests

- No new view-model tests needed — all three changes are pure layout/view-layer (frame sizes, view ordering). The delete action/confirmation flow is unchanged and already tested in `MeetingDetailViewModelTests`. No view-model logic is added or modified.
