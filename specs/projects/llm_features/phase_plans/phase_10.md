---
status: complete
---

# Phase 10: Speaker-Assignment Provenance (`userSet`)

## Overview

Add per-entry provenance to the speaker-assignment map so the LLM auto-run never overwrites a human's manual assignment. The stored value changes from a bare `UUID` to a `{ personID: UUID, userSet: Bool }` struct, with lenient decode of the old shape. Manual writes set `userSet = true`; the LLM bulk write merges rather than replaces, skipping any `userSet` entry.

## Steps

1. **Define `SpeakerAssignmentEntry` struct** in `TranscriptRecord.swift`:
   ```swift
   public struct SpeakerAssignmentEntry: Codable, Equatable, Sendable {
       public let personID: UUID
       public let userSet: Bool
   }
   ```

2. **Change `TranscriptRecord.speakerAssignments` computed property** from `[Int: UUID]` to `[Int: SpeakerAssignmentEntry]`. The getter decodes from the same `speakerAssignmentsData`, with lenient fallback: if decoding `[Int: SpeakerAssignmentEntry]` fails (old `[Int: UUID]` shape), return empty `[:]`. The setter encodes the new struct shape.

3. **Update `DataStore+LLMFeatures.swift` — `setSpeakerAssignment`** (single-speaker, manual path): set `userSet = true` for the entry. When `personID` is nil (unassign), remove the entry entirely.

4. **Update `DataStore+LLMFeatures.swift` — `setSpeakerAssignments`** (bulk, LLM path): change to **merge** semantics. For each incoming `(speakerID, personID)`, skip if the current entry has `userSet == true`. Write AI entries as `userSet = false`.

5. **Update `DataStore+ReadModels.swift` — `mapTranscript`**: adapt the read-model resolution to read `SpeakerAssignmentEntry.personID` instead of bare `UUID`. The public `TranscriptData.speakerAssignments: [Int: PersonData]` is unchanged.

6. **Update existing test** (`speakerAssignmentsRoundTrip`): adapt the raw-read assertion from `[Int: UUID]` to `[Int: SpeakerAssignmentEntry]`, verifying `personID` and `userSet`.

## Tests

- **`autoRunPreservesUserSetAndFillsUnset`**: set speaker 0 manually (`userSet = true`), then call `setSpeakerAssignments` with mappings for speakers 0 and 1. Verify speaker 0 is unchanged (preserved) and speaker 1 is filled with `userSet = false`.
- **`manualSetMarksUserSetTrue`**: call `setSpeakerAssignment(speakerID:personID:for:)` and verify the raw entry has `userSet == true`.
- **`oldShapeDecodeReturnsEmpty`**: write raw `[Int: UUID]` JSON to `speakerAssignmentsData` and verify the computed property returns `[:]`.
- **`unassignClearsEntry`**: set a speaker, then unassign. Verify the entry is completely removed.
- **`bulkWriteAllAIEntriesHaveUserSetFalse`**: call `setSpeakerAssignments` on an empty map and verify all entries have `userSet = false`.
