---
status: complete
---

# Phase 3.1: Schema + Container + CRUD + People

## Overview

Add the `DataStore` module to `BiscottiKit` — the SwiftData persistence layer. This phase defines all `@Model` types per the signed-off schema, the `DataStore` actor with configurable storage (on-disk / in-memory, CloudKit-ready-but-off), a `VersionedSchema` + empty `SchemaMigrationPlan`, meeting CRUD + recent/upcoming queries, and the people API (`findOrCreatePerson` / `setParticipants`). Transcript/audio-ref/snapshot/association/search *behavior* is Phase 3.2; this phase only defines those `@Model` types.

## Steps

1. **Update `Package.swift`** — add `DataStore` library target (sources in `Sources/DataStore/`, depends on nothing) and `DataStoreTests` test target (depends on `DataStore`). Both get `warningsAsErrors`. Add `SwiftData` framework dependency to the DataStore target.

2. **Create `Sources/DataStore/Models/` — all `@Model` types:**
   - `Person.swift` — `@Model public final class Person` with `id: UUID`, `name: String`, `email: String?`, inverse relationships to `Meeting.participants` (many-to-many) and `Meeting.organizer` (one-to-many).
   - `Meeting.swift` — `@Model public final class Meeting` with `id`, `title`, `startDate?`, `endDate?`, `createdAt`, `notes`, `preferredTranscriptID: UUID?`, cascade relationships to `audioFiles`, `transcripts`, `calendarSnapshot`, plus `participants: [Person]` and `organizer: Person?`.
   - `TranscriptRecord.swift` — `@Model` with `id`, `createdAt`, input fields (`transcriptionMethodId`, `vocabularyUsed`, `mappedEventIdentifier`), output fields (`language`, `speakerCount`), cascade to `segments`.
   - `TranscriptSegmentRecord.swift` — `@Model` with `id`, `index`, `speakerID?`, `speakerLabel`, `startTime`, `endTime`, `text`, `noSpeechProbability`, cascade to `words`.
   - `TranscriptWordRecord.swift` — `@Model` with `id`, `index`, `word`, `startTime`, `endTime`, `probability`, `speakerID?`.
   - `AudioFileRef.swift` — `@Model` with `id`, `role: AudioRole`, `bookmark: Data?`, `path`, `byteSize: Int64`, `isPresent: Bool`. Plus `public enum AudioRole: String, Codable, Sendable`.
   - `CalendarSnapshot.swift` — `@Model` with all link keys, core event fields, calendar provenance, conferencing, metadata per the schema.
   - `AppSettings.swift` — `@Model` with `customVocabulary: [String]`, `launchAtLogin: Bool`.

3. **Create `Sources/DataStore/DataStoreError.swift`** — `public enum DataStoreError: Error, Sendable, Equatable` with cases `containerInitFailed(String)`, `saveFailed(String)`, `notFound(UUID)`, `associationConflict`.

4. **Create `Sources/DataStore/Schema/DataStoreSchemaV1.swift`** — `VersionedSchema` listing all `@Model` types, version `Version(1,0,0)`.

5. **Create `Sources/DataStore/Schema/DataStoreMigrationPlan.swift`** — empty `SchemaMigrationPlan` with `schemas: [DataStoreSchemaV1.self]` and empty `stages`.

6. **Create `Sources/DataStore/DataStore.swift`** — the `public actor DataStore`:
   - `public enum Storage: Sendable { case onDisk(URL), inMemory }`
   - `public init(storage:cloudKit:)` — builds `ModelConfiguration` + `ModelContainer`.
   - Meeting CRUD: `createMeeting(title:start:end:) -> UUID`, `meeting(id:) -> Meeting?`, `recentMeetings(limit:) -> [Meeting]`, `upcomingMeetings(now:limit:) -> [Meeting]`, `delete(meetingID:)`.
   - People: `findOrCreatePerson(name:email:) -> UUID`, `setParticipants(_:organizer:for:)`.
   - Stub signatures for Phase 3.2 methods (transcript, audio, snapshot, association, search) that throw a "not yet implemented" fatal or are simply omitted until 3.2.

## Tests

- **`ContainerTests`** — in-memory container initializes successfully; CloudKit-off config is valid; multiple containers don't conflict.
- **`MeetingCRUDTests`** — `createMeeting` returns a UUID and the meeting is fetchable; `meeting(id:)` returns nil for unknown ID; `recentMeetings` orders by `createdAt` descending with limit; `upcomingMeetings` returns future meetings ordered by `startDate`; `delete` removes the meeting; deleting a nonexistent ID throws `notFound`.
- **`PeopleTests`** — `findOrCreatePerson` creates a new person; dedup by email (case-insensitive) returns same UUID; dedup by name when email is nil; `setParticipants` links people to meeting; a person recurs across two meetings (one Person, two meetings); organizer is set correctly; clearing participants works.
