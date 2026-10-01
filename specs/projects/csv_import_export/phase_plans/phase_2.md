---
status: complete
---

# Phase 2: DataStore — import/export storage layer

## Overview

Add the persistence substrate the CSV feature needs: two additive `Meeting`
fields (`externalID`, `importBatch`), the draft/read model types
(`ImportedMeetingDraft`, `ExistingMeetingIdentity`, `MeetingExportData`), and
seven new `DataStore` methods — the import write path, the export read path,
and the debug-build bulk delete. Everything is unit-testable in-memory; no UI,
no app target, no package-manifest changes.

## Steps

1. **`Models/Meeting.swift`** — add `public var externalID: String?` and
   `public var importBatch: Int?` (additive, nil defaults, no migration —
   mirror the `recordingDuration` precedent and its comment).
2. **`ImportDrafts.swift`** — extend with `ImportedMeetingDraft`
   (meetingID/externalID/title/created/summary/notes/transcript segments),
   `ExistingMeetingIdentity` (meetingIDs + externalIDs sets), and
   `MeetingExportData` (id/title/date/summary/notes/segments/speakerNames),
   per architecture §2.1–§2.2.
3. **New `DataStore+ImportExport.swift`** (extension on `DataStore`,
   matching `DataStore+Tags` style):
   - `existingMeetingIdentity()` — one fetch, map `id`/`externalID` into sets.
   - `nextImportBatchID(now:)` — `Int(now.timeIntervalSince1970 * 1000)`,
     incremented while the value collides with an existing `importBatch`
     (fetched as a narrowed set — avoids `#Predicate` optional-Int equality).
   - `insertImportedMeetings(_:batchID:)` — per draft: `Meeting` with
     `editedTitle = true`, `editedSummary = !summary.isEmpty`,
     `startDate`/`endDate` nil; non-empty transcript → `TranscriptRecord`
     with `transcriptionMethodId = "imported"`, `language = ""`, distinct
     speaker count, one `TranscriptSegmentRecord` per draft segment (`index`
     in order, `endTime = startTime`), `preferredTranscriptID` set. One
     `save()` for the batch; returns the inserted count.
   - `meetingIDsForExport()` — all IDs sorted by `startDate ?? createdAt`
     descending (in-memory sort, same approach as `meetingSummaries`).
   - `exportData(for:)` — fetch by ID list, return in input order (skipping
     any ID that vanished), preferred transcript's segments in index order,
     speaker names resolved from `speakerAssignments` (dangling dropped).
   - `importedMeetingCounts()` — two `fetchCount` calls
     (`importBatch != nil` / `== nil`), no objects materialized.
   - `deleteImportedMeetings()` — fetch `importBatch != nil`, eagerly
     `searchIndex.removeMeeting` per meeting, `context.delete`, one save;
     returns the deleted count.
4. **Tests** — new `Tests/DataStoreTests/ImportExportStoreTests.swift`
   (architecture §9 DataStoreTests list).

## Tests

- `insertImportedMeetings` — creates meetings with the given UUIDs; sets
  `externalID`, `importBatch`, `editedTitle`, `editedSummary` (true only for
  non-empty summary); transcript record carries `transcriptionMethodId
  == "imported"`, correct segment order/indices, `endTime == startTime`,
  `speakerCount` = distinct speakers, `preferredTranscriptID` set; empty
  transcript → no record; returns the inserted count.
- `existingMeetingIdentity` — returns both the UUID set and the externalID set.
- `nextImportBatchID` — returns epoch ms for `now`; increments past a colliding
  existing batch.
- `meetingIDsForExport` — sorts by `startDate ?? createdAt` descending
  (mix of meetings with and without `startDate`).
- `importedMeetingCounts` — imported/remaining split.
- `deleteImportedMeetings` — removes only imported meetings; leaves recorded
  meetings untouched; cascades their transcripts; search-index entries cleared
  (behavioral check via `searchHits`); returns the deleted count; zero
  imported → returns 0.
- `exportData(for:)` — returns data in input order; segments in index order
  from the preferred transcript; speaker names resolved from assignments;
  meeting without transcript → empty segments and names; unknown IDs skipped.
