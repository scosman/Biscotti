---
status: complete
---

# Phase 1: Data Model & DataStore

## Overview

Add the data model fields, DTOs, and DataStore methods needed by the LLM features project. This phase is purely additive -- no LLM, no UI. It adds `summary`/`editedSummary` to Meeting, `speakerAssignments` to TranscriptRecord, `summarizeTranscripts`/`guessSpeakerNames` to AppSettings, extends all affected DTOs, and adds the new DataStore mutation/query methods. Full test coverage.

## Steps

1. **Meeting model** (`Models/Meeting.swift`): Add `summary: String = ""` and `editedSummary: Bool = false` properties.

2. **TranscriptRecord model** (`Models/TranscriptRecord.swift`): Add `speakerAssignmentsData: Data = Data()` (private) and `@Transient var speakerAssignments: [Int: UUID]` computed property, mirroring the `vocabularyUsed`/`vocabularyUsedData` pattern.

3. **AppSettings model** (`Models/AppSettings.swift`): Add `summarizeTranscripts: Bool = true` and `guessSpeakerNames: Bool = true` properties. Wire through init.

4. **SegmentData DTO** (`DataStore+ReadModels.swift`): Add `speakerID: Int?` field. Update `mapTranscript` to populate it from `TranscriptSegmentRecord.speakerID`.

5. **TranscriptData DTO** (`DataStore+ReadModels.swift`): Add `speakerAssignments: [Int: PersonData]` field (resolved map). Add `func speakerName(forID:) -> String?` convenience. Update `mapTranscript` to accept and resolve speaker assignments against Person records.

6. **MeetingDetailData DTO** (`DataStore+ReadModels.swift`): Add `summary: String` and `editedSummary: Bool` fields. Wire in `meetingDetail(id:)`.

7. **AppSettingsData DTO** (`DataStore+ReadModels.swift`): Add `summarizeTranscripts: Bool` and `guessSpeakerNames: Bool`. Wire through `settings()` and `updateSettings(_:)`.

8. **DataStore methods -- summary** (`DataStore+ReadModels.swift` or new extension file): Add `applyGeneratedSummary(_:for:)` (sets summary, editedSummary=false) and `setSummary(_:for:)` (sets summary, editedSummary=true).

9. **DataStore methods -- speaker assignments** : Add `setSpeakerAssignments(_:for:)` (replace whole map on a TranscriptRecord) and `setSpeakerAssignment(speakerID:personID:for:)` (set/clear one entry).

10. **DataStore method -- allPersonData**: Add `allPersonData() -> [PersonData]` returning all Person records as DTOs.

11. **Read-model resolution**: Update `mapTranscript` and `meetingDetail` to resolve speaker assignments (fetch Person records by ID from the transcript's map, drop dangling IDs). Update `transcript(id:)` similarly.

## Tests

- `testApplyGeneratedSummary`: sets summary, editedSummary=false, readable via meetingDetail
- `testSetSummary`: sets summary, editedSummary=true
- `testApplyGeneratedSummaryNotFound`: throws notFound for unknown meeting
- `testSetSummaryNotFound`: throws notFound for unknown meeting
- `testSetSpeakerAssignments`: replace entire map, readable via transcript read model
- `testSetSpeakerAssignment_setSingle`: set one speaker, verify map
- `testSetSpeakerAssignment_clearSingle`: set then clear one speaker (nil personID)
- `testSpeakerAssignmentsRoundTrip`: [Int:UUID] encodes/decodes correctly through JSON Data
- `testSpeakerAssignmentsDanglingIDDropped`: assignments referencing non-existent Person IDs are dropped in the read model
- `testSpeakerAssignmentsResolved`: assignments resolve to PersonData in TranscriptData
- `testSpeakerNameConvenience`: TranscriptData.speakerName(forID:) returns correct name or nil
- `testSegmentDataIncludesSpeakerID`: SegmentData carries speakerID from the segment record
- `testMeetingDetailCarriesSummaryFields`: meetingDetail populates summary and editedSummary
- `testAllPersonData`: returns all persons as PersonData DTOs
- `testSettingsSummarizeAndGuessFields`: settings/updateSettings round-trip the new fields
- `testSetSpeakerAssignmentsNotFound`: throws notFound for unknown transcript
- `testSetSpeakerAssignmentNotFound`: throws notFound for unknown transcript
