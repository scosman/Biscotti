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
// ── People — their own model; recur across meetings; reserved for voiceprints (P2) ──
@Model public final class Person {
    public var id: UUID
    public var name: String
    public var email: String?                  // key field (may be nil)
    // Reserved for P2: voiceprint/centroid embeddings, an "isMe" flag.
    @Relationship(inverse: \Meeting.participants) public var meetings: [Meeting]
    @Relationship(inverse: \Meeting.organizer)    public var organizedMeetings: [Meeting]
}

@Model public final class Meeting {
    public var id: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt: Date
    public var notes: String                    // the USER's own notes (distinct from event notes)
    public var preferredTranscriptID: UUID?     // which transcript version is "current"
    @Relationship(deleteRule: .cascade) public var audioFiles: [AudioFileRef]
    @Relationship(deleteRule: .cascade) public var transcripts: [TranscriptRecord]
    @Relationship(deleteRule: .cascade) public var calendarSnapshot: CalendarSnapshot?
    @Relationship public var participants: [Person]   // many-to-many (people recur → voiceprints)
    @Relationship public var organizer: Person?
}

@Model public final class TranscriptRecord {    // versioned: many per Meeting
    public var id: UUID
    public var createdAt: Date
    // ── INPUTS that produced this transcript (drive staleness / "should re-transcribe") ──
    public var transcriptionMethodId: String    // opaque method id, e.g. "v1" — bakes in STT model,
                                                //   diarization model + strategy, all default settings
    public var vocabularyUsed: [String]         // effective custom vocab at transcript time
    public var mappedEventIdentifier: String?   // the calendar event the recording was mapped to then
    // ── OUTPUTS ──
    public var language: String
    public var speakerCount: Int
    @Relationship(deleteRule: .cascade) public var segments: [TranscriptSegmentRecord]   // modeled, not JSON
}

@Model public final class TranscriptSegmentRecord {  // a proper SwiftData entity (not a JSON blob)
    public var id: UUID
    public var index: Int                        // stable ordering within the transcript
    public var speakerID: Int?                   // diarization cluster id (nil = no match)
    public var speakerLabel: String              // "Speaker 0", "Unknown", …
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var noSpeechProbability: Float
    @Relationship(deleteRule: .cascade) public var words: [TranscriptWordRecord]
}

@Model public final class TranscriptWordRecord {
    public var id: UUID
    public var index: Int                        // stable ordering within the segment
    public var word: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var probability: Float                // the reliable per-word confidence (gotcha #13)
    public var speakerID: Int?
}

@Model public final class AudioFileRef {
    public var id: UUID
    public var role: AudioRole                   // .mic / .system  (no .merged — merge is transient, in Transcription)
    public var bookmark: Data?                   // security-scoped bookmark
    public var path: String
    public var byteSize: Int64
    public var isPresent: Bool                   // false = file missing on disk
}

@Model public final class CalendarSnapshot {     // clearable in one operation; frozen event metadata
    public var id: UUID                          // UUID
    // ── link keys (recurring-event-robust re-sync; research/eventkit §re-linking) ──
    public var eventIdentifier: String?          // EventKit id (shared across occurrences; may change on sync)
    public var calendarItemIdentifier: String?   // local-store id
    public var calendarItemExternalIdentifier: String?  // cross-device id
    public var occurrenceStartDate: Date?        // disambiguates a recurring instance
    public var compositeKey: String              // human fallback re-link key (title+start+organizer)
    // ── core event fields (copied at pairing time; snapshot is source of truth if the event vanishes) ──
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?                 // plain-text location (may hold a join URL)
    public var url: URL?                          // event URL (sometimes the join link)
    public var timeZone: String?                 // TimeZone.identifier
    public var eventNotes: String                // the EVENT's description (distinct from Meeting.notes)
    public var status: String?                   // EKEventStatus (e.g. "canceled")
    public var availability: String?             // EKEventAvailability
    // ── calendar provenance ──
    public var calendarTitle: String?
    public var calendarColorHex: String?
    // ── conferencing (regex-extracted from notes/location/url) ──
    public var conferenceURL: URL?
    public var conferencePlatform: String?       // "zoom" / "meet" / "teams" / …
    // ── metadata ──
    public var snapshotDate: Date                // when this snapshot was captured
    public var isStale: Bool                     // source event deleted / not found on last sync
    // Participants + organizer are `Person` relationships on `Meeting` (dedup + voiceprints),
    // NOT frozen here.
}

@Model public final class AppSettings {          // singleton-ish
    public var customVocabulary: [String]
    public var launchAtLogin: Bool
    // No model-variant setting: V1 offers no transcription options (method is fixed "v1").
}

public enum AudioRole: String, Codable, Sendable { case mic, system }
```

> **Transcript segments are modeled SwiftData entities** (`TranscriptSegmentRecord` → `TranscriptWordRecord`), not a JSON blob — queryable and relational. DataStore maps the Transcription package's `TranscriptResult` value DTOs into these `@Model` rows in `addTranscript` (so persistence types are owned here; the engine stays decoupled). `index` fields give stable ordering (SwiftData relationships are unordered).
>
> **No `searchText`** — a denormalized search field is premature; it'll be added (if needed) when search is actually designed (Project 7). V1 `search` matches over `Meeting.title` + participant names; transcript-text search is part of that later design.
>
> **`transcriptionMethodId`** is one opaque, extensible id ("v1") that bundles every transcription parameter that affects output (STT model + quantization, diarization model, diarization strategy, …). The Transcription library owns the mapping id→settings; the data model only stores the id. Re-transcribe staleness compares the stored id (+ vocab + mapped event) against current.
>
> **Participants are many-to-many** (`Meeting.participants ⟷ Person.meetings`): a `Person` recurs across meetings so voiceprints/identity accumulate (the reason People are their own model). **SwiftData-native pattern:** both ends are arrays, and `@Relationship(inverse:)` is declared **once on `Person`** for *each* of the two Person↔Meeting links (`participants` and `organizer`) so SwiftData can tell them apart. `organizer` is to-one on `Meeting` (→ `Person.organizedMeetings` to-many = one-to-many); `participants` is to-many on both sides (= many-to-many).

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

    // transcripts (versioned) — records the inputs that produced it (method/vocab/mapping);
    // maps result.segments → TranscriptSegmentRecord/WordRecord rows. The method id comes
    // from the result (result.transcriptionMethodId), not a parameter.
    public func addTranscript(
        _ result: TranscriptResult,
        vocabularyUsed: [String],
        mappedEventIdentifier: String?,
        to meetingID: UUID
    ) throws -> UUID
    public func setPreferredTranscript(_ transcriptID: UUID, for meetingID: UUID) throws
    /// True if the meeting's preferred transcript was produced with different inputs than
    /// supplied now (method/vocab/mapping changed) → the app should offer re-transcribe.
    public func preferredTranscriptIsStale(
        meetingID: UUID,
        currentMethodId: String,
        currentVocabulary: [String],
        currentEventIdentifier: String?
    ) throws -> Bool

    // people / participants
    public func findOrCreatePerson(name: String, email: String?) throws -> UUID   // dedup by email then name
    public func setParticipants(_ personIDs: [UUID], organizer: UUID?, for meetingID: UUID) throws

    // audio refs
    public func attachAudio(_ refs: [AudioFileRef], to meetingID: UUID) throws
    public func markAudioPresence(meetingID: UUID) throws    // refresh isPresent from disk

    // calendar snapshot
    public func setSnapshot(_ snapshot: CalendarSnapshot, for meetingID: UUID) throws
    public func clearSnapshot(for meetingID: UUID) throws    // one-operation clear

    // association + correction
    public func associate(meetingID: UUID, withEventIdentifier: String, compositeKey: String) throws
    public func correctAssociation(meetingID: UUID, toEventIdentifier: String, compositeKey: String) throws

    // search (V1: SwiftData term matching over title + participant names;
    // transcript-text search deferred to the search design — Project 7)
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

`findOrCreatePerson` dedups by `email` (case-insensitive) when present, else by exact `name`, so the same human is one `Person` across meetings (the basis for future voiceprints). `addTranscript` reads `result.transcriptionMethodId` and copies it plus the supplied vocab + mapped-event onto the `TranscriptRecord`, and maps `result.segments`/`words` into `TranscriptSegmentRecord`/`TranscriptWordRecord` rows (assigning `index` for order); `preferredTranscriptIsStale` compares the preferred record's stored inputs against the current ones. CloudKit-readiness note: SwiftData's CloudKit mirroring requires all relationships to be optional / have defaults — the `@Model` definitions are kept CloudKit-compatible now even though sync is off, so Project 12 is config-only.

## Dependencies

SwiftData + Foundation; the `TranscriptResult`/`TranscriptSegment`/`TranscriptWord` value DTOs from the Transcription package (mapped into the `@Model` rows). No other internal deps. Consumed by nearly everything later (Recording, TranscriptionService, Calendar, the UI screens).

## Test Plan (all `swift test` against an **in-memory** container)

- `ContainerTests` — in-memory container builds; CloudKit-off config valid.
- `MeetingCRUDTests` — create/read/delete; `recentMeetings`/`upcomingMeetings` ordering + limits.
- `TranscriptVersioningTests` — multiple `TranscriptRecord`s per meeting; adding a version never drops prior; `setPreferredTranscript` updates `preferredTranscriptID`.
- `TranscriptInputTrackingTests` — `addTranscript` persists `transcriptionMethodId`/vocab/mapped-event; `preferredTranscriptIsStale` is false for identical inputs and true when method id, vocab, or event mapping differs.
- `SegmentMappingTests` — `addTranscript` maps a `TranscriptResult`'s segments + words into `TranscriptSegmentRecord`/`TranscriptWordRecord` rows with correct `index` ordering, speaker ids, timings, and per-word probability; round-trips equal to the source DTO.
- `PeopleTests` — `findOrCreatePerson` dedups by email then name; `setParticipants` builds the M:N relationship + organizer; a person recurs across two meetings (one `Person`, two `meetings`).
- `AudioRefTests` — attach refs (roles mic/system only); `markAudioPresence` flips `isPresent` when a path is missing (temp-dir fixture).
- `SnapshotTests` — set then `clearSnapshot` removes it in one call; meeting survives; key event fields (location, isAllDay, conferenceURL, calendar provenance) persist.
- `AssociationTests` — associate then `correctAssociation`; conflict → `associationConflict`.
- `SearchTests` — term match across title + participant names; case-insensitive; no match → empty. (Transcript-text search is out of scope — designed in Project 7.)

**Deferred:** nothing to the Manual Test App (no DataStore tab — decided). Real on-disk migration is covered by the most realistic unit tests achievable and revisited if/when a real migration lands.
</content>
