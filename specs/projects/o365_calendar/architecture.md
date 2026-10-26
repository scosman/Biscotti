---
status: complete
---

# Architecture: Microsoft 365 Calendar (Graph)

Implements `functional_spec.md`. Phase 1 is fully decided below. Phases 2 and 3
were first sketched to the depth needed to keep Phase 1's seams right. §4 and
§5 now describe them as built, and their phase plans hold the details.

## 1. Shape of the change

```
Packages/BiscottiKit/Sources/GraphCalendar/   ← new module (Phase 1)
Packages/BiscottiKit/Tests/GraphCalendarTests/ ← fixture tests (Phase 1)
Packages/BiscottiKit/Package.swift             ← + GraphCalendar product/target/tests
— Phase 2 —
GraphAuth (new module: OAuth + PKCE sign-in, token provider, keychain),
AppCore (owns the account controller), SettingsUI (Microsoft 365 row,
replacing the Apple calendar list),
HomeUI (reconnect banner), docs/entra_app_registration.md
— Phase 3 —
GraphCalendar (GraphEventStore, poller),
Calendar (provider-agnostic change signal), AppCore (Microsoft365CalendarSync,
composition in AppCore+Live), OnboardingUI and SettingsUI (Microsoft 365 in
place of Apple Calendar when a registration is configured),
ManualTestKit/ManualTestApp ("M365 Calendar" tab)
```

**Dependency direction:** `GraphCalendar → Calendar, MeetingCatalog`. Nothing
upstream depends on `GraphCalendar` until Phase 3 adds the one composition edge
in `AppCore+Live`. That edge mirrors how `LiveEventStore` is composed today. It
keeps fork edits to upstream files small, so rebases stay cheap (see
`synderys_integrations/README.md`).

## 2. Module layout (Phase 1)

| File | Contents |
|---|---|
| `Graph.swift` | `enum Graph`, a namespace of `Decodable` wire types: `User`, `Calendar`, `Event`, `DateTimeTimeZone`, `OnlineMeetingInfo`, `Location`, `ItemBody`, `ResponseStatus`, `Attendee`, `Recipient`, `EmailAddress`. Every field is optional unless Graph always sends it. Top-level internal `GraphPage<Element>` (`value` + `@odata.nextLink`) and `GraphErrorResponse` (kept out of `Graph` to stay within SwiftLint's nesting limit). `seriesMasterId` keeps Graph's wire name under an `inclusive_language` disable. |
| `GraphTransport.swift` | `GraphAccessTokenProviding` (`accessToken(forceRefresh:) async throws -> String`), `StaticGraphAccessToken` (for Phase 1 and tools), `GraphHTTPTransport` (`send(URLRequest) async throws -> (Data, HTTPURLResponse)`), and `URLSessionGraphTransport`. |
| `GraphClient.swift` | `actor GraphClient`: `me()`, `calendars()`, `calendarView(calendarID:in:)`, `event(id:calendarID:)`. Owns request building, paging, the 401 refresh, throttle/backoff (`RetryPolicy`, injectable `Sleeper`) and the 4-slot limiter. |
| `GraphError.swift` | `GraphError` (transport/HTTP) and `GraphMappingError` (data), both `Equatable` for tests. |
| `GraphDateParsing.swift` | Hand parser for `dateTimeTimeZone` and `DateTimeOffset`, all-day day recovery, zone-name resolution, and the Windows → IANA table. |
| `HTMLText.swift` | HTML/text body → capped plain text (functional spec §6). |
| `GraphEventMapper.swift` | `GraphAccount` (UPN + mail, `sourceTitle`, `isCurrentUser`) and `GraphEventMapper` (`calendarInfo(_:)`, `event(_:calendar:)`), a pure value type. |
| `GraphCalendarReader.swift` | `GraphCalendarReader`: `account()`, `calendars(for:)`, `events(in:calendars:account:)` and `event(id:calendar:account:)`. It composes client and mapper, reads calendars concurrently, and applies the skip rules (functional spec §3.4). |
| `GraphCalendarLog.swift` | `os.Logger`, subsystem `net.scosman.biscotti` (shared by every module's logs, so one `log stream` predicate still catches everything), category `GraphCalendar`. |

### 2.1 Decisions

- **The client is an actor.** It serializes the slot counter and the waiter
  queue. Network awaits suspend without holding the actor, so the four slots
  really do overlap.
- **Mapping is synchronous and pure.** `GraphEventMapper` has no I/O, which
  lets fixture tests drive it directly from decoded JSON.
- **The account is passed in, not stored.** The reader takes the
  `GraphAccount` on each call. The Phase 3 poller fetches `/me` once per
  sign-in and reuses it; a stored copy could go stale on account switch.
- **The reader takes `[CalendarInfo]`, not IDs.** An event's calendar fields
  come from the `CalendarInfo` it was read with, so the Phase 3 adapter
  resolves the enabled IDs against its cached calendar list before reading.
- **Seams for tests:** the transport, the token provider, the sleeper and the
  base URL are all injected. Tests never touch the network or real time.
- **No `DateFormatter`/`ISO8601DateFormatter` in the module.** Graph's
  7-digit fractions defeat format strings, and hand parsing keeps everything
  `Sendable`. Query bounds are formatted with `Date.ISO8601FormatStyle`.
- **Naming:** `Graph.Calendar` is nested, so it never collides with
  `Foundation.Calendar` or the `Calendar` module.

## 3. Tests (Phase 1)

`Tests/GraphCalendarTests/` with JSON fixtures in `Fixtures/` (bundled with
`.copy`). The fixtures have recorded Graph v1.0 shapes but made-up people, IDs
and links. The test week is 2026-10-26 to 2026-11-02 (UTC).

| Suite | Covers |
|---|---|
| `GraphClientTests` | Request shape (bearer, `$select`, `$top`, Prefer, window), percent-encoded IDs, scoped/unscoped event paths, 404 → nil, paging, untrusted nextLink, Retry-After honored or capped, exponential backoff, throttled after max retries, Retry-After parsing, 401 refresh once / twice, 403 body, other statuses, decoding and transport errors, the 4-request cap. |
| `GraphEventMapperTests` | Each fixture event: a Teams meeting with an HTML body and a room, a series occurrence, a moved exception (`originalStart`), all-day in several zones and both wire forms, cancelled, a Zoom link only in the body, an organizer-only meeting, an unresolvable zone. Also: join link past the notes cap, `tel:` vs legacy `onlineMeetingUrl`, impossible dates, Windows-zone start times. |
| `GraphCalendarMappingTests` | Calendar titles and colors, hex normalization, status and role/type tables, current-user matching. |
| `GraphDateParsingTests` | 7-digit fractions, wall-clock forms, default zone, impossible dates, zone resolution, Windows-table validity, `originalStart`. |
| `HTMLTextTests` | Structure, hidden content, anchors, entities, whitespace, truncation. |
| `GraphCalendarReaderTests` | Account, calendars, the multi-calendar read (sort, 403/404 skip, bad-event skip, other errors fail, no calendars → no requests), single-event refresh. |

`FakeGraphTransport` replays stubs by decoded URL path, in order, repeating the
last one. It records requests and the peak number in flight. `FakeTokens` and
`SleepRecorder` record refreshes and waits.

## 4. Phase 2: auth (as built)

MSAL was dropped for a small OAuth client of our own; see
`phase_plans/phase_2.md` for why.

- **`GraphAuth` target** (deps `GraphCalendar`). `GraphCalendar` and its
  tests stay free of sign-in and keychain code.
- **Flow:** OAuth 2.0 authorization code + PKCE (S256) against Entra ID's v2
  endpoints for the configured tenant, as a public client (no secret, no
  `Origin` header). The browser part runs in `ASWebAuthenticationSession`
  with a `.customScheme` callback, so no URL scheme is registered in
  `App/project.yml`. Scopes: `openid profile offline_access User.Read
  Calendars.Read Calendars.Read.Shared`. Redirect:
  `msauth.com.synderys.biscotti://auth`.
- **`GraphTokenProvider` (actor): `GraphAccessTokenProviding`.** It keeps the
  access token in memory, refreshes 5 min before expiry, and shares one
  refresh among concurrent callers. A rotated refresh token is saved. If
  Entra refuses the refresh token with an OAuth error, the session is marked
  for reconnect and `GraphError.unauthorized` is thrown. Outages, proxies
  and captive portals throw `GraphError.transport` and keep the session.
- **`GraphTokenStore`:** `KeychainGraphTokenStore` keeps the refresh token
  and account as one item in the login keychain. It uses the file-based
  keychain, so no keychain-access-group entitlement is needed.
  `InMemoryGraphTokenStore` is for tests.
- **`GraphAccountController` (`@MainActor @Observable`):** exposes
  `GraphAccountState` (`notConfigured`, `signedOut`, `signingIn`, `signedIn`,
  `needsReconnect`) and `lastError`. It restores the session at launch and
  runs sign-in and sign-out. `AppCore.microsoft365` owns it.
- **Configuration:** `MicrosoftGraphClientID` / `MicrosoftGraphTenantID`,
  read from user defaults (including MDM managed preferences), then
  `Info.plist`. Without them the controller is `.notConfigured`.
- **UI:** the Settings → Calendars "Microsoft 365" row (Connect…, the
  account, Reconnect…, Disconnect…) and the Home "sign-in has expired"
  banner. The last-sync time waits for Phase 3's poller. The row is the whole
  Calendars section: the Apple calendar include/exclude list was removed
  (functional spec §7).

## 5. Phase 3: integration (as built)

See `phase_plans/phase_3.md` for the details and deviations.

- **`GraphEventStore: EventStoreProviding` (GraphCalendar):** synchronous
  reads from a `Mutex`-guarded snapshot (calendars, events, window, fetch
  time) plus the events around one past date for the picker.
  `refreshEvent` answers from memory. `authorizationStatus` is set by the
  account (`.authorized` while signed in or expired), and `requestAccess`
  prompts for nothing, because sign-in is Phase 2's UI.
- **`GraphCalendarPoller` (actor, GraphCalendar):** fills the store through
  `GraphCalendarReader` every 5 min and 1 min before each timed event, over
  the last day and the next 8 days. Concurrent refreshes share one poll. A
  failed poll keeps the snapshot and marks it stale. A generation counter
  stops a poll from before a sign-out writing. `loadNearby` reads around an
  older date for the picker.
- **`Microsoft365CalendarSync` (AppCore):** the glue between the account and
  the poller:
  - follows `GraphAccountController.state`, and runs the poller while
    signed in;
  - polls on wake and when the network comes back;
  - posts the change signal;
  - resets the calendar selection once per account;
  - surfaces the last sync and its error to Settings.
  It lives in AppCore, not GraphCalendar, because it needs `GraphAuth`,
  `DataStore` and AppKit.
- **No `CompositeEventStore`.** With a registration, Microsoft 365 replaces
  Apple Calendar (functional spec §7), so `GraphEventStore` is the only
  provider and nothing is deduped.
- **`CalendarService` (Calendar):** `startObserving` also observes
  `.calendarProviderDidChange`, and `refreshUpcoming` re-reads `auth`. These
  are the only upstream edits in `Calendar`.
- **`AppCore+Live`:** builds `CalendarService(provider:)` with the sync's
  `GraphEventStore` when `GraphAccountController.live()` is configured, and
  with `LiveEventStore` otherwise.
- **UI:** with a registration, onboarding's Calendar permission becomes a
  Microsoft 365 Connect row, and Settings lists the account's calendars
  under the Microsoft 365 row with the existing include/exclude selection.
  Without one, every screen is upstream's.
