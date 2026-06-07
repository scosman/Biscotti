---
status: complete
---

# Phase 3.2: Transcripts (modeled segments + input tracking), audio refs, snapshot, association, search

## Overview

Add all remaining `DataStore` methods on top of the Phase 3.1 schema and CRUD. This phase introduces the Transcription package as a dependency (for `TranscriptResult` DTOs), then implements: versioned transcript mapping (`TranscriptResult` -> `TranscriptRecord`/`TranscriptSegmentRecord`/`TranscriptWordRecord` rows); input tracking + staleness detection; audio file attachment + disk-presence checking; clearable calendar snapshots; meeting-to-calendar-event association with conflict handling; and basic title + participant name search (case-insensitive, NO transcript-text search -- that is Project 7).

## Steps

1. **Update `Packages/BiscottiKit/Package.swift`** -- add a local path dependency on `../Transcription` and wire it to the `DataStore` target (and `DataStoreTests`).

2. **Implement transcript methods in `DataStore.swift`:**
   - `addTranscript(_:vocabularyUsed:mappedEventIdentifier:to:)` -- maps `TranscriptResult` segments + words into `TranscriptSegmentRecord`/`TranscriptWordRecord` rows with `index` for stable ordering; records `transcriptionMethodId`, `vocabularyUsed`, `mappedEventIdentifier` on the `TranscriptRecord`; appends to the meeting's `transcripts`; returns the new record's UUID.
   - `setPreferredTranscript(_:for:)` -- sets `meeting.preferredTranscriptID`.
   - `preferredTranscriptIsStale(meetingID:currentMethodId:currentVocabulary:currentEventIdentifier:)` -- compares stored inputs on the preferred transcript against the supplied current values; returns true if any differ.

3. **Implement audio ref methods in `DataStore.swift`:**
   - `attachAudio(_:to:)` -- appends the supplied `AudioFileRef` objects to the meeting's `audioFiles`.
   - `markAudioPresence(meetingID:)` -- stats each `AudioFileRef.path` via `FileManager` and updates `isPresent` + `byteSize`.

4. **Implement snapshot methods in `DataStore.swift`:**
   - `setSnapshot(_:for:)` -- replaces the meeting's `calendarSnapshot`.
   - `clearSnapshot(for:)` -- sets the meeting's `calendarSnapshot` to nil.

5. **Implement association methods in `DataStore.swift`:**
   - `associate(meetingID:withEventIdentifier:compositeKey:)` -- sets the snapshot's `eventIdentifier` + `compositeKey`; throws `associationConflict` if the meeting already has a snapshot with a different `eventIdentifier`.
   - `correctAssociation(meetingID:toEventIdentifier:compositeKey:)` -- unconditionally replaces the snapshot's `eventIdentifier` + `compositeKey`.

6. **Implement search in `DataStore.swift`:**
   - `search(_:)` -- case-insensitive match on `Meeting.title` + participant names; no transcript-text search. Returns matching meetings.

## Tests

- **`TranscriptVersioningTests`** -- multiple transcripts per meeting; adding a version never drops prior; `setPreferredTranscript` updates `preferredTranscriptID`.
- **`TranscriptInputTrackingTests`** -- `addTranscript` persists `transcriptionMethodId`/vocab/mapped-event; `preferredTranscriptIsStale` returns false for identical inputs and true when method id, vocab, or event mapping differs.
- **`SegmentMappingTests`** -- `addTranscript` maps segments + words into `TranscriptSegmentRecord`/`TranscriptWordRecord` rows with correct `index` ordering, speaker IDs, timings, per-word probability; round-trips equal to the source DTO.
- **`AudioRefTests`** -- attach refs (roles mic/system); `markAudioPresence` flips `isPresent` when a path is missing (temp-dir fixture).
- **`SnapshotTests`** -- set then `clearSnapshot` removes it in one call; meeting survives; key event fields persist.
- **`AssociationTests`** -- associate then `correctAssociation`; conflict -> `associationConflict`.
- **`SearchTests`** -- term match across title + participant names; case-insensitive; no match -> empty.
