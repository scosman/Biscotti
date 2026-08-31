---
status: complete
---

# Functional Spec: App URLs

## 1. Purpose

Biscotti registers the `biscotti://` URL scheme so any process on the machine
— an MCP client, a note-taking app, a shell script, a browser link — can
launch or foreground Biscotti on a specific page.

Today a partial version of this exists: the scheme is registered in
`App/Resources/Info.plist` (`CFBundleURLTypes`), and `AppCore.handleDeepLink`
handles exactly one shape, `biscotti://meeting/{uuid}?time={seconds}`, which
backs the timestamp links Biscotti writes into meeting notes
(`Recording/NotesMarkdown.swift`). This project widens that one route into a
documented URL vocabulary and makes delivery reliable in the cases the
current implementation misses (cold launch, menu-bar-only, window closed).

## 2. Scope

### In scope

- A parsed, tested URL vocabulary (§4) covering navigation and one action.
- Reliable delivery of URLs to `AppCore` in every app state (§5).
- A canonical URL *builder* so other code emits well-formed links (§6).
- `biscotti_get_meeting` (MCP) returning an `app_url` for the meeting (§7).
- A ManualTestApp script that opens real URLs through the system (§8).

### Out of scope

- Universal Links / `https://` deep links. `biscotti://` only.
- Any URL that writes, deletes, or edits data. The only side-effecting URL is
  `record` (§4.7), which starts a recording — nothing destructive.
- Authentication or a per-caller allowlist. Any local process may open these
  URLs, exactly as any local process may already launch the app.
- Deep links into settings *sub*-sections (`settings?section=ai`). Settings
  opens at its default section.
- x-callback-url style return/callback parameters.
- A "Copy Link to Meeting" affordance in the app. These URLs resolve only
  against the local machine's library, so a meeting link is not shareable
  with anyone else — the audience is other software on the same machine
  (the MCP server above all), not humans passing links around.

## 3. General rules

These apply to every URL in §4.

**R1 — Scheme.** Scheme must be exactly `biscotti` (URL schemes are
case-insensitive per RFC 3986; compare lowercased). Anything else is ignored.

**R2 — Route key.** The route is the URL *host* (`biscotti://meetings` →
host `meetings`). Compared case-insensitively. An unknown host is a no-op.

**R3 — Two tiers of failure.** Rejection happens at one of two points, and
they behave differently:

| Tier | Cases | Behavior |
|---|---|---|
| **Parse** | wrong scheme, unknown host, malformed UUID, unparseable number, missing required parameter | **Silent no-op.** Nothing shown, app not foregrounded. |
| **Existence** | well-formed link to a meeting or event that isn't there | **Foreground, then alert** ("Meeting Not Found" / "Event Not Found"). |

Both tiers log at `debug` via the existing `os.Logger`.

The split follows from cost: parsing is synchronous and free, so a malformed
URL from a background process can be discarded before anything is shown —
it never steals focus. An existence check needs the store (one indexed
fetch) or the in-memory upcoming list, and by then the app is already
coming forward, so failing silently would leave a human who clicked a stale
link staring at an app that did nothing. The alert is the honest answer.

**R4 — Foregrounding.** Any URL that *parses* foregrounds the app: shows the
main window (creating it if needed), switches the activation policy to
`.regular`, and activates. This is the existing
`AppDelegate.showMainWindow()` path, called before the route resolves, so
the app responds immediately.

**R5 — No loading state.** Nothing in the resolve path is slow enough to
warrant a spinner: `meetingExists` is a single indexed fetch and the event
lookup is an in-memory scan of `calendar.upcoming`. Until a link resolves,
the app simply keeps showing whatever it was showing; navigation happens in
one step or an alert appears.

**R6 — Onboarding.** While `route == .onboarding`, every incoming URL is
dropped (logged, not queued). The user finishes onboarding first.

**R7 — Recording.** An in-progress recording is never interrupted or stopped
by navigation. Navigating away from the recording pane is allowed; recording
continues and the user can return via the sidebar indicator. (`record` while
already recording routes to the recording pane — see §4.7.)

**R8 — Unknown query parameters are ignored,** not treated as errors. This
keeps links forward-compatible.

**R9 — Percent-encoding.** All values are read through `URLComponents`, which
decodes percent-encoding. Builders (§6) percent-encode values.

## 4. URL vocabulary

### 4.1 `biscotti://home`

Routes to the Home screen. No parameters.

Equivalent to `AppCore.showHome()`.

### 4.2 `biscotti://meetings`

Routes to the Meetings screen (list + detail) in browse mode: clears any
active search query and results, **keeps** the current selection.

Equivalent to `AppCore.showMeetings()`.

### 4.3 `biscotti://settings`

Routes to in-window Settings, at its default section.

Equivalent to `AppCore.showSettings()`.

### 4.4 `biscotti://meeting/{uuid}`

Opens one meeting on the Meetings screen with that meeting selected.

| Part | Required | Notes |
|---|---|---|
| path `{uuid}` | yes | A UUID string. Case-insensitive (`UUID(uuidString:)` accepts either case). Invalid → no-op. |
| `?tab=` | no | One of `summary`, `transcript`, `notes` (case-insensitive). Unrecognized value → ignored, falls back to the default (R8). |
| `?time=` | no | Seconds as a decimal number (e.g. `42`, `102.7`). Implies `tab=transcript`. |

**Resolution order for the tab:**

1. `time` present and parseable → Transcript tab, seek to `time`.
2. `tab` present and recognized → that tab, no seek.
3. Neither → Summary tab.

If both `tab` and `time` are present and disagree (`?tab=notes&time=42`),
`time` wins — it is the more specific intent, and this preserves the existing
notes-timestamp link behavior. This is the one case where a *valid* parameter
is overridden rather than honored.

**Existence check.** The meeting must exist in the store
(`store.meetingExists(id:)`). A well-formed UUID with no matching meeting
foregrounds the app and shows a **"Meeting Not Found"** alert (R3), leaving
the current route untouched.

**Seek clamping.** `time` is clamped to `[0, duration]` by the existing
`MeetingDetailViewModel.applySeekIfReady()`. A negative or absurdly large
`time` therefore lands at the start or end rather than being rejected.

**Behavior change from today:** `biscotti://meeting/{uuid}` with no `time` is
currently a no-op (asserted by `DeepLinkTests.missingTimeIsNoOp`). It now
opens the meeting on Summary. That test is updated.

### 4.5 `biscotti://search?query={text}`

Routes to the Meetings screen, sets the search query to `{text}`, runs the
search, and focuses the search field so the user can continue typing.

| Part | Required | Notes |
|---|---|---|
| `?query=` | yes | Free text. Percent-decoded. Missing → no-op. |

An **empty** `query` (`biscotti://search?query=`) is treated as present but
empty: it routes to Meetings with an empty query (browse mode) and focuses
the field. This is a useful "open search" affordance, so it is deliberately
not a no-op — unlike a wholly **absent** `query` parameter, which is.

Search results appear asynchronously via the existing debounced search
(`AppCore.setMeetingsQuery`); the URL handler does not wait for them.

### 4.6 `biscotti://upcoming?key={composite-key}`

Routes to the read-only preview for an upcoming calendar event.

| Part | Required | Notes |
|---|---|---|
| `?key=` | yes | The calendar composite key. Missing → no-op. |

**Why a query parameter, not `upcoming/{id}` as originally sketched.** The
identifier is the existing composite key from
`Calendar/CompositeKey.swift`:
`{eventIdentifier}|{calendarItemIdentifier}|{unixTimestamp}`. It contains
`|` and, on some accounts, `/` — characters that are hostile in a URL path
segment. A query parameter percent-encodes cleanly and avoids path-splitting
ambiguity.

**Existence check.** `CalendarService.event(forKey:)` is a synchronous scan
of the in-memory `upcoming` list, so the check is free. A key that matches no
live event foregrounds the app and shows an **"Event Not Found"** alert
(R3) rather than navigating to an empty preview.

**Stability caveat.** The composite key embeds an occurrence timestamp, so a
link to a rescheduled event stops resolving. These links are not durable and
are not intended to be stored long-term.

### 4.7 `biscotti://record[?title={text}]`

Starts a recording immediately and routes to the recording pane. No
confirmation prompt — this matches the existing global ⌘⇧R hotkey, which also
starts recording with no confirmation.

| Part | Required | Notes |
|---|---|---|
| `?title=` | no | Sets the new meeting's title instead of the default. |

**Already recording → show the recording.** `AppCore.startRecording` already
guards on `runState` being `.idle`/`.detectedPending`, so a second `record`
URL cannot start a second session. Rather than doing nothing, it routes to
the recording pane — the user asked to record and a recording is what they
get to see. No alert: this is a success, not a failure.

**Title semantics.** Without `title`, the meeting gets the usual
`"Untitled Meeting"` default and remains eligible for AI-generated titling
(`Intelligence` only titles meetings whose title is still the default). With
`title`, that title is set at creation, which *also* means AI titling will
leave it alone — the user asked for this name. A `title` that is empty or
whitespace-only is treated as absent.

**Permissions.** Recording started by URL goes through the identical startup
path as the button and the hotkey, including the permission checks and the
`recordingStartup` loading/failed states. A missing microphone permission
surfaces the same failure UI as any other start; the URL handler adds no
special handling.

## 5. Delivery

The app must handle a URL in all four states:

| State | Today | Required |
|---|---|---|
| Window open, app foreground | works | works |
| Window open, app background | works | works + foregrounds |
| Running, no window (menu-bar only) | unreliable — `onOpenURL` is attached to the `Window` scene, which may not exist | works, opens window |
| Not running (cold launch) | unreliable | works, launches and navigates |

**Mechanism.** Delivery moves from
`WindowRootView.onOpenURL` (SwiftUI, scene-scoped) to
`NSApplicationDelegate.application(_:open:)` (AppKit, process-scoped), which
fires regardless of whether any window exists and is the documented path for
both cold launch and running-app URL opens. `onOpenURL` is removed so a URL
is never handled twice.

**Cold-launch ordering.** On cold launch, `application(_:open:)` can fire
before `AppCore.onLaunch()` has finished (it awaits orphan recovery, model
refresh and a settings read). A URL that arrives before the core is ready
must not be dropped: it is held as a single pending URL and applied once
`onLaunch()` completes and the onboarding gate (R6) is known. Only the most
recent pending URL is kept — if two arrive during launch, the last wins.

**Multiple URLs.** `application(_:open:)` may be handed several URLs at once.
Each is processed in order; the last one to resolve determines the final
route.

## 6. URL construction

A small builder mirrors the parser, so the two can be round-trip tested
(build → parse → same intent). That test is the cheapest way to keep the
parser honest against the documented schema in §9.

Its consumers are the MCP server (§7) and the manual test script (§8).

**`Recording/NotesMarkdown.swift` is deliberately left alone.** It
hand-interpolates its `biscotti://meeting/{id}?time={s}` links today and
keeps doing so. This project defines a URL schema for *external* callers;
internal code that already emits a correct URL does not need to be routed
through an abstraction to prove it.

## 7. MCP `biscotti_get_meeting` — `app_url`

`biscotti_get_meeting` gains one field on its result payload:

```json
{ "app_url": "biscotti://meeting/9F3C…-…" }
```

- **Always present** for a meeting that resolves (the tool already 404s
  otherwise), so the JSON schema marks it required alongside `id`/`title`.
- **No `tab` parameter** — it links to the meeting's default view (Summary),
  per the overview.
- Described in the tool schema so a client knows it may surface the link to
  the user: opening it shows that meeting in the Biscotti app.

`biscotti_query_meetings` and `biscotti_get_transcript` are unchanged. (Worth
revisiting later for the search-results list, but not in this project — see
§10.)

## 8. Testing

### The two alerts

Standard SwiftUI alerts on the app shell, one OK button, no recovery action:

| Trigger | Title | Message |
|---|---|---|
| `meeting/{uuid}` with no such meeting | Meeting Not Found | This link points to a meeting that is no longer in Biscotti. It may have been deleted. |
| `upcoming?key=` with no matching event | Event Not Found | This link points to a calendar event that is no longer upcoming. It may have ended, moved, or been cancelled. |

Only one alert can be pending at a time; a second failure replaces the first.

### Unit tests (gating, `make test`)

Parsing is pure and gets exhaustive table-driven coverage: every route, every
parameter combination, and the rejection cases (wrong scheme, unknown host,
bad UUID, unparseable time, missing required parameter, empty vs. absent
`query`, unknown parameter ignored, case-insensitivity of scheme/host/tab).

Behavior tests against `AppCore` cover: each route setting the expected
`route`/selection/query state; the tab-resolution order of §4.4 including the
`tab` + `time` conflict; the onboarding drop (R6); the no-op-does-not-navigate
rule; `record` while already recording; `record?title=`; and builder
round-tripping (§6).

The existing `DeepLinkTests.missingTimeIsNoOp` is rewritten to assert the new
behavior (opens on Summary).

### Manual test script (non-gating gate, `make manual-tests-check`)

A new `app_urls` script in `ManualTestKit/Scripts/`, registered in
`allScripts`. ManualTestApp is a separate application
(`net.scosman.biscotti.manualtest`), so it opens each URL through
`NSWorkspace` and macOS routes it to the real Biscotti app — a genuine
end-to-end test of system registration, not a simulation.

Shape: one `.action` button per URL that opens it, each followed by a
`.humanQuestion` confirming where Biscotti landed. Plus the three delivery
states unit tests cannot reach, as `.instruction` + `.humanQuestion` pairs:

- **Cold launch** — quit Biscotti entirely, then open a `meeting` URL.
- **Menu-bar only** — close Biscotti's window (app alive in the menu bar),
  then open a URL.
- **Background** — Biscotti open behind another app, then open a URL.

Per the repo's manual-test staleness rule, only recordable steps
(`.action`, `.humanQuestion`, `.autoCheck`) are written to
`manual_test_results.json`; the `.instruction` setup steps are not.

Note: this script needs the real Biscotti app installed and registered with
LaunchServices. If a stale copy of Biscotti is registered, URLs open *that*
build — the script says so explicitly in its first instruction step.

## 9. Documentation — `App/deeplinks.md`

The URL vocabulary is a public contract for other applications, so it is
documented in its own file, `App/deeplinks.md` — not folded into
`App/ConnectingMCP.md`, which is about a different integration.

It covers: every route in §4 with its parameters and defaults, the
tab/time resolution order, what a caller should expect from a bad URL
(nothing happens, deliberately — R3/R4), and a copy-pasteable example per
route. Written for someone integrating from outside Biscotti, who has no
access to this repo.

`biscotti_get_meeting`'s `app_url` description (§7) points at this document.

## 10. Deliberately deferred

- `app_url` on `biscotti_query_meetings` results.
- `settings?section=…` deep links.
- `biscotti://meeting/{uuid}?speaker=…` or other in-transcript anchors.
- Universal Links (`https://`), which need a domain and an AASA file.
- A `record` URL that also associates a calendar event (`?event=` key) —
  `AppCore.startRecording(eventKey:)` already supports it internally, but
  there is no emitter and the key is not durable (§4.6).
