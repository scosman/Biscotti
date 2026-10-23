---
status: complete
---

# Architecture: Microsoft 365 Calendar (Graph)

Implements `functional_spec.md`. Phase 1 is fully decided below. Phases 2 and 3
are sketched to the depth needed to keep Phase 1's seams right, and their
details are settled in their own phase plans.

## 1. Shape of the change

```
Packages/BiscottiKit/Sources/GraphCalendar/   ← new module (Phase 1)
Packages/BiscottiKit/Tests/GraphCalendarTests/ ← fixture tests (Phase 1)
Packages/BiscottiKit/Package.swift             ← + GraphCalendar product/target/tests
— Phase 2 —
GraphCalendar (+ MSAL token provider), SettingsUI (Microsoft 365 row),
App/project.yml + Info.plist (MSAL redirect scheme, client/tenant IDs)
— Phase 3 —
GraphCalendar (GraphEventStore, CompositeEventStore, poller),
Calendar (provider-agnostic change signal), AppCore+Live (composition),
OnboardingUI, ManualTestKit/ManualTestApp ("M365 Calendar" tab)
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

## 4. Phase 2 sketch: auth

- **MSAL dependency:** `AzureAD/microsoft-authentication-library-for-objc`,
  SPM. It goes in a separate target (`GraphAuth`), so `GraphCalendar` and its
  tests stay free of MSAL and keychain access.
- **`MSALGraphTokenProvider: GraphAccessTokenProviding`:** silent acquisition
  with `forceRefresh` passed through. Interactive sign-in is a separate call
  that takes the parent window (MSAL 2.x on macOS).
- **Configuration:** client ID and tenant ID come from `Info.plist`
  (overridable by managed preferences). The redirect URI is
  `msauth.com.synderys.biscotti://auth`. The scheme is registered in
  `App/project.yml`.
- **UI:** the Settings → Calendar "Microsoft 365" row (Connect /
  account + last sync / Disconnect) and the reconnect banner.

## 5. Phase 3 sketch: integration

- **`GraphEventStore: EventStoreProviding`:** synchronous reads from a locked
  snapshot (`calendars`, events covering the window, a by-ID index for
  `refreshEvent`). `authorizationStatus` reports signed-in state, and
  `requestAccess` is a no-op that returns the current state, because sign-in
  is Phase 2's UI.
- **`GraphCalendarPoller`:** refreshes the snapshot through
  `GraphCalendarReader` every 5 min, on wake, on network change, and before
  the record prompt. On failure it keeps the snapshot and marks it stale. It
  posts the change signal.
- **`CompositeEventStore: EventStoreProviding`:** unions providers and dedupes
  by iCalUID, with Graph winning (functional spec §7–8).
- **`CalendarService.startObserving`:** additionally observes a
  provider-agnostic notification. This is the single upstream edit in
  `Calendar`.
- **`AppCore+Live`:** builds `CalendarService(provider: CompositeEventStore(...))`.
