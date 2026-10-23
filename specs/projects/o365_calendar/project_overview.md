---
status: draft
---

# Microsoft 365 Calendar (Graph)

Biscotti should read Microsoft 365 calendars directly through Microsoft Graph, alongside or instead of EventKit/Apple Calendar. Everything that uses calendar data today should work the same for M365 events: upcoming-meeting notifications, "start recording?" prompts, auto-association, speaker matching from attendees, and meeting details in summaries.

## Why

- EWS is going away. Microsoft says "October 2026: EWS starts to be disabled globally… April 2027: EWS is fully disabled" ([Learn](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online)).
- Apple says Calendar on Mac uses EWS for Exchange accounts and that a Graph-based update is planned for "a future update to macOS 27" ([Apple](https://support.apple.com/guide/deployment/integrate-with-microsoft-exchange-dep158966b23/web)).
- Graph gives us data EventKit doesn't expose cleanly: `onlineMeeting.joinUrl`, `onlineMeetingProvider` (`teamsForBusiness`…), `iCalUId`, and attendee response status.

## Design

### Where it lives

- New module **`GraphCalendar`** in `Packages/BiscottiKit`. Nothing in upstream depends on it.
- **`GraphEventStore: EventStoreProviding`** implements the existing seam in `Calendar/EventStoreProviding.swift` and maps Graph JSON to the existing `EKEventDTO` / `AttendeeDTO` / `CalendarInfo` types, so `CalendarService` keeps working unchanged.
- **`CompositeEventStore: EventStoreProviding`** merges providers (EventKit + Graph).
  - It dedupes by iCalUID: Graph `iCalUId` against EventKit `calendarItemExternalIdentifier`, so an event visible in both sources appears once. That these two values match for Exchange events is **UNVERIFIED**; test on hardware.
  - On a duplicate, Graph wins.
- Touch points in upstream code (keep them small):
  - `AppCore/AppCore+Live.swift`: construct `CalendarService(store:catalog:provider: CompositeEventStore(...))`.
  - `SettingsUI/SettingsCalendarSection.swift`: add a Microsoft 365 account row.
  - `CalendarService.startObserving`: today it listens for `.EKEventStoreChanged`; add a provider-agnostic "changed" signal so Graph polling can trigger `refreshUpcoming`.

### Auth

- **MSAL for Apple platforms** (`AzureAD/microsoft-authentication-library-for-objc`, SPM).
  - Single-tenant authority `https://login.microsoftonline.com/<Synderys tenant ID>`.
  - Redirect URI `msauth.<bundle id>://auth`.
- **MSAL 2.x needs a parent window on macOS.** Its migration guide makes the parent view controller mandatory, with a non-nil window. Launch interactive sign-in from the Settings or Onboarding window, never from the menu-bar popover alone.
- **Tokens:** use MSAL's keychain cache and call `acquireTokenSilent`. On `MSALErrorInteractionRequired`, show a non-modal "Reconnect Microsoft 365" banner; don't pop a sign-in sheet unprompted.
- **Scopes (delegated):** `User.Read`, `Calendars.Read`, `offline_access`.
  - Optional: `Calendars.Read.Shared`, for delegated or shared calendars such as an EA's view of the CEO's calendar.
  - Don't use `Calendars.ReadBasic`: it drops the body, where some join links live.
- If Intune Company Portal (Enterprise SSO plug-in) is deployed, MSAL uses it automatically with the default redirect URI, which gives SSO with no password prompt.

### Entra app registration (one-time, IT)

1. Register a single-tenant app named "Biscotti (Synderys)".
2. Authentication → Add platform → **iOS/macOS** → bundle ID.
3. API permissions → delegated `User.Read`, `Calendars.Read`, `Calendars.Read.Shared` and `offline_access` → **Grant admin consent for Synderys**. Stephen does this as IT, once, so users never see a consent prompt.
4. Ship the client ID and tenant ID in the app's `Info.plist`, or as an MDM-managed preference so IT can rotate them.

### Fetching

- **Calendars:** `GET /me/calendars` → `CalendarInfo`.
  - `id` → `id`, `name` → `title`, `hexColor` → `colorHex` (fall back to `#808080`).
  - `sourceTitle` = "Microsoft 365 (<UPN>)".
  - These feed the existing enabled-calendar filter.
- **Events:** `GET /me/calendars/{id}/calendarView?startDateTime=…&endDateTime=…`.
  - The window is `CalendarService.upcomingWindowSeconds` (7 days), plus the ±1.5 h `eventsNear` window used for association.
  - Use calendarView, not `/events`, so recurring meetings come back as occurrences.
  - Use `$select` to request only the mapped fields, and page through `@odata.nextLink`.
- **Refresh cadence:**
  - Every 5 minutes while the app runs, on wake, on network change, and right before the "start recording?" prompt.
  - Graph webhooks need a publicly reachable endpoint ([Learn](https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks)), so a desktop app has to poll.
  - Phase 2 option: `/me/calendarView/delta` for the primary calendar only. Delta doesn't support `$select`, and the date range is fixed into the token.
- **`refreshEvent`:** `GET /me/events/{id}`. A 404 returns nil (event deleted).
- **Throttling:** honor `Retry-After` on 429, with exponential backoff when the header is missing. Run at most 4 concurrent requests per mailbox.
- **Offline:** keep the last successful fetch in memory and mark it stale. Never block recording on Graph.

### Field mapping (Graph `event` → `EKEventDTO`)

| EKEventDTO | Graph |
|---|---|
| `eventIdentifier` | `id` |
| `calendarItemIdentifier` | `seriesMasterId ?? id` |
| `calendarItemExternalIdentifier` | `iCalUId` |
| `occurrenceDate` / `startDate` / `endDate` | `start` / `end` (`dateTimeTimeZone`; request UTC and convert) |
| `isAllDay` | `isAllDay` |
| `title` | `subject` |
| `location` | `location.displayName` |
| `url` | `onlineMeeting.joinUrl` (fall back to the first conference URL found in `body`, using the existing `MeetingCatalog` detection) |
| `notes` | `body.content`, HTML stripped to plain text (cap the length) |
| `status` | `isCancelled ? "canceled" : responseStatus.response` |
| `availability` | `showAs` |
| `attendees[]` | `attendees[]`: `emailAddress.name` / `address` → `mailto:` URL, `type` → role, `status.response` → status |
| `organizer` | `organizer.emailAddress` |
| `AttendeeDTO.isCurrentUser` | address equals `/me` `mail` or `userPrincipalName` (case-insensitive) |
| `calendarSourceTitle` | "Microsoft 365 (<UPN>)" |
| `birthdayContactIdentifier` | `nil` |

### UI

- **Settings → Calendar:** a "Microsoft 365" row.
  - Disconnected: **Connect** button.
  - Connected: account email, last-sync time, **Disconnect**.
  - M365 calendars appear in the existing include/exclude list, grouped under the account.
- **Onboarding:** an optional "Connect Microsoft 365" step, offered before the Apple Calendar permission step. If the user connects M365, the Apple Calendar prompt is skipped by default.
- **Setting:** "Also read Apple Calendar", default **off** when M365 is connected. This avoids duplicates and TCC prompts.

## Testing

- Unit tests with recorded Graph JSON fixtures covering: recurring occurrences, all-day events, cancelled events, Teams join URL, join link only in body, organizer-only meetings, shared calendars, time zones, 429 with Retry-After, and paging.
- `CompositeEventStore` dedupe tests.
- ManualTestApp tab "M365 Calendar": sign in, list calendars, fetch the next 7 days, show raw versus mapped output. This covers what unit tests can't (MSAL, keychain, SSO plug-in).

## Out of scope

- Writing to the calendar.
- Graph mail or Teams transcripts.
- Multi-tenant or personal Microsoft accounts.
- Google Calendar.

## Phases

1. `GraphCalendar` module: Graph client, mapping, fixtures and tests (no auth; inject a token).
2. MSAL auth, keychain, Settings row, Entra registration doc.
3. `CompositeEventStore`, dedupe, polling and change signal, onboarding step, ManualTestApp tab.
