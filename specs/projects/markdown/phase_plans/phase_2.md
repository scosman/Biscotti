---
status: complete
---

# Phase 2: Integrate MarkdownEditor into Meeting Notes

## Overview

Wire the Phase 1 `MarkdownEditor` control into `MeetingDetailView`'s notes section, replacing the plain `TextEditor`. The integration preserves the existing debounced autosave and flush-on-disappear behavior, adds the bounded inline box layout (min/max height, subtle container affordance, internal scroll), and records the Apache-2.0 attribution for `swift-markdown-engine`.

## Steps

1. **Expose `meetingID` on `MeetingDetailViewModel`.**
   The `meetingID` property is currently `private`. The view needs it as the `documentId` parameter for `MarkdownEditor` (scoping undo/editor state per meeting). Change from `private let meetingID: UUID` to `public let meetingID: UUID`.

2. **Add `MarkdownEditorUI` dependency to `MeetingDetailUI` target.**
   In `Package.swift`, add `"MarkdownEditorUI"` to the `MeetingDetailUI` target's dependencies array.

3. **Replace `TextEditor` with `MarkdownEditor` in `MeetingDetailView.notesSection`.**
   - Import `MarkdownEditorUI`.
   - Replace the `TextEditor(text:)` block with `MarkdownEditor(text:documentId:placeholder:)`.
   - Bind text via the same `Binding(get: { viewModel.notes }, set: { viewModel.updateNotes($0) })`.
   - Pass `viewModel.meetingID.uuidString` as `documentId`.
   - Pass `"Add notes\u{2026}"` as `placeholder`.
   - Apply `.frame(minHeight: 120, maxHeight: 340)` for the bounded box.
   - Apply `.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardStroke))` for the subtle container affordance.
   - Remove the old `.font(.body)`, `.frame(minHeight: 60)`, and `.scrollContentBackground(.hidden)` modifiers.

4. **Record the Apache-2.0 attribution.**
   Create `THIRD_PARTY_LICENSES.md` at the repo root listing `swift-markdown-engine` with its license type, URL, and copyright.

## Tests

- No new unit tests needed for this phase. The integration is a view-layer swap with no new logic; the configuration factory and placeholder are already tested in Phase 1. The `MeetingDetailUI` target building cleanly (with `MarkdownEditorUI` imported) is the main automated signal.
- The existing `MeetingDetailUITests` must continue to pass (view model behavior unchanged).
- Visual/interaction verification is manual (live run or previews).
