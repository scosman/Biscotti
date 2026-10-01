---
status: complete
---

# Phase 3: Storage — Voiceprint Model, Reads, Writes, Current User

## Overview

Build the DataStore persistence layer for voiceprints (§4) and wire the
current-user calendar fact through AppCore (§7). After this phase, every
transcription saves voiceprint records alongside the transcript, the store
can serve corpus and query reads for the matcher (Phase 4), and the
`isCurrentUser` flag on `PersonData` is populated from EventKit data.

## Steps

1. **`Models/Voiceprint.swift`** — new `@Model` class with `id`, `createdAt`,
   `speakerID`, `kindRaw` (String-backed), `embeddingSpace`, `dimension`,
   `vectorData` (Data), `speakingDuration`, and an optional `transcript`
   relationship. Plus `VoiceprintKind` enum (DataStore's own copy).

2. **`VectorCoding.swift`** — `encode(_ vector: [Float]) -> Data` and
   `decode(_ data: Data, dimension: Int) -> [Float]?` (little-endian
   Float32; nil on size mismatch or non-finite value).

3. **`TranscriptRecord`** — add `@Relationship(deleteRule: .cascade,
   inverse: \Voiceprint.transcript) public var voiceprints: [Voiceprint] = []`.

4. **`CalendarSnapshot`** — add `public var currentUserPersonID: UUID?`.

5. **`DataStoreSchemaV1`** — add `Voiceprint.self` to the models array.

6. **`DataStore+Phase3_2.swift` (addTranscript)** — after inserting
   segments, iterate `result.embeddingSets`; for each set and each
   (speakerID, vector) with non-empty all-finite data, create a
   `Voiceprint`, append to `record.voiceprints`.

7. **`DataStore+Voiceprints.swift`** (new) — read DTOs
   (`SpeakerTagData`, `VoiceprintData`, `VoiceprintCorpusData`,
   `VoiceprintQueryData`) and query methods (`voiceprintQuery`,
   `voiceprintCorpus`). Plus backfill types and methods
   (`NewVoiceprint`, `addVoiceprints`, `hasVoiceprints`,
   `StoredSpanData`, `BackfillCandidateData`, `backfillCandidates`).

8. **`DataStore.setParticipants`** — add `currentUser: UUID? = nil`
   parameter; set `meeting.calendarSnapshot?.currentUserPersonID`.
   Validate non-nil currentUser exists.

9. **`calendarContext`** — populate `PersonData.isCurrentUser` from
   `snapshot.currentUserPersonID`. Remove the "Not yet populated" comment.

10. **`Person.swift`** — replace the "Reserved for P2" comment with a note
    that voiceprints live on transcripts.

11. **`AppCore.persistSnapshot`** — find the first attendee/organizer with
    `isCurrentUser == true`, pass its person ID to `setParticipants`.

12. **Test helpers** — `fetchAllVoiceprints()` on DataStore.

## Tests

### DataStoreTests (VoiceprintTests.swift, new)

- `vectorCodingRoundTrip` — encode/decode with matching dimension
- `vectorCodingWrongLength` — mismatched dimension -> nil
- `vectorCodingNaN` — non-finite value -> nil
- `addTranscriptCreatesVoiceprints` — voiceprint per non-empty vector per kind
- `addTranscriptSkipsNonFiniteVectors` — NaN vector skipped, rest saved
- `addTranscriptSkipsEmptyVectors` — empty vector skipped
- `voiceprintCorpusPreferredOnly` — only preferred transcript's voiceprints
- `voiceprintCorpusExcludesKindAndSpace` — wrong kind/space excluded
- `voiceprintCorpusExcludesMeeting` — excluded meeting ID filtered out
- `voiceprintCorpusTagsAndPeople` — tags joined with userSet, dangling -> nil
- `voiceprintCorpusPeopleOnlyReferenced` — people dict has only tagged persons
- `voiceprintQueryReturnsVectorsAndDurations` — correct data shape
- `voiceprintQueryNilSpaceWhenNone` — nil space when no voiceprints of that kind
- `cascadeDeleteRemovesVoiceprints` — deleting meeting cascades
- `setParticipantsCurrentUser` — currentUser sets currentUserPersonID
- `calendarContextMarksCurrentUser` — isCurrentUser populated correctly
- `addVoiceprintsAndHasVoiceprints` — backfill write + check
- `backfillCandidatesContentAndOrder` — oldest first, correct fields

### OnDiskMaterializationTests

- `voiceprintRoundTripOnDisk` — write voiceprints, reopen, read identical vectors

### AppCoreTests

- `persistSnapshotCurrentUser` — attendee with isCurrentUser -> correct person ID
