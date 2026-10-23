---
status: complete
---

# Phase 1: `GraphCalendar` module — client, mapping, fixture tests

## Overview

A new BiscottiKit module that reads Microsoft 365 calendars through Graph
and maps them to the `Calendar` module's DTOs, plus fixture tests. There is
no sign-in: callers inject a token provider. Nothing outside the module
changes except `Package.swift`.

## Pre-work (requested with this phase)

- **Bundle ID → `com.synderys.biscotti`.** It changes in the app, the XPC
  services, ManualTestApp, the LLM XPC lookup, the meeting-detector
  self-exclusion and the voiceprint CLI path. Logger subsystems, notification
  names and error domains keep `net.scosman.biscotti`. They aren't identity,
  and renaming them would only widen the upstream diff. TCC grants
  (microphone, system audio) have to be re-granted once.
- **Configurable MCP port.** `MCPServerConfiguration.port(from:)` reads the
  `mcpServerPort` user default (1024–65535, else 8516). The configured port
  flows into `endpointURL(port:)`. `App/ConnectingMCP.md` documents
  `defaults write com.synderys.biscotti mcpServerPort -int <port>`.
  `MCPServer` changed, so the `mcp_*` manual tests are marked `not-run`.

## Steps

1. **`Package.swift`:** the `GraphCalendar` library product and target (deps
   `Calendar`, `MeetingCatalog`), plus `GraphCalendarTests` with
   `resources: [.copy("Fixtures")]`. Both use the package's
   warnings-as-errors settings.
2. **`Graph.swift`:** wire types and `Page`/`ErrorResponse`.
3. **`GraphTransport.swift`:** the token and transport protocols,
   `StaticGraphAccessToken`, `URLSessionGraphTransport`.
4. **`GraphError.swift`:** `GraphError`, `GraphMappingError`.
5. **`GraphClient.swift`:** the actor client (functional spec §3.1–3.3).
6. **`GraphDateParsing.swift`:** functional spec §5.
7. **`HTMLText.swift`:** functional spec §6.
8. **`GraphEventMapper.swift`:** `GraphAccount`, `GraphEventMapper`
   (functional spec §4).
9. **`GraphCalendarReader.swift`:** functional spec §3.4.
10. **`GraphCalendarLog.swift`.**
11. **Fixtures** (`Tests/GraphCalendarTests/Fixtures/*.json`): `me`,
    `calendars`, `calendarView_week` (8 events covering the overview's test
    list), paging pages, an untrusted nextLink, `calendarView_early`,
    `calendarView_empty`, `event_teams`, and error bodies for 401, 403, 404
    and 429.
12. **Tests:** the six suites in architecture §3.
13. **Docs:** `functional_spec.md`, `architecture.md`,
    `implementation_plan.md`, this plan.

## Deviations and decisions

- **Spec docs written by hand.** The `/spec` skill isn't installed in this
  environment ("Unknown skill: spec"). These docs follow the format of
  `specs/projects/mcp_server/`.
- **Single-event path is calendar-scoped.** The overview says
  `GET /me/events/{id}`, but this uses `/me/calendars/{cid}/events/{id}`.
  Shared-calendar events aren't in the user's mailbox, so the unscoped path
  would 404 and read as "deleted" (functional spec §3.1).
- **`attendeeCount`:** the overview doesn't specify it. It's 0 with no
  attendees, otherwise invitees + 1 when the organizer isn't listed,
  matching EventKit's count.
- **`iCalUId` missing → `""`.** `calendarItemExternalIdentifier` is
  non-optional, as in EventKit.
- **Windows zone names:** a 32-entry Windows → IANA table covers
  `originalStartTimeZone`. Unknown names, including "Customized Time Zone",
  give a nil `timeZone` and are never guessed.
- **All-day events:** both wire forms are handled (functional spec §5.2,
  UNVERIFIED).
- **Unreadable calendars:** a 403 or 404 skips that calendar; anything else
  fails the read. One unmappable event is skipped in list reads but throws
  on single-event refresh.
- **Verified.** It was written while `hooks-mcp` was down and compiled
  later. `make precommit-checks` passed on 2026-10-23: format, lint, and
  every package's tests, with `GraphCalendarTests` among them.
