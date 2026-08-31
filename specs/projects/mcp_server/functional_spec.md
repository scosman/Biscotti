---
status: complete
---

# Functional Spec: MCP Server

## 1. Summary

Biscotti gains an **opt-in local MCP server** so any MCP-capable agent (Claude
Desktop, Claude Code, Cursor, …) can search and read the user's meeting notes
and transcripts.

- **Off by default.** A single toggle, the last row of Settings → General.
- **Local only.** HTTP on `127.0.0.1:8516`, `Origin`-validated, no auth.
- **Read-only.** Three tools: query meetings, get one meeting, get its transcript.
- **Zero cost when off.** Nothing is bound, allocated, or scheduled unless enabled.

Non-goals for this project are listed in §10.

## 2. User-facing behavior

### 2.1 The Settings row

Last row of the **General** section (after "Show next meeting in menu bar" /
"App updates"), matching the existing toggle-with-caption pattern used by
"Keep app running in tray".

| State | Row | Caption |
|---|---|---|
| Off (default) | `MCP` toggle, off | "Chat with your meeting notes in any agent." |
| Starting | toggle on, disabled | "Starting…" |
| On | `MCP` toggle, on | "Chat with your meeting notes in any agent." + a **How to connect** link on the same line, after the subtitle, in the app accent color |
| Failed | toggle on | Error text (see §2.3) + **Retry** button |

The caption never shows the endpoint URL or a Copy button — those live only in
the sheet. When on, the **How to connect** link opens a small sheet (same
treatment as the existing `AlertsHelpSheet`) titled **"Connect to MCP"**
containing:

- one line of intent: *"Add Biscotti MCP to any agent to chat with your
  meeting notes."*,
- an **MCP Server URL** section: the endpoint URL at readable size with a
  **Copy** button,
- a link — *"How to connect to common agents (Claude, Cursor, etc)"* — opening
  the connection guide (`App/ConnectingMCP.md` on GitHub, `main` branch) in
  the browser,
- one sentence on what is exposed and to whom: *"Any app on this Mac can read
  your meetings while this is on. Nothing leaves your machine unless the agent
  you connect sends it somewhere."*

There is no JSON config snippet in the sheet: client configs are inconsistent
across agents, so per-client instructions live in the guide instead.

### 2.2 Lifecycle

- Toggling **on** starts the server immediately (sub-second); the row reflects
  the real state, not the intent.
- Toggling **off** stops the listener and closes open connections immediately.
- The setting persists. On app launch, the server starts iff the setting is on.
- The server lives only as long as the app process. Quitting stops it. Running
  in the menu bar with no window counts as running.
- Enabling does not require any macOS permission prompt. (The app is
  non-sandboxed with hardened runtime; loopback binds need no entitlement and
  are exempt from the macOS Local Network prompt.)

### 2.3 Port conflict and other start failures

If the bind fails (port `8516` already in use, or any other listener error):

- The toggle **stays on** — the user's intent is preserved.
- The caption is replaced by an error, e.g.
  *"Couldn't start: port 8516 is already in use by another app."*
  Other failures use a generic *"Couldn't start the MCP server."* plus the
  underlying reason.
- A **Retry** button re-attempts the bind.
- Turning the toggle off clears the error.
- No automatic port fallback and no automatic retry loop. A fixed port is
  what keeps the URL the settings sheet and the connection guide show stable.

## 3. Protocol surface

| Property | Value |
|---|---|
| Transport | MCP **Streamable HTTP**, stateless (no sessions, no SSE) |
| Protocol version | `2025-11-25` (SDK-negotiated; older versions accepted per SDK) |
| Bind | `127.0.0.1:8516` — loopback only, never `0.0.0.0` |
| Path | `/mcp` |
| Methods | `POST` only |
| Capabilities | `tools` only |

Responses:

- `POST /mcp` → JSON-RPC response (`application/json`).
- `GET`/`DELETE`/other on `/mcp` → `405` with `Allow: POST` (spec-legal for a
  server that offers no SSE stream).
- Any other path → `404`.
- Foreign `Origin` header → `403` (rejected before reaching any tool); absent
  `Origin` allowed (non-browser clients).
- Body larger than **1 MB** → `413`.

## 4. Security model

- **Loopback bind is the security boundary.** No password, token, or OAuth.
- **`Origin` validation** blocks DNS-rebinding attacks from a browser page.
- **Any local process running as this user can read every meeting**, including
  transcripts and the on-disk paths of audio files. This is accepted and stated
  in the help sheet. Exposing audio *paths* grants no access the caller didn't
  already have — a process that can open the path could have found it anyway.
- The server never writes: no tool mutates data, starts a recording, or changes
  settings (§10).
- Logging (`os.Logger`, category `MCP`) records lifecycle events and tool names
  with argument *shapes*. It never logs meeting content, titles, queries, or
  transcript text.

## 5. Tools

All three are read-only. Tool descriptions are written for a calling agent:
brief, but enough to know what Biscotti is and how the three tools compose.

Shared conventions:

- **Dates in and out are ISO-8601 strings** (`2026-08-30T14:03:00Z`). Inputs
  also accept a bare date (`2026-08-30`), interpreted as local midnight.
- A meeting's `date` is its **effective date**: the calendar start time when
  known, otherwise the creation time. (This is the date the app itself sorts
  and displays by; the overview called it `created_at`.)
- Every tool declares an `outputSchema` and returns both `structuredContent`
  and the same JSON serialized as text, per the 2025-11-25 spec.
- Invalid arguments → JSON-RPC `-32602` (invalid params). Valid-but-unsatisfiable
  requests (unknown id, no transcript) → a **tool error result** with a
  human-readable message, so the agent can recover rather than fail the turn.

### 5.1 `biscotti_query_meetings`

> Search the user's recorded meetings in Biscotti. Use
> `biscotti_get_meeting` for details and `biscotti_get_transcript` for what
> was said. Useful whenever the user asks about a meeting, call, sync,
> standup, or something someone said.

**Parameters** (all optional):

| Name | Type | Notes |
|---|---|---|
| `query` | string | Full-text search over title, summary, notes, transcript, people and tags. Prefix-matched per term, AND across terms. |
| `after` | string | Only meetings whose date is ≥ this. |
| `before` | string | Only meetings whose date is ≤ this. |
| `limit` | integer | 1–250, default 50. |

With **no filters at all**, the tool lists the user's meetings most recent
first (date descending) — it never errors for being unfiltered. `limit`
alone therefore means "the newest N".

There is no separate tag filter: tags are indexed by the search stack (and
weighted highly), so `query` already covers them.

**Ordering:** relevance (bm25) when `query` is given; date descending otherwise.

**Result:**

```json
{
  "results": [
    {
      "id": "5B1F…-UUID",
      "title": "Weekly sync",
      "date": "2026-08-27T17:00:00Z",
      "query_snippet": "…discussed the Q3 roadmap and…"
    }
  ],
  "results_truncated": false
}
```

- `query_snippet` is present only when `query` was passed.
- `results_truncated` is `true` when the returned count equals the effective
  `limit` — i.e. more matches may exist.
- No matches → `{"results": [], "results_truncated": false}` (not an error).
- Errors: unparseable date → invalid params. `before` earlier than `after` →
  invalid params. Unknown tag name is **not** an error — it simply matches
  nothing.

**Known limitation (documented, not fixed):** when `query` is combined with a
date filter, ranked candidates are drawn from the search index in a bounded
pool (500) before the date filter is applied. A date range that matches only
very low-ranked results could miss them. Acceptable at the scale of one
person's meeting history.

### 5.2 `biscotti_get_meeting`

> Full details for one Biscotti meeting: calendar context, AI summary, the
> user's notes, tags, participants, and transcript statistics. Does not include
> the transcript text — call `biscotti_get_transcript` for that.

**Parameters:** `id` (string, UUID) — required.

**Result** (fields omitted when not applicable — except `summary` and
`notes`, which are always present, `null` when the meeting has none):

```json
{
  "id": "…",
  "title": "Weekly sync",
  "date": "2026-08-27T17:00:00Z",
  "end_date": "2026-08-27T17:30:00Z",
  "recording_duration_seconds": 1804,
  "summary": "## Decisions\n…",
  "notes": "my own notes",
  "tags": ["roadmap", "eng"],
  "participants": [{"name": "Ada L.", "email": "ada@example.com"}],
  "organizer": {"name": "Ada L.", "email": "ada@example.com"},
  "audio_files": {
    "microphone": "/Users/…/mic.aac",
    "system": "/Users/…/system.aac",
    "present": true
  },
  "calendar": {
    "title": "Weekly sync",
    "start": "…", "end": "…",
    "location": "…",
    "conference_platform": "Zoom",
    "conference_url": "https://…",
    "calendar_name": "Work",
    "organizer": {"name": "…", "email": "…"},
    "attendees": [{"name": "…", "email": "…"}],
    "notes": "event description"
  },
  "transcript": {
    "available": true,
    "id": "…",
    "created_at": "…",
    "segment_count": 412,
    "word_count": 6180,
    "character_count": 34117,
    "speaker_count": 3,
    "speakers": [
      {"id": 0, "label": "Speaker 1", "name": "Ada L."},
      {"id": 1, "label": "Speaker 2"}
    ]
  },
  "transcript_version_count": 2
}
```

- `transcript` describes the **preferred** transcript version. When none exists:
  `{"available": false}`.
- `summary` and `notes` are **always present** — `null` when the meeting has
  none (never omitted).
- `recording_duration_seconds` is whole seconds, rounded (an integer, not a
  float).
- `speakers[].name` appears only where the user has mapped that speaker to a
  person.
- `audio_files.present` is false when the files were deleted from disk; the
  paths are still reported when known.
- Unknown `id` → tool error: *"No meeting with that id."*

### 5.3 `biscotti_get_transcript`

> The full diarized transcript of one Biscotti meeting, as plain text with
> speaker names and timestamps. **This can be very long** — a one-hour meeting
> runs to tens of thousands of words. Check `transcript.word_count` from
> `biscotti_get_meeting` first, and prefer the AI summary when you only need
> the gist.

**Parameters:**

| Name | Type | Notes |
|---|---|---|
| `id` | string (UUID) | required |
| `start_seconds` | number | Seconds from the start of the recording (0 = the beginning) where the returned window begins; inclusive. Only segments overlapping the `[start_seconds, end_seconds)` window are returned; either bound may be omitted. Timestamps in the returned text keep their original values. |
| `end_seconds` | number | Seconds from the start of the recording where the returned window ends; exclusive. Only segments overlapping the `[start_seconds, end_seconds)` window are returned; either bound may be omitted. Timestamps in the returned text keep their original values. |

`start_seconds` / `end_seconds` are **relative to the recording start,
zero-based**: `[start_seconds, end_seconds)` with start inclusive / end
exclusive, and the two bounds are independently optional. Only segments
**overlapping** the window are returned — the timestamp text of each line
stays absolute (unchanged values, filtered set), and `word_count` /
`character_count` describe the returned window. A window that matches
nothing (past the end, before the start, or `start_seconds ≥ end_seconds`)
returns empty `text` and zero counts — not an error.

**Result:**

```json
{
  "id": "…",
  "transcript_id": "…",
  "word_count": 6180,
  "character_count": 34117,
  "text": "[00:04] Ada L.\nLet's start with the roadmap.\n\n[00:31] Speaker 2\n…"
}
```

- Format: one block per speaker turn — a `[MM:SS] Name` header line, then the
  spoken text on its own line(s) below it, with a blank line between turns:

  ```
  [00:04] Ada L.
  Let's start with the roadmap.

  [00:31] Speaker 2
  Sure — I pushed the deck last night.
  ```

  Consecutive segments from the same speaker are collapsed into one turn.
  `HH:MM:SS` is used past the hour mark.
- Speaker names resolve through the user's speaker→person mapping; unmapped
  speakers keep their diarization label ("Speaker 2").
- Returns the **preferred** transcript version only.
- Never truncated — the description is the guard rail.
- Unknown `id` → tool error *"No meeting with that id."*
- Meeting exists but has no transcript → tool error *"That meeting has no
  transcript yet."*

## 6. Configuration

| What | Where | Default |
|---|---|---|
| Enabled | `AppSettings` (SwiftData), new `mcpServerEnabled: Bool` | `false` |
| Port | Compile-time constant `8516` | not user-configurable |
| Host | Compile-time constant `127.0.0.1` | not user-configurable |
| Path | Compile-time constant `/mcp` | not user-configurable |

## 7. Performance and resource limits

- **Disabled:** no listener, no event loop, no MCP server object, no timers.
  The only cost is reading one Bool at launch and observing the settings-change
  notification. Nothing is lazily warmed.
- **Enabled and idle:** an accept socket plus the listener's event loop threads.
- Request body cap 1 MB; concurrent connections capped (16) with excess
  connections closed; idle connections closed after 120 s.
- Tool calls are served off the main thread and hop to the `DataStore` actor.
  A large transcript read must not block the UI.

## 8. Testing

**Unit tests** (`swift test`, no hardware, no network beyond loopback):

- Tool layer against an in-memory `DataStore`: argument validation, filter
  stacking, ordering, truncation flag, snippet presence, all error paths,
  transcript formatting (speaker collapsing, name resolution, timestamps).
- End-to-end over a real listener bound to an **ephemeral port** (`127.0.0.1:0`):
  `initialize` → `tools/list` → `tools/call`, plus `Origin` rejection, 405 on
  GET, 404 on a foreign path, oversized body.
- Lifecycle: start/stop idempotence, restart after stop, bind-failure surfaces
  a failed state (bind the port twice).

**Manual test** — one step in the ManualTestApp results file, in the spirit of
the `make test-ai` reminder: a human runs the **real Biscotti app**, enables the
toggle, connects a real MCP client, and confirms the three tools list and
return sane data. Recorded as a single pass/fail step so
`make manual-tests-check` tracks it.

## 9. Edge cases

| Case | Behavior |
|---|---|
| Toggle flipped on/off rapidly | Serialized; final state wins; no orphan listener |
| Enabled but a meeting is deleted between query and get | `get_meeting` returns the not-found tool error |
| Client sends a JSON-RPC *notification* (e.g. `notifications/initialized`) | `202 Accepted`, empty body (SDK behavior) |
| Client opens the GET SSE stream | `405` — clients treat this as "no stream offered" and continue |
| Two clients connected at once | Both served; stateless, so no session interference |
| Transcript exists but has zero segments | `text: ""`, counts 0 — not an error |
| App quits while a request is in flight | Connection closes; no persistence concerns |
| Search index mid-rebuild | `searchHits` syncs the index first, as the app's own search does |

## 10. Out of scope

- Any **write** tool (create/edit meetings, notes, tags; start/stop recording).
- MCP **resources** and **prompts** — tools only.
- Authentication, OAuth, bearer tokens.
- Access from other machines, LAN binding, tunnels.
- Stateful sessions, SSE, server-initiated messages, progress notifications.
- A configurable port, or an in-app list of connected clients.
- Exposing audio *content* (only paths), or media/attachments.
