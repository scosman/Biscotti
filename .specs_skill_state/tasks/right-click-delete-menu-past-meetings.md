---
status: complete
created: 2026-06-30
---

# Task: Right-click delete context menu for the past meetings list

## Request

Add a right click menu with clicking on items in all past meetings list. "Delete" is only option when single item selected. "Delete N" when multiple selected.

Follow native list standard behaviour (I have 5 selected and right click a 6th). Not sure what standard is, but follow Apple's pattern

## Notes

- The menu lives on items in the "all past meetings" list.
- Single selection → menu item labeled "Delete". Multiple selection → "Delete N" (where N is the count).
- Apple's native list pattern (the "5 selected, right-click a 6th" case): right-clicking an item that is **not** part of the current selection should make that item the selection (operate on just it); right-clicking an item that **is** part of the current selection operates on the whole selection. SwiftUI's `.contextMenu(forSelectionType:)` modifier implements exactly this — prefer it over a per-row `.contextMenu` so the framework handles the selection semantics for free.
- Reuse the existing meeting-deletion path (whatever the list/store already uses to delete a meeting) rather than introducing a parallel delete code path. Match any existing confirmation/undo behavior the app already has for deletion.
