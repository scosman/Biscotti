---
status: complete
---

# Implementation Plan: MCP Server

Three phases. Each ends green on `make precommit-checks` (format + lint + test)
and is reviewable on its own.

## Phases

- [x] **Phase 1 — Dependencies and transport plumbing**
  Resolve the MCP SDK (try `0.12.1`, fall back to `0.11.0` per architecture
  §2.1) and swift-nio into `Packages/BiscottiKit`. Create the `MCPServer`
  target and product: configuration, state types, `HTTPListener`,
  `HTTPChannelHandler`, `MCPServerController`, logging. Wire an `MCP.Server`
  with an empty tool catalog. Tests: HTTP-surface behavior (405/404/403/413,
  malformed JSON, notification → 202), `initialize` + `tools/list` round trip
  on an ephemeral port, and the lifecycle cases (idempotent start/stop,
  start→stop→start rebinds, port-in-use → `.failed`).

- [x] **Phase 2 — The three tools**
  `DataStore.meetingPeople(id:)` and its read model. `MeetingToolCatalog`
  (names, descriptions, input/output schemas), `MeetingToolPayloads`,
  `TranscriptTextFormatter`, `ToolDateFormatting`, and `MeetingToolProvider`
  implementing `biscotti_query_meetings`, `biscotti_get_meeting`,
  `biscotti_get_transcript` per architecture §6. Tests: the full tool-logic and
  payload-encoding list from architecture §10, plus `tools/call` end-to-end
  over the real listener.

- [x] **Phase 3 — Settings, wiring, and docs**
  `mcpServerEnabled` on `AppSettings`/`AppSettingsData`, the
  `.mcpServerEnabledDidChange` notification, AppCore ownership and the
  start-on-launch / observe-changes path, the General settings row with its
  four states (Copy button, Retry) and the How-to-connect sheet. Add the
  `MCPScript` manual test with its one recordable step and register it in
  `allScripts`. Update `specs/architecture.md` (new module in the topology) and
  `CLAUDE.md` (module list, manual-test staleness rule now covers
  `mcp_*` steps).
