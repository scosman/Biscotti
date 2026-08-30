---
status: complete
---

# MCP Server

I want to add an MCP server to Biscotti. Let's design it.

## UI

- Off by default, with an option in settings to enable it. Title "MCP", subtitle "Chat with your meeting notes in any agent."
- When on, subtitle: "Chat with your meeting notes in any agent."

## Technical notes

- Technically: an HTTP MCP server, bind to `127.0.0.1:8516`, validate `Origin`.
- No password for now — the local bind is the security layer.
- Design: this should be a new clean class/module. Nothing else depends on it. It can import data-model, search, etc.
- Zero overhead if not enabled.
- Use the newer MCP protocol (MCP has gone through a few versions).
- Use the official Swift SDK: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk).

## MCP tools

- `biscotti_query_meetings(…)` — returns a list of up to 50 meeting results. Short representation, something like
  `{results: [{id: 'uuid', title: 'The title', created_at: timestamp, query_snippit: 'matching snippit from search backend, if query param passed'}, …], results_truncated: false}`.
  Truncated flag true if list count == 50.
  - Function options: all optional, they stack. If none provided, return an error.
    - `query: string` — using our usual search stack
    - `before: timestamp`
    - `after: timestamp`
    - … maybe more?
  - Sorted by relevance if query provided; date (newest first) if query omitted.
- `biscotti_get_meeting(id: uuid)` — returns more meeting info than the search API: title, calendar event info in an object, AI summary, recording length, local path to audio files, transcript length, speaker labels, etc. Exact data TBD, but a rich representation.
- `biscotti_get_transcript(id: uuid)` — gets the formatted transcript. Description warns it can be long.
