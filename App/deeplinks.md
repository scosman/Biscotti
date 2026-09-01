# Biscotti App URLs

Biscotti for macOS registers the `biscotti://` URL scheme. Any process on
the machine — a shell script, a note-taking app, an MCP client, a
launcher — can open one of these URLs to launch or foreground Biscotti on
a specific page.

Links are **machine-local**: they resolve against the meeting library on
the Mac that opens them. A link copied on one computer means nothing on
another.

## Opening a URL

From a shell or script:

```sh
open 'biscotti://meetings'
```

From an app, open the URL like any other (`NSWorkspace.open`, `openURL`,
…). macOS launches Biscotti if it is not running, re-opens its window if
the app is running menu-bar-only, and brings the app to the front
otherwise. If Biscotti is still in first-run onboarding, the URL is
dropped.

## Routes

| Route | Opens |
|---|---|
| `biscotti://home` | The Home screen |
| `biscotti://meetings` | The Meetings screen (browse mode) |
| `biscotti://settings` | Settings, at its default section |
| `biscotti://meeting/{uuid}` | One meeting (see below) |
| `biscotti://search?query={text}` | Meetings screen, search filled and focused |
| `biscotti://upcoming?key={key}` | The preview of an upcoming calendar event |
| `biscotti://record[?title={text}]` | Starts a recording immediately |

```sh
open 'biscotti://home'
open 'biscotti://meetings'
open 'biscotti://settings'
open 'biscotti://search?query=roadmap'
open 'biscotti://record?title=Standup'
```

### `biscotti://meeting/{uuid}`

Opens the meeting with that UUID, selected in the Meetings screen.

| Part | Required | Notes |
|---|---|---|
| path `{uuid}` | yes | Case-insensitive UUID. Invalid → ignored. |
| `?tab=` | no | `summary` (default), `transcript`, or `notes`. Unrecognized values fall back to `summary`. |
| `?time=` | no | Seconds from the recording start, e.g. `42` or `102.7`. Implies the transcript tab, with playback cued to that time (clamped to the recording length). |

When both `tab` and `time` are present, `time` wins.

```sh
open 'biscotti://meeting/9F3C2A54-1B7D-4E8E-9C21-5D0A6B7C8D9E'
open 'biscotti://meeting/9F3C2A54-1B7D-4E8E-9C21-5D0A6B7C8D9E?tab=notes'
open 'biscotti://meeting/9F3C2A54-1B7D-4E8E-9C21-5D0A6B7C8D9E?time=102.7'
```

The `app_url` field returned by Biscotti's MCP tool `biscotti_get_meeting`
is a link of this form. Biscotti itself also offers **Copy Meeting Link**
in the meetings list context menu and the detail overflow menu.

### `biscotti://search?query={text}`

Routes to the Meetings screen, fills the search field with `{text}`, runs
the search, and focuses the field so the user can keep typing. An empty
`query` (`biscotti://search?query=`) is a valid "open search" affordance;
a wholly absent `query` parameter is ignored.

### `biscotti://upcoming?key={key}`

Opens the read-only preview of an upcoming calendar event.

```sh
# Substitute a real, percent-encoded composite key for COMPOSITE_KEY —
# as written this is a non-empty but unknown key, so it shows
# "Event Not Found".
open 'biscotti://upcoming?key=COMPOSITE_KEY'
```

`{key}` is an internal identifier Biscotti derives from the event:
`{eventIdentifier}|{calendarItemIdentifier}|{unixTimestamp}` — the
EventKit identifiers joined with `|`, plus the occurrence's start time in
Unix seconds. Percent-encode the value (`|` as `%7C`) when building the
URL. No Biscotti feature currently emits these links; there is no stable
public identifier for recurring-event occurrences, and a link to a
rescheduled event stops resolving. Do not store these long-term.

### `biscotti://record[?title={text}]`

Starts a recording immediately and shows the recording pane — no
confirmation, exactly like Biscotti's global ⌘⇧R shortcut. `title` names
the new meeting instead of the default. If a recording is already in
progress, the app simply shows it. Recording permissions apply as usual.

## What a caller should expect from a bad URL

| Failure | Behavior |
|---|---|
| Wrong scheme, unknown route, malformed UUID/number, missing required parameter | **Nothing navigates.** The app does not come to the front; if it was not running, a bad URL may still launch it. Unknown *extra* parameters are ignored so links stay forward-compatible. |
| Well-formed link to a meeting or event that no longer exists | The app comes to the front and shows a "Meeting Not Found" / "Event Not Found" alert. |

## Rules that apply to every route

- The scheme and route are case-insensitive (`BISCOTTI://Meetings` works).
- Values are percent-encoded; read them through any standard URL parser.
- An in-progress recording is never interrupted by navigation.
- Only `record` has a side effect; every other route just navigates.
