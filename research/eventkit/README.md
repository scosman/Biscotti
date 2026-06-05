# EventKit / Calendar Research

## Summary

EventKit on macOS 15 provides everything Steak needs for read-only calendar integration. Request full access via `EKEventStore.requestFullAccessToEvents()` (requires the `NSCalendarsFullAccessUsageDescription` Info.plist key); enumerate calendars with `eventStore.calendars(for: .event)` so the user can toggle which ones feed into the app; fetch events with date-range predicates and copy all relevant fields into our own `Meeting` model at snapshot time. The API surface is mature, stable, and well-documented. The main subtlety is identifier instability for recurring/synced events (use a composite key) and the absence of a first-class "video conference URL" property (parse it from `notes`, `location`, and `url` fields with regex).

> **Validated (Phase 10 / V2, Apple M4, macOS 15).** The full approach was exercised end-to-end against a real calendar account via the EventKitLab experiment. All core flows passed: permission request (full access + contacts), denial handling, calendar enumeration/filtering, date-range event fetching, full field availability in event detail, and conference-URL detection on real meetings. Three takeaways folded back here: **(1)** **Punt Contacts enrichment for V1** — it works mechanically but adds a second permission prompt for little value (resolves Open Question #3). **(2)** Conference detection via regex is sound and worked on real meetings, but the pattern set needs ongoing tuning for more platforms/URL formats. **(3)** Implementation gotcha: SwiftUI calendar-filter state must be an **observable stored property** — a `UserDefaults`-backed computed property is not tracked by `@Observable` and produces stale, non-live toggles (see Risks & Gotchas #9). Full per-test results: [`experiments/EventKitLab/VALIDATION.md`](../../experiments/EventKitLab/VALIDATION.md).

---

## Key Questions & Findings

### 1. How do we request and obtain calendar access on macOS 15 (full-access model, prompt UX)?

**The API:** Use `EKEventStore.requestFullAccessToEvents()` (async/await) or its completion-handler variant `requestFullAccessToEvents(completion:)`. This was introduced alongside the iOS 17 / macOS 14 SDK and replaces the older `requestAccess(to:)` method. Since we target macOS 15+ and build with Xcode 26.3, we use the newer API exclusively.

**Info.plist key:** Add `NSCalendarsFullAccessUsageDescription` with a user-facing string explaining why the app needs calendar access. Example:

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Steak reads your calendar to show upcoming meetings and enrich recordings with event details like title, participants, and description.</string>
```

This string is displayed verbatim in the system permission alert. Without it, TCC silently denies the request.

**Authorization flow:**

```swift
let eventStore = EKEventStore()

// Check current status first
let status = EKEventStore.authorizationStatus(for: .event)

switch status {
case .notDetermined:
    // Prompt the user
    let granted = try await eventStore.requestFullAccessToEvents()
    // granted == true means .fullAccess
case .fullAccess, .authorized:
    // .authorized is deprecated (same raw value as .fullAccess) but still
    // present in the enum — handle it for exhaustiveness.
    break
case .denied, .restricted:
    // Direct user to System Settings > Privacy & Security > Calendars
    break
case .writeOnly:
    // Insufficient; we need full (read) access. Re-request or guide user.
    break
@unknown default:
    break
}
```

**Authorization status values** (`EKAuthorizationStatus`):
- `.notDetermined` -- user has not been prompted yet
- `.fullAccess` -- read and write access granted (what we need; introduced iOS 17 / macOS 14)
- `.writeOnly` -- can write but not read (insufficient for us; introduced iOS 17 / macOS 14)
- `.authorized` -- **deprecated** but still present in the enum (same raw value as `.fullAccess`). Must be handled in switches for exhaustiveness even on macOS 15+. Treat identically to `.fullAccess`.
- `.denied` -- user explicitly denied
- `.restricted` -- device policy prevents access

**Prompt UX:** The system shows a standard macOS alert with the app name, the usage-description string, and "Don't Allow" / "Allow Full Access" buttons. The prompt appears only once; subsequent calls return the stored decision. The user can later change their choice in System Settings > Privacy & Security > Calendars. Our app should detect denial and show a helpful message directing the user there.

**Sandbox note:** For sandboxed apps, the entitlement `com.apple.security.personal-information.calendars` must also be set to `true` in the `.entitlements` file. For non-sandboxed apps (our experiments), only the Info.plist key is required. The production app's sandbox/notarization strategy is covered in R4.

**Sources:**
- [Apple: requestFullAccessToEvents(completion:)](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:))
- [Apple: NSCalendarsFullAccessUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription)
- [Apple: Accessing Calendar using EventKit and EventKitUI](https://developer.apple.com/documentation/EventKit/accessing-calendar-using-eventkit-and-eventkitui)
- [Create with Swift: Getting access to the user's calendar](https://www.createwithswift.com/getting-access-to-the-users-calendar/)

---

### 2. How do we enumerate calendars so the user can filter which are included?

**Listing calendars:**

```swift
let allCalendars: [EKCalendar] = eventStore.calendars(for: .event)
```

This returns every event calendar the user has configured, across all sources (iCloud, Google/CalDAV, Exchange, local, subscribed, birthdays).

**EKCalendar properties useful for the filter UI:**

| Property | Type | Description |
|---|---|---|
| `calendarIdentifier` | `String` | Stable UUID for the calendar. Persist this to remember the user's include/exclude choices across launches. |
| `title` | `String` | Display name (e.g. "Work", "Family", "Birthdays"). Show this in the settings toggle list. |
| `color` | `NSColor` | macOS-only calendar color property. Display alongside the title for visual identification. |
| `cgColor` | `CGColor` | Cross-platform calendar color property (available on both macOS and iOS). Use this for portable code. |
| `source` | `EKSource` | The account/source the calendar belongs to. |
| `source.title` | `String` | Account name (e.g. "iCloud", "Gmail", "Exchange"). Useful for grouping calendars in the UI. |
| `source.sourceType` | `EKSourceType` | Account type enum: `.local`, `.calDAV`, `.exchange`, `.subscribed`, `.birthdays`. |
| `type` | `EKCalendarType` | Calendar type: `.local`, `.calDAV`, `.exchange`, `.subscription`, `.birthday`. |
| `isSubscribed` | `Bool` | Whether it is a subscribed (read-only) calendar. |
| `isImmutable` | `Bool` | Whether the calendar's properties can be modified. |
| `allowedEntityTypes` | `EKEntityMask` | Whether it supports `.event`, `.reminder`, or both. |

**Recommended filter UI approach:**
1. List all calendars grouped by `source.title` (e.g. "iCloud", "Google").
2. Show each calendar's `title` and `color` with a toggle.
3. Persist the user's selections as a `Set<String>` of `calendarIdentifier` values in UserDefaults (or our SwiftData settings model).
4. Default: all calendars enabled. The user disables ones they want excluded (e.g. "Family", "Birthdays").

**Fetching events from selected calendars only:**

```swift
let selectedCalendars: [EKCalendar] = allCalendars.filter { enabledIDs.contains($0.calendarIdentifier) }
let predicate = eventStore.predicateForEvents(
    withStart: startDate,
    end: endDate,
    calendars: selectedCalendars  // nil = all calendars
)
let events: [EKEvent] = eventStore.events(matching: predicate)
```

Passing the filtered calendar array to `predicateForEvents` means EventKit handles the filtering server-side -- we do not need to post-filter.

**Sources:**
- [Apple: EKCalendar](https://developer.apple.com/documentation/eventkit/ekcalendar)
- [Apple: EKSource](https://developer.apple.com/documentation/eventkit/eksource)
- [Andrew Bancroft: Creating Calendars with Event Kit and Swift](https://www.andrewcbancroft.com/2015/06/17/creating-calendars-with-event-kit-and-swift/)
- [Hacking with Swift: How to identify an EKCalendar](https://www.hackingwithswift.com/forums/swift/how-to-identify-an-ekcalendar-to-store-a-user-calendar-selection/4119)

---

### 3. What event fields are available, and in what shape?

This is the core data-availability report. Every field listed below is available on `EKEvent` (some inherited from `EKCalendarItem`) and could enrich our `Meeting` data model.

#### 3a. EKEvent Own Properties

| Property | Type | R/W | Description |
|---|---|---|---|
| `eventIdentifier` | `String` | R | Unique ID for the event. Shared across all occurrences of a recurring event. May change if calendar is changed or after sync. |
| `startDate` | `Date` | R/W | Event start date and time. |
| `endDate` | `Date` | R/W | Event end date and time. |
| `isAllDay` | `Bool` | R/W | Whether this is an all-day event (time component ignored). |
| `availability` | `EKEventAvailability` | R/W | Scheduling availability: `.notSupported`, `.busy`, `.free`, `.tentative`, `.unavailable`. |
| `status` | `EKEventStatus` | R | Event status: `.none`, `.confirmed`, `.tentative`, `.canceled`. |
| `organizer` | `EKParticipant?` | R | The event organizer (read-only). See EKParticipant details below. |
| `structuredLocation` | `EKStructuredLocation?` | R/W | Location with optional geocoordinates. See below. |
| `occurrenceDate` | `Date` | R | The original occurrence date for a recurring event instance. |
| `isDetached` | `Bool` | R | Whether this occurrence has been individually modified from its recurring series. |
| `birthdayContactIdentifier` | `String?` | R | Contact identifier if this is a birthday event. Non-nil means birthday event. |

#### 3b. Inherited from EKCalendarItem

| Property | Type | R/W | Description |
|---|---|---|---|
| `title` | `String` | R/W | Event title. |
| `notes` | `String?` | R/W | Event description/notes. Often contains conference links, agenda, etc. |
| `location` | `String?` | R/W | Plain-text location string. May contain a video conference URL. |
| `url` | `URL?` | R/W | Associated URL. Sometimes set to the conference join link. |
| `calendar` | `EKCalendar` | R/W | The calendar this event belongs to. |
| `calendarItemIdentifier` | `String` | R | Local database identifier. Stable within the local store, but locates only the first occurrence of a recurring event. |
| `calendarItemExternalIdentifier` | `String` | R | Server-side identifier (e.g. CalDAV/iCloud UID). Non-optional in Swift, but may change after sync or calendar migration. See [Apple docs](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier). |
| `attendees` | `[EKParticipant]?` | R | Array of attendees. Read-only. See EKParticipant details below. Check presence with `!(attendees?.isEmpty ?? true)`. |
| `alarms` | `[EKAlarm]?` | R/W | Alarm/reminder list. Probably not useful for our model. Check presence with `!(alarms?.isEmpty ?? true)`. |
| `recurrenceRules` | `[EKRecurrenceRule]?` | R/W | Recurrence rules (daily, weekly, etc.). Check presence with `recurrenceRules?.isEmpty == false`. |
| `timeZone` | `TimeZone?` | R/W | The event's time zone. |

> **Swift API note:** The Objective-C convenience properties `hasNotes`, `hasAttendees`, `hasAlarms`, and `hasRecurrenceRules` exist on `EKCalendarItem` but are **not available in Swift** (they are ObjC-only and will not compile). In Swift, use the underlying optional properties directly: `notes != nil`, `!(attendees?.isEmpty ?? true)`, `!(alarms?.isEmpty ?? true)`, `recurrenceRules?.isEmpty == false`. See [Apple: hasNotes (ObjC only)](https://developer.apple.com/documentation/eventkit/ekcalendaritem/hasnotes?language=objc).
| `creationDate` | `Date?` | R | When the event was created. |
| `lastModifiedDate` | `Date?` | R | When the event was last modified. |

#### 3c. EKParticipant (Attendees & Organizer)

All properties are **read-only**. EventKit does not allow modifying participants programmatically.

| Property | Type | Description |
|---|---|---|
| `name` | `String?` | Display name of the participant. |
| `url` | `URL` | URL associated with the participant. For CalDAV events, often a `mailto:` URI from which the email can be extracted via `url.resourceSpecifier` (though this is not always reliable). |
| `isCurrentUser` | `Bool` | Whether this participant represents the device owner's account. Useful for identifying "me" in the attendee list. |
| `participantRole` | `EKParticipantRole` | `.unknown`, `.required`, `.optional`, `.chair`, `.nonParticipant`. |
| `participantStatus` | `EKParticipantStatus` | `.unknown`, `.pending`, `.accepted`, `.declined`, `.tentative`, `.delegated`, `.completed`, `.inProcess`. |
| `participantType` | `EKParticipantType` | `.unknown`, `.person`, `.room`, `.resource`, `.group`. |
| `contactPredicate` | `NSPredicate` | Predicate for looking up this participant in the Contacts framework (CNContactStore). Useful for enriching with full contact details, company name, photo, etc. |

**Note on email addresses:** There is no public `emailAddress` property on `EKParticipant`. The common workaround is to parse `url.resourceSpecifier` for `mailto:` scheme URLs, or to use `contactPredicate` with the Contacts framework to look up the associated contact record and retrieve the email from there. The private `EKAttendee` subclass has an email field, but relying on private API is not recommended.

#### 3d. EKStructuredLocation

| Property | Type | Description |
|---|---|---|
| `title` | `String?` | Location name/label. |
| `geoLocation` | `CLLocation?` | Geographic coordinates (latitude, longitude, altitude, etc.). |
| `radius` | `Double` | Radius in meters (0 = default). Primarily used for geofence alarms. |

#### 3e. EKCalendar (on the event's `.calendar` property)

| Property | Type | Description |
|---|---|---|
| `calendarIdentifier` | `String` | Stable UUID for the calendar. |
| `title` | `String` | Calendar display name. |
| `color` | `NSColor` | macOS-only calendar color. |
| `cgColor` | `CGColor` | Cross-platform calendar color (available on both macOS and iOS). |
| `type` | `EKCalendarType` | `.local`, `.calDAV`, `.exchange`, `.subscription`, `.birthday`. |
| `source` | `EKSource` | The account this calendar belongs to. |
| `source.title` | `String` | Account name (e.g. "iCloud"). |
| `source.sourceType` | `EKSourceType` | `.local`, `.calDAV`, `.exchange`, `.subscribed`, `.birthdays`. |
| `isSubscribed` | `Bool` | Whether this is a subscribed calendar. |
| `isImmutable` | `Bool` | Whether the calendar is immutable. |
| `allowedEntityTypes` | `EKEntityMask` | Supported entity types. |

#### 3f. Video Conferencing / Join URL

**There is no first-class "conferencing URL" property on EKEvent.** Apple's `EKVirtualConferenceProvider` / `EKVirtualConferenceDescriptor` system is designed for apps that *provide* virtual conferencing to Calendar.app, not for *reading* conference info from arbitrary events. Zoom, Google Meet, and Teams do not currently use this extension to embed their join URLs in a structured way.

**Practical approach (widely used, proven in production apps):** Parse join URLs from three fields using regex:

1. `event.url` -- sometimes set to the join link directly.
2. `event.notes` -- most commonly where the join link is embedded (Zoom, Meet, Teams all do this).
3. `event.location` -- some calendar providers put the join link here.

**Regex patterns for common platforms:**

| Platform | Pattern |
|---|---|
| Zoom | `https?://[\\w.-]*zoom\\.us/j/\\d+[^\\s]*` |
| Google Meet | `https?://meet\\.google\\.com/[a-z-]+` |
| Microsoft Teams | `https?://teams\\.microsoft\\.com/l/meetup-join/[^\\s]+` |
| Webex | `https?://[\\w.-]*webex\\.com/[^\\s]+` |
| Slack Huddle | `https?://app\\.slack\\.com/huddle/[^\\s]+` |

This is the approach used by the open-source [meeting-reminder](https://github.com/nilBora/meeting-reminder) macOS app and others. It is reliable in practice because calendar providers consistently embed join links in the notes/location/url fields.

**Sources:**
- [Apple: EKEvent](https://developer.apple.com/documentation/eventkit/ekevent)
- [Apple: EKCalendarItem](https://developer.apple.com/documentation/eventkit/ekcalendaritem)
- [Apple: EKParticipant](https://developer.apple.com/documentation/eventkit/ekparticipant)
- [Apple: EKStructuredLocation](https://developer.apple.com/documentation/eventkit/ekstructuredlocation)
- [Apple: EKVirtualConferenceDescriptor](https://developer.apple.com/documentation/eventkit/ekvirtualconferencedescriptor)
- [meeting-reminder (GitHub)](https://github.com/nilBora/meeting-reminder)
- [Apple Developer Forums: virtual meeting extension](https://developer.apple.com/forums/thread/783375)

---

### 4. What is the right way to COPY event data into our own model so we do not depend on the EventKit link persisting?

#### The Problem

EventKit identifiers are not perfectly stable:

- **`eventIdentifier`**: All occurrences of a recurring event share the same identifier. Can change if the event's calendar is changed or after a sync operation.
- **`calendarItemIdentifier`**: Local database ID. Stable locally, but `calendarItem(withIdentifier:)` returns only the first occurrence of a recurring event.
- **`calendarItemExternalIdentifier`**: Non-optional `String` in Swift, but server-assigned. Can change after sync, especially with Exchange calendars. May be empty or a temporary value immediately after event creation.
- **Detached occurrences**: When a single occurrence of a recurring event is modified, it gets a new `eventIdentifier` and `isDetached` becomes `true`.

#### Recommended Strategy

**Snapshot-and-store at meeting creation time.** When Steak associates a recording with a calendar event:

1. **Copy all needed fields** into our own SwiftData `CalendarEventSnapshot` model (a sub-item of `Meeting`, so it can be cleared in one swipe if the pairing was wrong, per app_overview.md).
2. **Store a composite key** for re-linking:

```swift
struct EventLinkKey: Codable, Hashable {
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let occurrenceStartDate: Date
}
```

Using both identifiers plus the occurrence date handles recurring events (same `eventIdentifier`, different dates) and gives a fallback if one identifier changes after sync.

3. **Store `calendarItemExternalIdentifier`** as a supplementary field for cross-device matching, but do not rely on it as a primary key.

4. **Treat the snapshot as the source of truth.** The app should function correctly even if the original calendar event is deleted, moved, or the user revokes calendar access. The snapshot preserves the title, attendees, description, etc. that were captured at recording time.

5. **Optional re-sync:** Periodically (or on `EKEventStoreChangedNotification`), attempt to re-fetch the linked event using the composite key. If found, update the snapshot with any changes. If not found, keep the stale snapshot and mark it as unlinked.

#### Change Notifications

```swift
NotificationCenter.default.addObserver(
    forName: .EKEventStoreChanged,
    object: eventStore,
    queue: .main
) { _ in
    // The notification carries no detail about what changed.
    // Re-fetch upcoming events and diff against our cached list.
    self.refreshUpcomingEvents()
}
```

Key behaviors:
- Posted whenever *any* change occurs in the Calendar database (events, reminders, any calendar).
- Contains **no information** about what specifically changed. A full re-fetch and diff is the only option.
- The `EKEventStore` instance must be kept alive (strong reference) for notifications to fire.
- `refresh()` (inherited from `EKObject`, not defined on `EKEvent` directly) can be called on a previously fetched event to check if it is still valid and merge the latest saved values. Returns `false` if the event has been deleted. See [Apple: EKObject.refresh()](https://developer.apple.com/documentation/eventkit/ekobject/refresh()).

#### Validating a Previously Fetched Event

```swift
if event.refresh() {
    // Event is still valid; properties have been updated
} else {
    // Event has been deleted or is otherwise invalid; stop using it
}
```

**Sources:**
- [Apple: eventIdentifier](https://developer.apple.com/documentation/eventkit/ekevent/eventidentifier)
- [Apple: calendarItemExternalIdentifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)
- [Apple: EKEventStoreChangedNotification](https://developer.apple.com/documentation/eventkit/ekeventstorechangednotification)
- [Filip Nemecek: How to monitor system calendar for changes with EventKit](https://nemecek.be/blog/63/how-to-monitor-system-calendar-for-changes-with-eventkit)
- [WWDC 2010 Session 136: Calendar Integration with Event Kit](https://asciiwwdc.com/2010/sessions/136)
- [DEV Community: Building Calendar ToDo with SwiftUI and EventKit](https://dev.to/yuugooku/building-calendar-todo-turning-calendar-events-into-a-done-list-with-swiftui-and-eventkit-1c9b)

---

## Recommendation

The concrete approach the experiment and production app should implement:

### Permission Flow
1. Add `NSCalendarsFullAccessUsageDescription` to Info.plist.
2. On first launch (or when user navigates to a calendar-dependent feature), check `EKEventStore.authorizationStatus(for: .event)`.
3. If `.notDetermined`, call `try await eventStore.requestFullAccessToEvents()`.
4. If `.denied` or `.restricted`, show a message directing the user to System Settings > Privacy & Security > Calendars.
5. For sandboxed builds, also add `com.apple.security.personal-information.calendars = true` to the entitlements file.

### Calendar Filtering
1. Call `eventStore.calendars(for: .event)` to get all calendars.
2. Present them in Settings, grouped by `source.title`, showing `title` and `color`, with toggles.
3. Persist enabled calendar identifiers as a `Set<String>` of `calendarIdentifier` values.
4. Default to all enabled; user disables unwanted ones.

### Event Fetching
1. Build a date-range predicate with `eventStore.predicateForEvents(withStart:end:calendars:)`, passing the user's selected calendars.
2. Call `eventStore.events(matching:)` for synchronous fetch.
3. Sort by `startDate`.
4. For the tray app "upcoming" view, query a rolling window (e.g. now to +24 hours).
5. Subscribe to `.EKEventStoreChanged` to refresh when the calendar database changes.

### Data Snapshot for Meeting Model
Create a `CalendarEventSnapshot` SwiftData model (sub-item of `Meeting`) that copies these fields at pairing time:

```swift
@Model
class CalendarEventSnapshot {
    // -- Link key (for re-sync) --
    var eventIdentifier: String
    var calendarItemIdentifier: String
    var calendarItemExternalIdentifier: String  // non-optional in Swift (per Apple's declaration)
    var occurrenceStartDate: Date

    // -- Core fields --
    var title: String
    var notes: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var url: URL?
    var timeZone: String?       // TimeZone.identifier

    // -- Status --
    var availability: String    // EKEventAvailability raw description
    var status: String          // EKEventStatus raw description

    // -- Organizer (flattened) --
    var organizerName: String?
    var organizerEmail: String? // parsed from url.resourceSpecifier
    var organizerIsCurrentUser: Bool

    // -- Calendar info --
    var calendarTitle: String
    var calendarColorHex: String?

    // -- Attendees (as sub-array or JSON) --
    var attendees: [AttendeeSnapshot]

    // -- Conferencing (extracted) --
    var conferenceURL: URL?
    var conferencePlatform: String? // "zoom", "meet", "teams", etc.

    // -- Metadata --
    var snapshotDate: Date      // when this snapshot was taken
    var lastSyncDate: Date?     // when we last verified against EventKit
    var isStale: Bool           // true if the source event was deleted/not found
}

struct AttendeeSnapshot: Codable {
    var name: String?
    var email: String?          // parsed from url.resourceSpecifier
    var isCurrentUser: Bool
    var role: String            // EKParticipantRole description
    var status: String          // EKParticipantStatus description
    var type: String            // EKParticipantType description
}
```

### Video Conference URL Extraction
Implement a `ConferenceURLDetector` utility that scans `event.url`, `event.notes`, and `event.location` with regex patterns for Zoom, Google Meet, Teams, Webex, and Slack. Return the first match along with the detected platform name. This is a well-proven approach used by multiple production macOS calendar apps.

---

## Risks & Gotchas

1. **Identifier instability.** `eventIdentifier` and `calendarItemExternalIdentifier` can both change after sync operations or calendar migrations. Never rely on a single identifier as a stable foreign key. Use a composite key (identifier + occurrence date) and treat the snapshot as the source of truth.

2. **Recurring events share identifiers.** All occurrences of a recurring event have the same `eventIdentifier`. When fetching by identifier, `event(withIdentifier:)` returns only the first occurrence. Always use date-range predicates for fetching, and store `occurrenceStartDate` alongside the identifier.

3. **No structured conferencing data.** Apple's `EKVirtualConferenceProvider` system is provider-side (for apps adding conferencing *to* Calendar), not consumer-side. Zoom, Meet, and Teams do not use it. We must regex-parse join URLs from notes/location/url. This is fragile to URL format changes but is the industry-standard approach.

4. **`EKEventStoreChangedNotification` is coarse.** It fires for any change to any calendar item, with no payload indicating what changed. We must re-fetch and diff. For the tray app's "upcoming meetings" view, this means periodic re-queries. Keep the query window small to limit cost.

5. **EKParticipant email is not public API.** The `url` property sometimes contains a `mailto:` URI, but `url.resourceSpecifier` is not always a valid email address (especially for Exchange accounts where it may be an X500 address). Use `contactPredicate` with `CNContactStore` for reliable contact matching, but note this requires Contacts access (separate permission).

6. **`birthdayContactIdentifier` crashes (historical).** Older SDKs had bugs where accessing this property on birthday events caused crashes. Guard access defensively or simply filter out birthday calendar events (`.type == .birthday` on the calendar) to avoid the issue entirely.

7. **Thread safety.** `EKEventStore` is not documented as thread-safe. Create and use it on a single actor/thread. The `events(matching:)` call is synchronous and can block; call it off the main thread.

8. **Memory.** `EKEvent` objects hold internal references to the `EKEventStore`. Holding many events in memory keeps the store alive. Copy fields into our own model and release the `EKEvent` references promptly.

9. **`@Observable` does not track `UserDefaults`-backed computed properties (found in Phase 10 V2).** The calendar-filter selection (enabled calendar IDs) was first implemented as a computed property reading/writing `UserDefaults` directly. Under the Observation framework this produced stale UI — toggling a calendar persisted correctly but the list did not re-render until the view re-appeared. The Observation macro only tracks **stored** properties. Fix: keep an observable stored property (e.g. `private var savedEnabledIDs: Set<String>?`, `nil` = all-enabled default) as the source of truth and persist to `UserDefaults` in its setter; expose a computed accessor that resolves the default. This is the same class of bug seen in the AudioLab experiment (Phase 6b live-refresh). Applies to any persisted UI state in the production app.

---

## Open Questions for the Team

1. **All-day events:** Should the app show/record all-day events (e.g. holidays, OOO markers), or filter them out? They are unlikely to be "meetings" but could be useful context. Recommend filtering by default with a setting to include.

2. **Birthday / subscribed calendars:** Should we hide birthday and subscribed calendars by default in the filter UI, since they never have meetings? Or let the user toggle them off manually?

3. ~~**Contacts integration for attendee enrichment:**~~ **RESOLVED (Phase 10 V2 — defer/drop for V1).** Validation showed the `contactPredicate` lookup works mechanically but returned zero matches for a tester who doesn't maintain Contacts — and it costs a second permission prompt (`NSContactsUsageDescription`). EventKit's own attendee data (name, role, status, type, and `mailto:`-parsed email) is sufficient for the Meeting model. Drop Contacts enrichment from V1; revisit only if a concrete need emerges.

4. **Re-sync frequency:** How aggressively should we re-sync snapshots against EventKit? Options range from "never" (pure snapshot) to "on every `EKEventStoreChanged` notification" to "on app launch + notification." More aggressive sync keeps data fresh but adds complexity. Recommend: re-sync on notification + app launch, mark stale if source event deleted.

5. **Conference URL heuristics:** The regex approach for extracting join URLs works well for Zoom, Meet, and Teams. Should we also try to detect phone dial-in numbers from the notes field? This could be useful for non-video meetings but adds parsing complexity.

6. **Recurrence display:** When a user records a recurring meeting (e.g. weekly 1:1), should past recordings show as a "series" grouped by the shared `eventIdentifier`? This could be a nice UX feature for recurring meetings but needs design thought.

7. **Event matching strategy at recording time:** When the user starts recording, how do we pick which calendar event to associate? Options: (a) auto-match to the event currently in progress or starting within N minutes, (b) let the user pick from a list of nearby events, (c) both with auto-suggestion. Recommend (c) -- auto-suggest the best match but let the user override.
