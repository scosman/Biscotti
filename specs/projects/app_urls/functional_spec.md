---
status: draft
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

## 3. General rules

These apply to every URL in §4.

**R1 — Scheme.** Scheme must be exactly `biscotti` (URL schemes are
case-insensitive per RFC 3986; compare lowercased). Anything else is ignored.

**R2 — Route key.** The route is the URL *host* (`biscotti://meetings` →
host `meetings`). Compared case-insensitively. An unknown host is a no-op.

**R3 — Bad input is a silent no-op.** Unknown host, malformed UUID,
unparseable numbers, a UUID with no matching meeting, a missing required
parameter: the URL is ignored. Nothing is shown to the user, no alert, no
error page. Every rejection is logged at `debug` via the existing `os.Logger`
for diagnosis.

**R4 — Window behavior on a no-op.** A rejected URL does **not** foreground
the app and does **not** open a window. Only a URL that resolves to a route
brings the app forward. (Rationale: a bad link from a background process
shouldn't yank focus.) Because rejection can only be determined after
parsing — and, for `meeting`, after an async store lookup — the app is
foregrounded *after* the route resolves, not before.

**R5 — Foregrounding.** A URL that resolves always: shows the main window
(creating it if needed), switches the activation policy to `.regular`, and
activates the app. This is the existing `AppDelegate.showMainWindow()` path.

**R6 — Onboarding.** While `route == .onboarding`, every incoming URL is
dropped (logged, not queued). The user finishes onboarding first.

**R7 — Recording.** An in-progress recording is never interrupted or stopped
by navigation. Navigating away from the recording pane is allowed; recording
continues and the user can return via the sidebar indicator. (`record` while
already recording is a no-op — see §4.7.)

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
(`store.meetingExists(id:)`). A well-formed UUID with no matching meeting is
a no-op (R3) — no navigation, no foregrounding.

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

**No existence check.** Unlike `meeting`, upcoming events are not stored by
key in a way that supports a cheap existence probe; `AppCore.selectEvent(_:)`
already routes to a preview that handles an unresolvable key. A key that no
longer matches a live event therefore navigates to an empty preview rather
than being a no-op. This is the one documented exception to R3, and it is
acceptable because the route is P2 with no current emitter.

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

**Already recording → no-op.** `AppCore.startRecording` already guards on
`runState` being `.idle`/`.detectedPending`, so a second `record` URL during
a recording does nothing. The URL does *not* navigate to the recording pane
in that case either; it is a plain no-op (R3/R4).

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

A single canonical builder is the only place URLs are constructed, so
emitters cannot drift from the parser. It covers every route in §4 and is
exercised by round-trip tests (build → parse → same intent).

Its first three consumers:

1. **`Recording/NotesMarkdown.swift`** — today it interpolates the
   `biscotti://meeting/{id}?time={s}` string by hand. It moves to the builder.
2. **The MCP server** — §7.
3. **The manual test script** — §8.

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

## 9. Documentation

The URL vocabulary is user-facing surface, so it gets written down rather
than living only in the parser. `App/ConnectingMCP.md` is the precedent for
this kind of doc. Exact location decided in the architecture step.

## 10. Deliberately deferred

- `app_url` on `biscotti_query_meetings` results.
- `settings?section=…` deep links.
- `biscotti://meeting/{uuid}?speaker=…` or other in-transcript anchors.
- Universal Links (`https://`), which need a domain and an AASA file.
- A `record` URL that also associates a calendar event (`?event=` key) —
  `AppCore.startRecording(eventKey:)` already supports it internally, but
  there is no emitter and the key is not durable (§4.6).
