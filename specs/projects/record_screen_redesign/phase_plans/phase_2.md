---
status: complete
---

# Phase 2: Notes backend + markdown seeding (no UI)

## Overview

Add the in-memory meeting notes model, mutators on RecordingController, and the
pure NotesMarkdown generator that produces deep-link markdown seeded into the
meeting's `notes` field on stop. This is backend-only (no UI changes) and
provides the data layer consumed by Phase 3's recording pane and Phase 6's deep
link handler.

## Steps

1. **Add `MeetingNote` value type** to `Recording` module
   (`Sources/Recording/MeetingNote.swift`):
   ```swift
   public struct MeetingNote: Identifiable, Sendable, Equatable {
       public let id: UUID
       public var text: String
       public let timestamp: TimeInterval
   }
   ```

2. **Add `NotesMarkdown` pure generator** to `Recording` module
   (`Sources/Recording/NotesMarkdown.swift`):
   ```swift
   public enum NotesMarkdown {
       public static func generate(notes: [MeetingNote], meetingID: UUID) -> String?
       public static func merged(existing: String, section: String) -> String
       public static func timeLabel(_ seconds: TimeInterval) -> String
   }
   ```
   - `generate`: returns the `### Notes During Meeting` section (oldest-first),
     or `nil` when `notes` is empty.
   - Link format: `[{m:ss}](biscotti://meeting/{id}?time={seconds})` with one
     decimal on seconds.
   - `timeLabel`: `m:ss` for < 1 hour, `h:mm:ss` for >= 1 hour.
   - `merged`: appends `section` to `existing` (blank line separator when
     existing is non-empty).

3. **Add notes state + mutators to `RecordingController`**:
   - New `public private(set) var notes: [MeetingNote] = []` (oldest-first).
   - `addNote(text:)`: trims whitespace; ignores empty; stamps `state.elapsed`;
     appends.
   - `updateNote(id:text:)`: changes text, preserves timestamp.
   - `removeNote(id:)`: removes by id.
   - `start()`: resets `notes = []` alongside existing session reset.

4. **Seed notes on stop** in `RecordingController.stop()`:
   - After audio-presence/duration persistence, before resetting state/notes.
   - Generate markdown via `NotesMarkdown.generate`; if non-nil, read existing
     notes from store, merge, and write back via `store.setNotes`.
   - Clear `notes = []` after seeding.
   - Failures are logged, non-fatal (existing pattern).

## Tests

- **`NotesMarkdownTests`** (new file in `RecordingTests/`):
  - `testGenerateWithMultipleNotes`: oldest-first ordering, correct link format,
    heading, blank lines between notes.
  - `testGenerateEmptyReturnsNil`: empty array -> nil.
  - `testGenerateSingleNote`: single note output format.
  - `testTimeLabelMinutesSeconds`: m:ss for < 1 hour.
  - `testTimeLabelHours`: h:mm:ss for >= 1 hour.
  - `testTimeLabelZero`: 0 seconds -> "0:00".
  - `testOneDecimalSeconds`: fractional seconds in link target.
  - `testMergedEmptyExisting`: section returned as-is.
  - `testMergedNonEmptyExisting`: existing + blank line + section.

- **`RecordingControllerTests` additions** (existing file):
  - `testAddNoteStampsElapsed`: addNote uses state.elapsed for timestamp.
  - `testAddNoteIgnoresBlank`: empty/whitespace-only text produces no note.
  - `testUpdateNoteChangesText`: text changes, timestamp preserved.
  - `testRemoveNote`: note removed by id.
  - `testStartClearsNotes`: start() resets notes to empty.
  - `testStopSeedsNotes`: stop() writes markdown to meeting's notes field.
  - `testStopClearsNotes`: notes array is empty after stop.
  - `testStopNoNotesSkipsSeeding`: no notes -> meeting notes remain empty.
