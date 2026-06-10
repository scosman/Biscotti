---
status: complete
---

# Component: Calendar

## Purpose and Scope

The `Calendar` module is the read-only bridge between EventKit and the rest of the app. It owns the
`EKEventStore` lifecycle, calendar-access authorization, enabled-calendar filtering, upcoming-event
fetching with "meeting-like" filtering, conference-link detection, snapshot mapping (EKEvent to
Sendable DTOs the store can persist), and the `bestMatch(at:)` algorithm for automatic event
association at record time. It observes `.EKEventStoreChanged` and keeps its published `upcoming` list
current.

**Not its job:**

- Persistence schema. `CalendarSnapshot`, `Person`, `Meeting` models and their write methods live in
  `DataStore`. Calendar produces a `CalendarSnapshotInput` DTO; `AppCore` calls `DataStore.setSnapshot`
  / `setParticipants` with it.
- UI. Calendar-dependent views (`SettingsUI`, `OnboardingUI`, `MeetingListUI`, `HomeUI`,
  `MeetingDetailUI`) consume `CalendarService` and its DTOs; they do not import EventKit.
- Recording or transcription. Calendar has no dependency on `AudioCapture`, `Recording`, or
  `TranscriptionService`.
- Meeting detection. That is `MeetingDetection`. Both share `MeetingCatalog` (L0 dependency) but are
  otherwise independent.

---

## Public Interface

All types and methods below are the FIXED contract from `architecture.md` section 5. Signatures are
reproduced here with full parameter/return types and error behavior.

### Types

```swift
// MARK: - Auth

/// Maps EKAuthorizationStatus → a simpler enum.
/// .writeOnly and .restricted both map to .denied (not usable for read access).
public enum CalendarAuthStatus: Sendable, Equatable {
    case notDetermined, authorized, denied, restricted
}

// MARK: - Calendar info (settings / onboarding UI)

public struct CalendarInfo: Sendable, Identifiable, Equatable {
    public let id: String          // EKCalendar.calendarIdentifier
    public let title: String
    public let colorHex: String    // "#RRGGBB" from cgColor; fallback "#808080"
    public let sourceTitle: String // EKSource.title, for grouping in the UI
}

// MARK: - Live event DTO

/// A live, un-recorded calendar event. Never holds an EKEvent reference.
public struct CalendarEvent: Sendable, Identifiable, Equatable {
    public let id: String              // composite key (see Internal Design)
    public let title: String
    public let start: Date
    public let end: Date
    public let conferencePlatform: String?
    public let conferenceURL: URL?
    public let attendeeCount: Int
    public let calendarTitle: String
    public let calendarColorHex: String
    public var isMeetingLike: Bool     // conferenceURL != nil || attendeeCount >= 2
}

// MARK: - Snapshot input (Sendable DTO for DataStore)

/// Built by CalendarService from an EKEvent; handed to AppCore, which calls
/// DataStore.setSnapshot + setParticipants. Keeps EventKit out of DataStore.
public struct CalendarSnapshotInput: Sendable, Equatable {
    // Link keys
    public let eventIdentifier: String
    public let calendarItemIdentifier: String
    public let calendarItemExternalIdentifier: String
    public let occurrenceStartDate: Date
    public let compositeKey: String               // human-readable fallback (title+start+organizer)

    // Core fields
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let url: URL?
    public let timeZone: String?                  // TimeZone.identifier
    public let eventNotes: String
    public let status: String?                    // EKEventStatus description
    public let availability: String?              // EKEventAvailability description

    // Calendar provenance
    public let calendarTitle: String
    public let calendarColorHex: String?

    // Conferencing
    public let conferenceURL: URL?
    public let conferencePlatform: String?

    // Participants (Sendable value types)
    public let organizer: AttendeeInput?
    public let attendees: [AttendeeInput]
}

public struct AttendeeInput: Sendable, Equatable {
    public let name: String?
    public let email: String?                     // parsed from mailto: URL
    public let isCurrentUser: Bool
    public let role: String
    public let status: String
    public let type: String
}
```

### Seam protocol

```swift
/// Abstraction over EKEventStore for testability. All methods are synchronous or
/// async but never block callers on the main thread — implementations run heavy
/// work off-main.
public protocol EventStoreProviding: Sendable {
    func authorizationStatus() -> CalendarAuthStatus
    func requestAccess() async throws -> Bool
    func calendars() -> [CalendarInfo]
    /// Synchronous fetch (EKEventStore.events(matching:) is blocking).
    /// Must be called off the main thread.
    func events(in interval: DateInterval, calendars: [String]?) -> [EKEventDTO]
    /// Re-validate a previously fetched event. Returns nil if deleted.
    func refreshEvent(eventIdentifier: String, occurrenceStart: Date) -> EKEventDTO?
}

/// Thin, Sendable mirror of EKEvent fields (no EKEvent reference retained).
/// Internal to the Calendar module; only CalendarEvent / CalendarSnapshotInput
/// cross the module boundary.
public struct EKEventDTO: Sendable { /* all scalar fields from EKEvent */ }
```

The live implementation (`LiveEventStore`) wraps a real `EKEventStore` and maps EKEvent fields into
`EKEventDTO` promptly, releasing the EKEvent reference before returning.

### CalendarService

```swift
@MainActor @Observable
public final class CalendarService {
    // Observable state
    public private(set) var auth: CalendarAuthStatus
    public private(set) var upcoming: [CalendarEvent]

    public init(
        store: DataStore,
        catalog: any MeetingCatalog,
        provider: any EventStoreProviding = LiveEventStore()
    )

    /// Request full calendar access. Reports result into Permissions via
    /// CalendarAuthStatus (caller or AppCore maps to PermissionState).
    public func requestAccess() async -> CalendarAuthStatus

    /// All visible calendars (enabled + disabled). For settings/onboarding UI.
    public func calendars() async -> [CalendarInfo]

    /// Re-fetch meeting-like events in the given window. Updates `upcoming`.
    /// Called on launch, on .EKEventStoreChanged, and when enabled-calendar
    /// selection changes.
    public func refreshUpcoming(window: DateInterval) async

    /// Look up a cached CalendarEvent by its composite key string.
    /// Returns nil if the event is not in the current `upcoming` list.
    public func event(forKey key: String) -> CalendarEvent?

    /// Pick the best calendar event for auto-association at recording start.
    /// See Internal Design for the algorithm.
    public func bestMatch(at date: Date) -> CalendarEvent?

    /// Map the event identified by `key` to a CalendarSnapshotInput suitable
    /// for DataStore persistence. Returns nil if the event cannot be found
    /// (deleted since last refresh). Re-fetches from the provider to get the
    /// freshest fields.
    public func snapshot(forKey key: String) async -> CalendarSnapshotInput?

    /// Subscribe to .EKEventStoreChanged and auto-refresh. Also marks stale
    /// snapshots when a linked event is deleted.
    public func startObserving()
}
```

**Error behavior:** `CalendarService` never throws to callers. Authorization failures update `auth` to
`.denied`; fetch failures log via `os.Logger` and leave `upcoming` empty. `snapshot(forKey:)` returns
`nil` if the event cannot be located. The service degrades gracefully; the rest of the app continues
without calendar data.

---

## Internal Design Approach

### EKEventStore lifecycle

`LiveEventStore` holds a strong reference to `EKEventStore` for the app's lifetime (required for
`.EKEventStoreChanged` to fire). The `EKEventStore` is created once at init and never replaced.
`events(matching:)` is a synchronous, potentially blocking call; `LiveEventStore` dispatches it to a
non-main serial queue (or an unstructured `Task` on a background executor) and returns the mapped
`[EKEventDTO]`. No `EKEvent` reference escapes; fields are copied into `EKEventDTO` immediately.

### requestAccess + status mapping

```
EKAuthorizationStatus  →  CalendarAuthStatus
.notDetermined         →  .notDetermined
.fullAccess            →  .authorized
.authorized (deprecated) → .authorized
.writeOnly             →  .denied       // insufficient for read access
.denied                →  .denied
.restricted            →  .restricted
@unknown default       →  .denied
```

On `requestAccess()`: if `.notDetermined`, call `eventStore.requestFullAccessToEvents()`. Re-read
status afterward (the return `Bool` is not authoritative for edge cases). Update `self.auth`.
`AppCore` relays the result into `Permissions.calendar` for the unified permissions view.

### Enabled-calendar filtering

`CalendarService` reads `DataStore.settings().enabledCalendarIDs` to determine which calendars are
included. The pattern follows EventKitLab's validated approach:

- The stored value is `Set<String>?` (`nil` = all calendars enabled, the default).
- A private stored property `cachedEnabledIDs: Set<String>?` is loaded from `DataStore` on init and
  when settings change. This avoids an actor hop on every filter operation.
- When building the EventKit predicate, if `cachedEnabledIDs` is `nil`, pass `nil` for the calendars
  parameter (EventKit returns all). Otherwise, filter the provider's calendar list to the enabled set
  and pass those identifiers.
- Updates to enabled calendars (from SettingsUI / OnboardingUI) go through
  `DataStore.updateSettings`; `CalendarService` re-reads on the next `refreshUpcoming` call (or
  explicitly after a settings write, triggered by AppCore).

### Upcoming fetch

**Date-range windows:**

| Surface | Window |
|---|---|
| Menu bar "next meeting" | now ... now + 2h |
| Sidebar / Home "Upcoming" | now ... now + 24h |

`refreshUpcoming(window:)` calls `provider.events(in:calendars:)`, then applies the meeting-like
filter and conference detection, maps to `[CalendarEvent]`, sorts by `start`, and publishes to
`self.upcoming`.

**Meeting-like filter:**

```swift
func isMeetingLike(_ dto: EKEventDTO) -> Bool {
    guard !dto.isAllDay else { return false }
    guard dto.birthdayContactIdentifier == nil else { return false }   // guard per research gotcha #6
    let conference = catalog.conferenceMatch(
        inURL: dto.url, location: dto.location, notes: dto.notes
    )
    return conference != nil || dto.attendeeCount >= 2
}
```

All-day events and solo-no-conference events are excluded from `upcoming`. Birthday events are
explicitly excluded via the `birthdayContactIdentifier` guard (research gotcha #6: accessing certain
birthday-event fields can be problematic; explicit exclusion is safer and semantically correct).

### Conference detection

Productionized from EventKitLab's `ConferenceDetector`. The detection logic moves to
`MeetingCatalog.conferenceMatch(inURL:location:notes:)` (the seam from section 7 of the architecture).
`BundledMeetingCatalog` compiles the regex patterns once at init and caches the `NSRegularExpression`
instances (fixing the "compile on every call" note from EventKitLab).

Priority order (first match wins): `url` > `location` > `notes`. This matches the EventKitLab
implementation. The field priority is important because `event.url` is most likely to be a clean,
intentionally-set conference link, while `notes` may contain multiple URLs.

Supported platforms (V1, extensible): Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddle.

### Composite link key

The key that identifies a specific calendar event occurrence:

```swift
/// Stable-ish identifier for a calendar event occurrence.
/// Format: "{eventIdentifier}|{calendarItemIdentifier}|{occurrenceStartDateUnixTimestamp}"
static func compositeKey(
    eventIdentifier: String,
    calendarItemIdentifier: String,
    occurrenceStartDate: Date
) -> String {
    let ts = Int64(occurrenceStartDate.timeIntervalSince1970)
    return "\(eventIdentifier)|\(calendarItemIdentifier)|\(ts)"
}
```

This is the `CalendarEvent.id` and the key used by `event(forKey:)`, `snapshot(forKey:)`, and the
`.event(key)` route. `calendarItemExternalIdentifier` is stored in the snapshot as a supplementary
field for potential cross-device re-linking, but is NOT part of the composite key (it can change after
sync, per research findings).

### Snapshot mapping: EKEvent -> CalendarSnapshotInput -> CalendarSnapshot

`snapshot(forKey:)` re-fetches the event from the provider (to get the freshest data), then maps:

```
EKEventDTO  ──(CalendarService)──>  CalendarSnapshotInput  ──(AppCore + DataStore)──>  CalendarSnapshot + Person rows
```

Field mapping from `EKEventDTO` to `CalendarSnapshotInput`:

- `eventIdentifier`, `calendarItemIdentifier`, `calendarItemExternalIdentifier`,
  `occurrenceStartDate` -- direct copy from the DTO.
- `compositeKey` -- computed via the formula above.
- `title` -- `dto.title ?? "(No title)"`.
- `startDate`, `endDate`, `isAllDay`, `location`, `url`, `timeZone` (.identifier), `eventNotes`
  (from `dto.notes ?? ""`), `status`, `availability` -- direct copy, using the string-description
  helpers from EventKitLab.
- `calendarTitle`, `calendarColorHex` -- from the event's calendar.
- `conferenceURL`, `conferencePlatform` -- from `catalog.conferenceMatch(...)`.
- `organizer` -- mapped from `dto.organizer` via `AttendeeInput` (name, email parsed from
  `mailto:` URL, isCurrentUser, role/status/type as strings).
- `attendees` -- mapped from `dto.attendees` via `[AttendeeInput]`.

**Email-from-mailto parsing** reuses EventKitLab's `emailFromParticipantURL` pattern: check
`url.scheme == "mailto"`, then take `(url as NSURL).resourceSpecifier`. Returns `nil` for non-mailto
URLs (e.g. Exchange X500 addresses).

**Color hex** conversion reuses EventKitLab's approach: read `cgColor.components`, handle both RGB and
grayscale color spaces, format as `#RRGGBB`. Fall back to `#808080` if `cgColor` is nil.

**AppCore then calls:**

1. `DataStore.setSnapshot(calendarSnapshot, for: meetingID)` -- maps `CalendarSnapshotInput` fields
   into a `CalendarSnapshot` model instance (AppCore builds it; DataStore inserts it).
2. For each attendee in `input.attendees`: `DataStore.findOrCreatePerson(name:email:)` to get/create
   `Person` rows (dedup by email, then by name).
3. `DataStore.setParticipants(personIDs, organizer: organizerID, for: meetingID)`.

### bestMatch(at:) algorithm

Called at recording start (C4 association). Scans `upcoming` (already meeting-like-filtered) for the
best event to auto-associate:

```
1. Filter to events where:
   - event is in progress (start <= now <= end), OR
   - event is imminent (start is within 10 minutes after now)
2. Score each candidate:
   - +2 if conferenceURL != nil (prefer conference events)
   - +1 if currently in progress (vs. merely imminent)
3. Sort by score DESC, then by |start - now| ASC (nearest start wins ties).
4. Return the top candidate, or nil if no candidates.
```

The 10-minute imminent window handles the common case of starting a recording a few minutes before the
scheduled start. The algorithm is intentionally simple for V1; `AppCore` exposes "Change event" for
manual override if the auto-match is wrong.

### startObserving()

Subscribes to `NotificationCenter.default` for `.EKEventStoreChanged` (object: the provider's event
store). On each notification:

1. Call `refreshUpcoming(window:)` with the 24h window to update the `upcoming` list.
2. For any recent/active meetings with non-stale snapshots (query via DataStore), attempt to
   re-validate the linked event via `provider.refreshEvent(eventIdentifier:occurrenceStart:)`.
   If the event is no longer found (returns `nil`), mark the snapshot `isStale = true` via
   `DataStore`. If found, optionally update changed fields (title, attendees, etc.) on the snapshot.

The staleness check is scoped to meetings from the last 7 days to keep the re-fetch window small
(per research recommendation #4). `.EKEventStoreChanged` is coarse (no payload), so this is the best
available approach.

### Swift API gotchas (from research, addressed in implementation)

- **No `hasNotes`/`hasAttendees` in Swift.** Use `notes != nil`, `!(attendees?.isEmpty ?? true)`.
- **`EKParticipant.emailAddress` is not public.** Parse from `url` with `mailto:` scheme check.
- **`birthdayContactIdentifier` guard.** Filter out birthday events via nil-check before processing.
- **Thread safety.** `EKEventStore` used on a single serial context inside `LiveEventStore`; never
  shared across concurrent tasks.
- **Memory.** `EKEvent` references release the store; copy all fields to `EKEventDTO` promptly and
  drop the `EKEvent`.

---

## Dependencies

**Calendar depends on (internal):**

- `DataStore` (L0) -- reads `settings().enabledCalendarIDs`; AppCore uses DataStore to persist
  snapshots/participants, but Calendar itself only reads settings.
- `MeetingCatalog` (L0) -- `conferenceMatch(inURL:location:notes:)` for conference detection.

**Calendar depends on (external):**

- `EventKit` -- `EKEventStore`, `EKEvent`, `EKCalendar`, `EKParticipant`, `EKAuthorizationStatus`.

**What depends on Calendar:**

- `AppCore` (L2) -- constructs and owns `CalendarService`; calls `requestAccess`, `refreshUpcoming`,
  `bestMatch`, `snapshot`, `startObserving`; maps `CalendarSnapshotInput` to DataStore writes.
- `HomeUI` (L3a) -- reads `CalendarService.upcoming` for the home preview.
- `SettingsUI` (L3a) -- calls `CalendarService.calendars()` for the include/exclude UI.
- `OnboardingUI` (L3a) -- calls `requestAccess()` and `calendars()` during the onboarding wizard.
- `MeetingListUI` (L3a) -- reads `CalendarService.upcoming` for the sidebar "Upcoming" list.
- `MeetingDetailUI` (L3a) -- uses `CalendarService.event(forKey:)` for the `.event(key)` preview
  route; reads `CalendarContextData` (from DataStore) for the associated event block.

---

## Test Plan

All tests use `swift-testing` with `EventStoreProviding` fakes (scripted calendars/events) and an
in-memory `DataStore`. No EventKit framework needed at test time. Tests are in
`BiscottiKit/Tests/CalendarTests/`.

### Authorization

- **`writeOnlyMapsToDenied`** -- Fake provider returns `.writeOnly` status. Verify
  `CalendarService.auth == .denied`.
- **`restrictedMapsToRestricted`** -- Fake returns `.restricted`. Verify `auth == .restricted`.
- **`requestAccessGrantedUpdatesAuth`** -- Fake returns `.notDetermined` then `.fullAccess` after
  request. Verify `auth` transitions to `.authorized`.
- **`requestAccessDeniedUpdatesAuth`** -- Fake returns `.denied` after request. Verify
  `auth == .denied`.

### Calendar enumeration

- **`calendarsReturnsAllFromProvider`** -- Provider has 3 calendars across 2 sources. Verify
  `calendars()` returns all 3, with correct `id`, `title`, `colorHex`, `sourceTitle`.

### Enabled-calendar filtering

- **`enabledCalendarFilterDefaultsAllOn`** -- DataStore settings has `enabledCalendarIDs == nil`.
  Verify `refreshUpcoming` passes `nil` to provider (all calendars). Events from all calendars
  appear in `upcoming`.
- **`enabledCalendarFilterExcludesDisabled`** -- DataStore settings has `enabledCalendarIDs` =
  `{"cal-A"}`. Provider has events in cal-A and cal-B. Verify `upcoming` only contains cal-A events.

### Meeting-like filter

- **`meetingLikeFilterExcludesAllDayAndSolo`** -- Provider returns: (1) all-day event with 5
  attendees, (2) timed event with 1 attendee and no conference link, (3) timed event with 3
  attendees. Verify only event (3) appears in `upcoming`.
- **`meetingLikeFilterIncludesConferenceSolo`** -- Provider returns a timed event with 1 attendee
  but a Zoom conference URL. Verify it appears in `upcoming` (conference link satisfies the
  meeting-like condition).
- **`meetingLikeFilterExcludesBirthdayEvents`** -- Provider returns an event where
  `birthdayContactIdentifier != nil` with 3 attendees. Verify it is excluded from `upcoming`.

### Conference detection

- **`conferenceDetectionPrefersURLOverNotes`** -- Event has a Zoom link in `url` and a Google Meet
  link in `notes`. Verify `CalendarEvent.conferenceURL` is the Zoom link and `conferencePlatform` is
  `"zoom"`.
- **`conferenceDetectionFallsToLocation`** -- Event has no `url`, a Teams link in `location`, and
  a different link in `notes`. Verify the Teams link from `location` is used.
- **`conferenceDetectionNilWhenNoMatch`** -- Event has no conference links in any field. Verify
  `conferenceURL == nil` and `conferencePlatform == nil`.

### bestMatch(at:)

- **`bestMatchPicksInProgressConferenceEvent`** -- Two events: (A) in progress, no conference;
  (B) in progress, has conference URL. Verify `bestMatch(at: now)` returns B.
- **`bestMatchPicksImminentOverNone`** -- One event starting in 5 minutes. Verify `bestMatch`
  returns it.
- **`bestMatchReturnsNilOutsideWindow`** -- One event starting in 30 minutes. Verify `bestMatch`
  returns `nil` (outside the 10-minute imminent window).
- **`bestMatchBreaksTieByNearestStart`** -- Two events: (A) in progress since 30 min ago,
  conference; (B) started 2 min ago, conference. Verify B wins (nearer start).

### Snapshot mapping

- **`snapshotMapsAllCoreFields`** -- Provider returns a fully-populated event. Call
  `snapshot(forKey:)`. Verify every field on `CalendarSnapshotInput` matches the source event
  (title, dates, location, notes, status, availability, calendar title/color, conference URL/platform,
  link keys).
- **`snapshotMapsAttendeesToAttendeeInputs`** -- Event has 3 attendees (one organizer). Verify
  `CalendarSnapshotInput.attendees` has 3 entries with correct name, email (from mailto), role,
  status, type, isCurrentUser. Verify `organizer` is populated.
- **`snapshotEmailFromMailtoParsesCorrectly`** -- Attendee with `mailto:alice@example.com` URL.
  Verify `email == "alice@example.com"`.
- **`snapshotEmailNilForNonMailtoURL`** -- Attendee with an X500-style URL. Verify `email == nil`.
- **`snapshotReturnsNilForDeletedEvent`** -- Provider's `refreshEvent` returns nil for the key.
  Verify `snapshot(forKey:)` returns `nil`.

### Composite key

- **`compositeKeyIncludesAllComponents`** -- Verify the key string contains eventIdentifier,
  calendarItemIdentifier, and occurrenceStartDate unix timestamp, separated by `|`.

### Staleness / observation

- **`staleMarkedWhenEventDeleted`** -- Start observing. Simulate `.EKEventStoreChanged`. Provider's
  `refreshEvent` returns nil for a previously-snapshotted event. Verify DataStore snapshot has
  `isStale == true`.
- **`refreshUpcomingCalledOnStoreChanged`** -- Start observing. Post `.EKEventStoreChanged`. Verify
  `upcoming` is refreshed (provider's events call count incremented).

### event(forKey:)

- **`eventForKeyReturnsMatchFromUpcoming`** -- Refresh upcoming with 2 events. Call
  `event(forKey:)` with the first event's composite key. Verify it returns the correct event.
- **`eventForKeyReturnsNilForUnknownKey`** -- Call `event(forKey: "nonexistent")`. Verify nil.

---

### Contract gap note

The architecture specifies `CalendarService` reads `DataStore.settings().enabledCalendarIDs`, but the
current `AppSettings` model does not yet have an `enabledCalendarIDs` field. The architecture section
4.1 specifies adding it as `[String]?` (nil = all enabled) in a `DataStoreSchemaV2` lightweight
migration. This dependency is a prerequisite for the Calendar module -- the schema migration must land
first (or concurrently). No gap in the contract itself; this is a sequencing note.
