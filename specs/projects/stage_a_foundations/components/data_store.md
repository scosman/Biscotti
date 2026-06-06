---
status: complete
---

# Component: DataStore (`BiscottiKit` module)

The SwiftData persistence layer and single owner of persistent types. A module inside `BiscottiKit` (not a package — idiomatic for `@Model`; repo [`architecture.md` §Granularity #3](../../../../architecture.md)). Informed by the `EventKitLab` data-availability report.

## Purpose & Scope

**In:** the schema; configurable container (on-disk + in-memory); CRUD/queries; versioned transcripts; event↔recording association + correction; the clearable calendar-snapshot sub-item; simple V1 search; sync-ready (CloudKit wired-but-off).

**Not:** EventKit/audio/transcription specifics (stores their results), UI, networking, real CloudKit sync (P12), the orphaned-recording recovery *flow* (Recording, Project 4), FTS.

## Public Interface

### Models (`@Model` classes; field lists are the V1 schema)

```swift
@Model public final class Meeting {
    public var id: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt: Date
    public var notes: String
    @Relationship(deleteRule: .cascade) public var audioFiles: [AudioFileRef]
    @Relationship(deleteRule: .cascade) public var transcripts: [TranscriptRecord]
    @Relationship(deleteRule: .cascade) public var calendarSnapshot: CalendarSnapshot?
    public var preferredTranscriptID: UUID?     // which version is "current"
    // … inits
}

@Model public final class TranscriptRecord {     // versioned: many per Meeting
    public var id: UUID
    public var createdAt: Date
    public var modelVersion: String
    public var language: String
    public var speakerCount: Int
    public var segmentsJSON: Data                 // encoded [TranscriptSegment] from Transcription
    public var searchText: String                 // denormalized concatenated text for V1 search
}

@Model public final class AudioFileRef {
    public var id: UUID
    public var role: AudioRole                     // .mic / .system / .merged
    public var bookmark: Data?                     // security-scoped bookmark
    public var path: String
    public var byteSize: Int64
    public var isPresent: Bool                      // false = file missing on disk
}

@Model public final class CalendarSnapshot {       // clearable in one operation
    public var id: UUID
    public var eventIdentifier: String?            // EventKit link (may break)
    public var compositeKey: String                // re-link key (title+start+organizer)
    public var title: String
    public var organizer: String?
    public var participantsJSON: Data
    public var conferenceURL: URL?
    public var eventNotes: String
}

@Model public final class AppSettings {            // singleton-ish
    public var customVocabulary: [String]
    public var launchAtLogin: Bool
    public var preferredModelVariant: String
}

public enum AudioRole: String, Codable, Sendable { case mic, system, merged }
```

> `segmentsJSON`/`participantsJSON` store the engine packages' `Sendable` DTOs as encoded blobs — DataStore depends on no engine internals (architecture's boundary rule). If view-model/concurrency friction appears, the escape hatch in architecture §Granularity #3 (extract a `Models` leaf) applies — additive, not a re-topology.

### Store façade

```swift
public actor DataStore {
    public enum Storage: Sendable { case onDisk(URL), inMemory }
    public init(storage: Storage, cloudKit: Bool = false) throws   // cloudKit wired but default off

    // CRUD / queries
    public func createMeeting(title: String, start: Date?, end: Date?) throws -> UUID
    public func meeting(id: UUID) throws -> Meeting?
    public func recentMeetings(limit: Int) throws -> [Meeting]
    public func upcomingMeetings(now: Date, limit: Int) throws -> [Meeting]
    public func delete(meetingID: UUID) throws

    // transcripts (versioned)
    public func addTranscript(_ result: TranscriptResult, to meetingID: UUID) throws -> UUID
    public func setPreferredTranscript(_ transcriptID: UUID, for meetingID: UUID) throws

    // audio refs
    public func attachAudio(_ refs: [AudioFileRef], to meetingID: UUID) throws
    public func markAudioPresence(meetingID: UUID) throws    // refresh isPresent from disk

    // calendar snapshot
    public func setSnapshot(_ snapshot: CalendarSnapshot, for meetingID: UUID) throws
    public func clearSnapshot(for meetingID: UUID) throws    // one-operation clear

    // association + correction
    public func associate(meetingID: UUID, withEventIdentifier: String, compositeKey: String) throws
    public func correctAssociation(meetingID: UUID, toEventIdentifier: String, compositeKey: String) throws

    // search (V1: SwiftData term matching over title/people/searchText)
    public func search(_ query: String) throws -> [Meeting]
}
```

### Errors

```swift
public enum DataStoreError: Error, Sendable, Equatable {
    case containerInitFailed(String)
    case saveFailed(String)
    case notFound(UUID)
    case associationConflict
}
```

## Internal Design

One `ModelContainer` built from the `Storage` case (`.inMemory` → `isStoredInMemoryOnly: true`); a `ModelConfiguration` with `cloudKitDatabase: .automatic` only when `cloudKit == true` (off by default — Project 12 flips it). All mutations go through the actor; queries use `FetchDescriptor` + `#Predicate`. `markAudioPresence` stats each `AudioFileRef.path` (resolving bookmarks) and updates `isPresent`. Schema declared via a `VersionedSchema` + an empty `SchemaMigrationPlan` so a later version can add a stage without a wipe.

## Dependencies

SwiftData + Foundation; the `TranscriptResult`/`TranscriptSegment` value types from the Transcription package (encoded into `segmentsJSON`). No other internal deps. Consumed by nearly everything later (Recording, TranscriptionService, Calendar, the UI screens).

## Test Plan (all `swift test` against an **in-memory** container)

- `ContainerTests` — in-memory container builds; CloudKit-off config valid.
- `MeetingCRUDTests` — create/read/delete; `recentMeetings`/`upcomingMeetings` ordering + limits.
- `TranscriptVersioningTests` — multiple `TranscriptRecord`s per meeting; adding a version never drops prior; `setPreferredTranscript` updates `preferredTranscriptID`.
- `AudioRefTests` — attach refs; `markAudioPresence` flips `isPresent` when a path is missing (temp-dir fixture).
- `SnapshotTests` — set then `clearSnapshot` removes it in one call; meeting survives.
- `AssociationTests` — associate then `correctAssociation`; conflict → `associationConflict`.
- `SearchTests` — term match across title / participants / `searchText`; case-insensitive; no match → empty.
- `CodableBridgeTests` — `TranscriptResult` → `segmentsJSON` → decodes back equal.

**Deferred:** nothing to the Manual Test App (no DataStore tab — decided). Real on-disk migration is covered by the most realistic unit tests achievable and revisited if/when a real migration lands.
</content>
