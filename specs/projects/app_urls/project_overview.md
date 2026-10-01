---
status: complete
---

# App URLs

Register a URL handler with the system so URLs launch the app to the correct page.

## URLs

P1 — build these:

* `biscotti://meeting/UUID`
* `biscotti://meetings`
* `biscotti://settings`
* `biscotti://home`
* `biscotti://search?query=`
* `biscotti://record` (P2 to have a `title` param)

P2 — punt only if hard:

* `biscotti://upcoming/ID` (not sure we have an ID)

`meeting/UUID` should have a `?tab` option for summary, transcript, notes.

Only `biscotti://meeting/UUID` and `settings` have planned consumers, so the
rest can be punted if they turn out to be hard — but if they're all easy,
let's build and implement them.

## Behavior decisions

1. **Delivery:** handle all of it — cold launch (app not running), no-window
   menu-bar-only, and app-already-foreground.
2. **`meeting/UUID` with no params:** opens the meeting on the Summary tab —
   `time` becomes optional (today it is required and a bare link is a no-op).
   `?tab=transcript` or `?time=x` both jump to the transcript (the latter
   exists today).
3. **`search?query=`:** routes to Meetings, fills the search field, runs the
   search, and focuses the field so the user can keep typing.
4. **Bad URLs** (unknown host, unknown UUID): silent no-op.
5. **Onboarding:** ignore incoming URLs while onboarding is showing.
   **Recording:** navigate anyway — the recording keeps running and the user
   can return to it any time.
6. **`record` is unconditional** — no confirmation prompt, matching the
   global ⌘⇧R hotkey.

## Testing

The manual test app is the perfect companion to unit tests: it can hold the
links and confirmation that they worked. ManualTestApp is a separate app
(`net.scosman.biscotti.manualtest`, its own project/scheme), so it can open
`biscotti://` URLs through the system and have macOS route them to the real
Biscotti app — a real end-to-end test, including cold launch.

## Consuming feature

The MCP server should return a new `app_url` from `get_meeting`, linking to
the meeting (default tab, summary).
