---
status: complete
---

# Functional Spec: Microsoft 365 Calendar (Graph)

Input: `project_overview.md`. Where this spec and the overview differ, this
spec wins. Each difference is called out where it is made.

## 1. Summary

Biscotti reads Microsoft 365 calendars through Microsoft Graph and maps them to
the `Calendar` module's existing DTOs (`CalendarInfo`, `EKEventDTO`,
`AttendeeDTO`). `CalendarService` and everything downstream of it then treat
M365 events like EventKit events. That covers notifications, the "start
recording?" prompt, auto-association, attendee-based speaker matching, and
meeting details in summaries.

- **Read-only.** It reads calendars, events and `/me`, and never writes.
- **Delegated, single-tenant.** The app reads on behalf of the signed-in
  Synderys user, using MSAL (Phase 2).
- **Never blocks recording.** A Graph failure costs calendar context, never a
  recording.

## 2. Phases

| Phase | Delivers | User-visible? |
|---|---|---|
| 1 | `GraphCalendar` module: Graph client, the Graph → DTO mapping, fixture tests. The access token is injected; there is no sign-in. | No |
| 2 | MSAL sign-in, keychain token cache, the Settings → Calendar "Microsoft 365" row, the Entra registration doc. | Settings row |
| 3 | `GraphEventStore` + `CompositeEventStore`, iCalUID dedupe, polling and the change signal, the onboarding step, the ManualTestApp "M365 Calendar" tab. | Yes |

Sections 3–6 specify Phase 1 in full. Section 7 records what Phases 2 and 3 must
honor. Those phases get their own phase plans when they start.

## 3. Reading (Phase 1)

### 3.1 Requests

| Read | Request | Notes |
|---|---|---|
| Account | `GET /me?$select=id,displayName,mail,userPrincipalName` | Gives "who is me" for `isCurrentUser` and the source title. |
| Calendars | `GET /me/calendars?$select=id,name,hexColor,isDefaultCalendar,canEdit,owner` | Includes shared calendars the user added in Outlook. Paged. |
| Events | `GET /me/calendars/{id}/calendarView?startDateTime=…&endDateTime=…&$select=…&$top=100` | One request chain per calendar. Recurring meetings come back as occurrences. Paged. |
| One event | `GET /me/calendars/{cid}/events/{id}` | Re-reads an event before prompting. **404 → nil** (deleted). |

- Every request carries `Authorization: Bearer <token>`.
- Event reads also carry `Prefer: outlook.timezone="UTC"`, so `start`/`end`
  arrive in UTC.
- Window bounds are sent as UTC ISO 8601 (`2026-10-26T00:00:00Z`).
- IDs are percent-encoded as single path segments. Graph IDs can contain `/`
  and `+`.
- *Deviation from the overview:* single-event reads use the calendar-scoped
  path rather than `/me/events/{id}`. Events on a shared calendar don't live in
  the user's own mailbox, so `/me/events/{id}` would report them as deleted.
  The client also keeps the unscoped form for callers without a calendar.

### 3.2 Paging

- The client follows `@odata.nextLink` until a page has none.
- It only follows a link on the same scheme and host as the base URL
  (`https://graph.microsoft.com`). Any other link fails the read with
  `untrustedNextLink`, so the bearer token never goes to another host.
- At most 100 pages per collection. This guards against a server that loops;
  real calendars don't reach it.

### 3.3 Throttling and retries

- **429 and 503:** wait `Retry-After` seconds when the header is a
  non-negative integer. Otherwise back off exponentially: 1 s, 2 s, 4 s, …
  Waits are capped at 60 s.
- After 3 retries, the read fails with `throttled(retryAfter:)`.
- **401:** fetch a fresh token (`forceRefresh: true`) and retry once. A second
  401 fails with `unauthorized`. In Phase 2, that error drives the "Reconnect
  Microsoft 365" banner.
- **Concurrency:** at most 4 requests in flight per client (one client per
  mailbox), which is Graph's per-app-per-mailbox limit. Further requests wait
  for a slot.

### 3.4 Multi-calendar reads

- Calendars are read concurrently, within the 4-request cap.
- If Graph refuses a calendar (403) or no longer has it (404), for example a
  revoked share, the reader logs and skips it.
- Any other error fails the whole read. Phase 3 then keeps the last good
  snapshot (§7).
- If one event can't be mapped (impossible date, unknown zone), the reader logs
  and drops that event. The rest of the calendar still loads.
- Results are sorted by `(startDate, eventIdentifier)`. Concurrent reads
  finish in any order, so the sort keeps output deterministic.
  `CalendarService` re-sorts on its own; `EventStoreProviding` sets no order.
- A single-event refresh **throws** on a mapping error rather than returning
  nil. That way a bad event is never mistaken for a deleted one.

### 3.5 Errors

| `GraphError` | When |
|---|---|
| `unauthorized` | 401 after one forced token refresh. |
| `forbidden(code:message:)` | 403. Carries Graph's `error.code` and `error.message`. |
| `throttled(retryAfter:)` | 429 or 503 after the retries in §3.3. |
| `http(status:code:message:)` | Any other non-2xx status, with Graph's error body when present. |
| `untrustedNextLink(_)` | §3.2. |
| `decoding(_)` / `invalidResponse` / `invalidRequest(_)` | Unparseable 2xx body, non-HTTP response, or a URL that can't be built. |
| `transport(_)` | Network failure from `URLSession`. |

Mapping failures are a separate `GraphMappingError`: `invalidDateTime(_)` and
`unknownTimeZone(_)`.

## 4. Field mapping

### 4.1 Account

| Value | Source |
|---|---|
| `sourceTitle` (on calendars and events) | `"Microsoft 365 (<userPrincipalName>)"` |
| "Is me" | Case-insensitive, trimmed match of an address against `/me` `mail` **or** `userPrincipalName`. They often differ (`Jane.Doe@` vs `jane@`). |

### 4.2 Calendar (Graph `calendar` → `CalendarInfo`)

| CalendarInfo | Graph |
|---|---|
| `id` | `id` |
| `title` | `name`. If `owner.address` isn't the current user, it becomes `"<name> (<owner.name, else owner.address>)"`, because shared calendars are all called "Calendar". |
| `colorHex` | `hexColor` normalized to uppercase `#RRGGBB`. It's `#808080` when Graph sends empty, `"auto"`, a color name or a malformed value. |
| `sourceTitle` | §4.1 |

### 4.3 Event (Graph `event` → `EKEventDTO`)

| EKEventDTO | Graph | Notes |
|---|---|---|
| `eventIdentifier` | `id` | Each occurrence has its own `id`. |
| `calendarItemIdentifier` | `seriesMasterId ?? id` | |
| `calendarItemExternalIdentifier` | `iCalUId ?? ""` | `iCalUId` may differ per occurrence (§8). |
| `occurrenceDate` | `originalStart` (DateTimeOffset) ?? `startDate` | For exceptions, `originalStart` is the slot the occurrence was moved from, matching EventKit. For all-day events it is `startDate`. |
| `startDate` / `endDate` | `start` / `end` | §5 |
| `isAllDay` | `isAllDay ?? false` | |
| `title` | `subject` | Blank → nil. |
| `location` | `location.displayName` | Blank → nil. |
| `url` | `onlineMeeting.joinUrl` → `onlineMeetingUrl` → first conference link in the body | The first two must be `http`/`https`; a `tel:` join URL is skipped. The body fallback uses `MeetingCatalog.conferenceMatch` on the **uncapped** body text, because Teams puts its link at the end. |
| `timeZone` | `originalStartTimeZone`, resolved to IANA (§5.3) | nil for all-day events and for unresolvable zones such as "Customized Time Zone". |
| `notes` | `body.content` as plain text (§6), capped at 10,000 characters | Blank → nil. |
| `status` | `isCancelled == true ? "canceled" : responseStatus.response` | Raw Graph value otherwise (`accepted`, `organizer`, `none`, …), like EventKit's raw strings. |
| `availability` | `showAs` | Raw (`busy`, `free`, `tentative`, `oof`, `workingElsewhere`, `unknown`). |
| `calendarIdentifier` / `calendarTitle` / `calendarColorHex` / `calendarSourceTitle` | From the `CalendarInfo` the event was read with | |
| `birthdayContactIdentifier` | nil | |
| `attendees` | `attendees[]` | §4.4 |
| `attendeeCount` | 0 if there are no attendees, else attendees + 1 if the organizer isn't among them | EventKit counts the organizer for invitations; Graph lists invitees only. *Overview gap; decided here.* |
| `organizer` | `organizer.emailAddress` | §4.4 |

### 4.4 Participants (→ `AttendeeDTO`)

| AttendeeDTO | Attendee | Organizer |
|---|---|---|
| `name` | `emailAddress.name` (blank → nil) | same |
| `participantURL` | `mailto:<emailAddress.address>` (blank → nil) | same |
| `isCurrentUser` | §4.1 | same |
| `role` | `type`: required → `required`, optional → `optional`, resource → `nonParticipant`, else `unknown` | `chair` |
| `status` | `status.response`: accepted/organizer → `accepted`, tentativelyAccepted → `tentative`, declined → `declined`, notResponded → `pending`, else `unknown` | `accepted` |
| `type` | resource → `resource`, required/optional → `person`, else `unknown` | `person` |

The strings are the vocabulary `LiveEventStore` writes, so downstream code needs
no Graph-specific cases.

## 5. Time

### 5.1 Timed events

`start`/`end` arrive as `{dateTime, timeZone}` with `timeZone: "UTC"`, because
of the Prefer header. The parser:

- Accepts `yyyy-MM-ddTHH:mm[:ss[.f…]]` with Graph's 7-digit fractions, parsed
  by hand. No `DateFormatter` format covers 7 fractional digits.
- Rejects impossible dates (Feb 30, hour 25) with `invalidDateTime`.
- Also accepts an IANA name or a known Windows zone name in `timeZone`, in case
  the Prefer header is dropped. A missing zone means UTC.

### 5.2 All-day events

All-day bounds name a **day**, not an instant. EventKit shows them as floating
local days, so they map to **local midnight** (`localTimeZone`, default
`.current`) of the named day:

- If the time is `00:00:00`, the date part is the day.
- Otherwise Graph has converted the organizer's midnight to UTC, for example
  `07:00Z` for a Pacific organizer. The day is then recovered in the event's
  `originalStartTimeZone` before taking local midnight.
- **UNVERIFIED:** which form Graph sends for all-day events under
  `Prefer: outlook.timezone="UTC"`. Both are handled and tested; confirm on a
  real tenant in Phase 3.

### 5.3 Zone names

`originalStartTimeZone` is usually a Windows name ("Pacific Standard Time").
Resolution order:

1. UTC aliases (`UTC`, `tzone://Microsoft/Utc`, "Coordinated Universal
   Time", …).
2. IANA identifiers.
3. A built-in table of 32 common Windows zones → IANA.

Anything else, such as "Customized Time Zone", resolves to nil. It is never
guessed.

## 6. Notes text

`body.content` is HTML (`contentType: "html"`) or plain text. HTML becomes plain
text as follows:

- `<head>`, `<style>`, `<script>` and comments, including Outlook's
  `<!--[if mso]>` blocks, are removed.
- `<br>` and block ends (`</p>`, `</div>`, `</tr>`, lists, headings) become
  line breaks. `<li>` becomes `- `, and table cells are separated by spaces.
- Links keep their target: `<a href="https://x">docs</a>` → `docs
  https://x`. A link isn't repeated when its text already is the URL, and
  `mailto:` and `#` links keep only their text. The target is padded with
  spaces so conference detection, which matches up to whitespace, sees a
  clean URL. (Side effect: a space can appear before punctuation.)
- Entities (named basics, decimal, hex) are decoded **once**, after tags are
  removed. Unknown entities and invalid scalars stay as written.
- Whitespace runs collapse to one space, with at most one blank line and no
  leading or trailing blank lines.
- Text over the cap is cut and ends in `…`.

## 7. Requirements carried to Phases 2 and 3

- **Token source (Phase 2).** MSAL implements `GraphAccessTokenProviding`
  (`accessToken(forceRefresh:)`). `forceRefresh` maps to
  `acquireTokenSilent` with `forceRefresh = true`. `MSALErrorInteractionRequired`
  surfaces as `GraphError.unauthorized`, or as a distinct error if the banner
  needs one. Scopes, authority and redirect are as in the overview, with
  redirect `msauth.com.synderys.biscotti://auth`.
- **Sync seam (Phase 3).** `EventStoreProviding` is synchronous, but Graph is
  not. `GraphEventStore` serves `calendars()`, `events(in:calendars:)` and
  `refreshEvent` from an in-memory snapshot that a poller fills through
  `GraphCalendarReader`. Every 5 minutes, on wake, on network change, and
  before the record prompt (best-effort, time-boxed), it posts a
  provider-agnostic "changed" signal. A failed poll keeps the last snapshot,
  marked stale.
- **Window.** `CalendarService`'s 7-day upcoming window, plus the ±1.5 h
  `eventsNear` association window.
- **Dedupe.** `CompositeEventStore` matches Graph `iCalUId` against EventKit
  `calendarItemExternalIdentifier`, and Graph wins. Because of §8, it must not
  assume `iCalUId` is shared across a series.

## 8. Open questions (verify on hardware, Phase 3)

1. **All-day form under the UTC Prefer header** (§5.2).
2. **iCalUID parity:** does Graph `iCalUId` equal EventKit's
   `calendarItemExternalIdentifier` for the same Exchange event? This comes
   from the overview and is still unverified.
3. **Per-occurrence `iCalUId`:** Graph documents that occurrences of a series
   can carry distinct `iCalUId` values. If EventKit uses the series UID, dedupe
   needs `(iCalUId or series UID, occurrence start)` rather than UID alone.
4. **Shared-calendar 403s:** whether `Calendars.Read.Shared` is needed for the
   EA case, or `Calendars.Read` is enough for calendars the user added.

## 9. Non-goals

These are as in the overview: no calendar writes, no Graph mail or Teams
transcripts, no multi-tenant or personal accounts, and no Google Calendar.
Phase 1 also has no sign-in, no UI, no polling, and no wiring into `AppCore`.
