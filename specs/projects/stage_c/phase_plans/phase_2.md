---
status: complete
---

# Phase 2: Calendar Module

## Overview

Build the `Calendar` module in `BiscottiKit` -- the read-only bridge between EventKit and the rest of
the app. This includes the `EventStoreProviding` seam (testability layer over `EKEventStore`),
`EKEventDTO` (Sendable mirror of EKEvent fields), `CalendarService` (`@MainActor @Observable` service
providing auth status, upcoming events, bestMatch, snapshot mapping), and `LiveEventStore` (the real
EventKit implementation). All public types (`CalendarEvent`, `CalendarInfo`, `CalendarSnapshotInput`,
`AttendeeInput`, `CalendarAuthStatus`) cross the module boundary as Sendable DTOs. Conference detection
delegates to the existing `MeetingCatalog` module. Full unit tests over the `EventStoreProviding` seam.

## Steps

### 1. Add `Calendar` target to Package.swift

Add a new `Calendar` target depending on `DataStore` and `MeetingCatalog`, plus a `CalendarTests` test
target. Add `Calendar` as a library product. The target links `EventKit` (system framework -- no
explicit dep needed in SPM, imported in source files).

### 2. Create public types: `CalendarAuthStatus`, `CalendarInfo`, `CalendarEvent`

File: `Sources/Calendar/CalendarTypes.swift`

```swift
public enum CalendarAuthStatus: Sendable, Equatable {
    case notDetermined, authorized, denied, restricted
}

public struct CalendarInfo: Sendable, Identifiable, Equatable { ... }
public struct CalendarEvent: Sendable, Identifiable, Equatable { ... }
```

### 3. Create `AttendeeInput` and `CalendarSnapshotInput`

File: `Sources/Calendar/CalendarSnapshotInput.swift`

The Sendable DTO that CalendarService builds from an EKEventDTO. AppCore passes this to DataStore for
persistence. All fields per the component spec.

### 4. Create `EKEventDTO` and `EventStoreProviding` protocol

File: `Sources/Calendar/EventStoreProviding.swift`

`EKEventDTO` is a public Sendable struct mirroring all EKEvent fields needed for filtering, mapping,
and snapshot creation. `EventStoreProviding` protocol with `authorizationStatus()`, `requestAccess()`,
`calendars()`, `events(in:calendars:)`, `refreshEvent(eventIdentifier:occurrenceStart:)`.

### 5. Create `LiveEventStore` (the real EventKit implementation)

File: `Sources/Calendar/LiveEventStore.swift`

Wraps `EKEventStore`, maps `EKEvent` to `EKEventDTO` promptly (releasing EKEvent references), runs
`events(matching:)` on a background executor. Maps `EKAuthorizationStatus` to `CalendarAuthStatus`.
Includes helpers for color hex conversion and email-from-mailto parsing (productionized from
EventKitLab).

### 6. Create `CalendarService`

File: `Sources/Calendar/CalendarService.swift`

`@MainActor @Observable` class with `auth`, `upcoming`, init taking `DataStore + MeetingCatalog +
EventStoreProviding`. Methods: `requestAccess()`, `calendars()`, `refreshUpcoming(window:)`,
`event(forKey:)`, `bestMatch(at:)`, `snapshot(forKey:)`, `startObserving()`.

Internal: composite key computation, meeting-like filter, enabled-calendar filtering (reads
`DataStore.settings().enabledCalendarIDs`), conference detection via catalog, snapshot field mapping,
`.EKEventStoreChanged` observation.

### 7. Add `markSnapshotStale` to DataStore

File: edit `Sources/DataStore/DataStore+Phase3_2.swift`

Add `markSnapshotStale(meetingID:)` method that sets `isStale = true` on the meeting's calendar
snapshot. Also add `recentMeetingsWithSnapshots(since:)` to query meetings with non-stale snapshots
in a date window (for the staleness check in `startObserving`).

### 8. Write unit tests

File: `Tests/CalendarTests/CalendarServiceTests.swift`

All tests use a `FakeEventStoreProvider` implementing `EventStoreProviding` with scripted data and an
in-memory `DataStore`. Tests per the component spec test plan:

- Authorization mapping (writeOnly->denied, restricted->restricted, request granted/denied)
- Calendar enumeration
- Enabled-calendar filtering (default all, specific set)
- Meeting-like filter (all-day excluded, solo excluded, conference solo included, birthday excluded)
- Conference detection (URL>notes priority, location fallback, nil when no match)
- bestMatch(at:) (in-progress conference preferred, imminent over none, nil outside window, tie-break)
- Snapshot mapping (all fields, attendees, mailto parsing, non-mailto nil, deleted returns nil)
- Composite key format
- event(forKey:) lookup and nil for unknown
- Staleness/observation (stale marked when event deleted, refresh called on store changed)

## Tests

- `writeOnlyMapsToDenied` -- CalendarAuthStatus mapping
- `restrictedMapsToRestricted` -- CalendarAuthStatus mapping
- `requestAccessGrantedUpdatesAuth` -- auth state transition
- `requestAccessDeniedUpdatesAuth` -- auth state transition
- `calendarsReturnsAllFromProvider` -- calendar enumeration
- `enabledCalendarFilterDefaultsAllOn` -- nil enabledCalendarIDs = all
- `enabledCalendarFilterExcludesDisabled` -- specific set filters
- `meetingLikeFilterExcludesAllDayAndSolo` -- filter correctness
- `meetingLikeFilterIncludesConferenceSolo` -- conference link satisfies
- `meetingLikeFilterExcludesBirthdayEvents` -- birthday guard
- `conferenceDetectionPrefersURLOverNotes` -- priority order
- `conferenceDetectionFallsToLocation` -- location fallback
- `conferenceDetectionNilWhenNoMatch` -- no false positives
- `bestMatchPicksInProgressConferenceEvent` -- scoring
- `bestMatchPicksImminentOverNone` -- imminent window
- `bestMatchReturnsNilOutsideWindow` -- 10-min boundary
- `bestMatchBreaksTieByNearestStart` -- tie-breaking
- `snapshotMapsAllCoreFields` -- full field mapping
- `snapshotMapsAttendeesToAttendeeInputs` -- attendee mapping
- `snapshotEmailFromMailtoParsesCorrectly` -- mailto extraction
- `snapshotEmailNilForNonMailtoURL` -- non-mailto handling
- `snapshotReturnsNilForDeletedEvent` -- graceful nil
- `compositeKeyIncludesAllComponents` -- key format
- `eventForKeyReturnsMatchFromUpcoming` -- lookup
- `eventForKeyReturnsNilForUnknownKey` -- miss
- `staleMarkedWhenEventDeleted` -- staleness via observation
- `refreshUpcomingCalledOnStoreChanged` -- observation triggers refresh
