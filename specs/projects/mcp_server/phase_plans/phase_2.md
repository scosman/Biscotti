---
status: complete
---

# Phase 2: The three tools

## Overview

Fill the empty tool catalog with the real read-only surface:
`biscotti_query_meetings`, `biscotti_get_meeting`, `biscotti_get_transcript`
(architecture §5–§6, functional spec §5). Adds the one DataStore read model the
detail tool needs (`meetingPeople(id:)`, architecture §7.2), the DTOs/schemas,
the transcript text formatter, ISO-8601 helpers, and the provider that maps
arguments → validation → store reads → `CallTool.Result`. The controller swaps
its empty `ListTools` handler for the catalog and registers the `CallTool`
handler. Phase 1's two implementation constraints are respected unchanged:
channel-handler-internal aggregation (no NIO handler changes here) and
bind-before-transport (`performStart` order untouched — only `makeServer`
gains the provider wiring, and the provider is created inside `makeServer`,
so a stopped controller still holds no tool objects).

## Decisions made while planning (within the decided design)

- **`audio_files` is always emitted**, and **deleted files keep their
  paths** paired with `present: false` (functional spec §5.2, confirmed as
  product intent in review). `DataStore.audioFileRefs` filters on `isPresent`
  and has UI callers relying on that, so the tool reads a new contained
  variant, `storedAudioFileRefs(meetingID:)` → `StoredAudioFileRefs`: stored
  paths regardless of presence, `present` reflecting the disk. "Fields
  omitted when not applicable" is applied to the scalar optionals
  (`end_date`, `recording_duration_seconds`, `summary`, `notes`, `tags`,
  `participants`, `organizer`, `calendar`).
- **`transcript_version_count` is always emitted** (0 is meaningful: versions
  exist independent of a preferred one).
- **`speakers[]` lists only segments with a non-nil `speakerID`**, one entry
  per distinct id in segment order (the wire example shows integer ids; a nil
  id has nothing stable to report and its label is not a speaker).
- **Empty-after-trim `query` → `invalidParams`** (FTS on an empty string is
  undefined; this is argument validation, not domain behavior).
- **Out-of-range `limit` → `invalidParams`** (reject, not clamp) — the input
  schema declares `minimum`/`maximum`, so violating it is a protocol error,
  matching functional spec §5's "invalid arguments → -32602".
- **Dates are formatted by creating `ISO8601DateFormatter` per call**, not a
  cached `static let`: the class is not statically Sendable, and tool-call
  frequency makes per-call init cost irrelevant.
- **Tool `annotations`** (`readOnlyHint: true`, `destructiveHint: false`,
  `idempotentHint: true`, `openWorldHint: false`) added to all three tools —
  the functional spec states all three are read-only; annotations are the
  standard way to say so.

## Steps

1. **`Sources/DataStore/DataStore+ReadModels.swift`** — add
   `MeetingPeople` (`organizer: PersonData?`, `participants: [PersonData]`
   uncapped/deduped/organizer-excluded) and
   `func meetingPeople(id: UUID) throws -> MeetingPeople?` (nil when the
   meeting is gone), next to `meetingDetail`. Review addendum: also
   `StoredAudioFileRefs` + `storedAudioFileRefs(meetingID:)` — stored paths
   regardless of on-disk presence, `present` reflecting the disk — used only
   by `biscotti_get_meeting` so `audioFileRefs`' UI callers are untouched.

2. **`Sources/MCPServer/MCPServerConfiguration.swift`** — add the tool-logic
   constants deferred from Phase 1: `searchCandidatePool = 500`,
   `maxResultLimit = 50`.

3. **`Sources/MCPServer/ToolDateFormatting.swift`** (new) —
   `enum ToolDateFormatting`: `format(Date) -> String` (UTC,
   `withInternetDateTime`, e.g. `2026-08-27T17:00:00Z`) and
   `parse(String) -> Date?` (full ISO-8601 with zone, optional fractional
   seconds, or bare `yyyy-MM-dd` → local midnight). Per-call formatter
   instances (see decisions).

4. **`Sources/MCPServer/TranscriptTextFormatter.swift`** (new) — pure
   `text(segments:names:)` per architecture §6.4: skip empty-after-trim
   segments; collapse consecutive segments with the same non-nil `speakerID`
   into one turn (`" " + trimmed`); name from `names[speakerID]` else
   `speakerLabel`; turn header `"[MM:SS] Name"`, `HH:MM:SS` from 3600 s up;
   turns joined by `"\n\n"`; nil-speaker segments always start their own turn.

5. **`Sources/MCPServer/MeetingToolPayloads.swift`** (new) — internal `Codable`
   DTOs with explicit snake_case `CodingKeys` (never a global strategy):
   `QueryMeetingsPayload` + `MeetingResultItem`, `MeetingDetailPayload`,
   `PersonPayload`, `AudioFilesPayload`, `CalendarPayload`,
   `TranscriptStatsPayload`, `SpeakerPayload`, `TranscriptPayload`. All
   optional fields rely on `encodeIfPresent` (omit, never `null`). Date fields
   are pre-formatted `String`s, so encoding needs no date strategy and the
   wire format has exactly one source (`ToolDateFormatting.format`).
   *Deviation from the architecture's nested-DTO sketch:* the payload structs
   are flat, not nested inside each other — the repo's strict `nesting` rule
   caps type nesting at one level and every DTO carries its own `CodingKeys`.

6. **`Sources/MCPServer/MeetingToolCatalog.swift`** (new) — `static let all:
   [Tool]` plus name constants (`biscotti_query_meetings`, …) shared with the
   provider. Descriptions verbatim from functional spec §5; `inputSchema`
   mirrors the parameter tables (including `"minimum": 1, "maximum": 50` on
   `limit`, per-property descriptions); `outputSchema` mirrors the payload
   shapes; read-only annotations (see decisions).

7. **`Sources/MCPServer/MeetingToolProvider.swift`** (new) —
   `actor MeetingToolProvider` with
   `func call(name:arguments:) async throws -> CallTool.Result`:
   - unknown name → `MCPError.methodNotFound`;
   - centralized argument helpers `requiredUUID`/`optionalString`/
     `optionalDate`/`optionalInt(range:)` → `MCPError.invalidParams` naming
     the field;
   - domain failures (unknown id, no transcript) → `isError` text result;
   - `DataStore`/other throws → caught once in `call`, logged (detail
     private), generic tool-error message (paths/queries never leak);
     `CancellationError` is rethrown, not converted (review addendum);
   - success → `CallTool.Result(content: [.text(sorted-key JSON)],
     structuredContent: dto)` — one DTO, two encodings;
   - algorithms per architecture §6.1–§6.3 (validation order, pool-500
     candidate draw for query+date, FTS order for query / date-desc otherwise,
     inclusive bounds, `results_truncated == (count == limit)`, stats computed
     on the preferred transcript's segments);
   - `debug` logs carry shapes only (which optional params, limit, result
     count) — never query text, titles, snippets, transcript text, paths.

8. **`Sources/MCPServer/MCPServerController.swift`** — `makeServer()` creates
   `MeetingToolProvider(store:)` (created in `start()`, released with the
   server), registers `ListTools` → `MeetingToolCatalog.all` and `CallTool` →
   `provider.call`. No lifecycle changes.

9. **`Package.swift`** — `MCPServerTests` gains the `Transcription` product
   dependency (fixtures need `TranscriptResult`).

10. **`Tests/MCPServerTests/TestSupport.swift`** — add
    `withRunningServer(store:_:)` so end-to-end tests can seed data; the
    existing no-store entry point delegates with a fresh in-memory store.

11. **`Sources/MCPServer/ToolArgumentDecoding.swift`** (new, discovered while
    building) — the centralized argument helpers (`requiredUUID`,
    `optionalNonEmptyString`, `optionalDate`, `optionalInt(range:)`) live in
    an `extension MeetingToolProvider` in their own file: the strict
    `type_body_length` limit (250) forced the split. Same for the test
    suites, which split query-logic (`MeetingToolProviderTests` + shared
    `MeetingToolTestSupport`) from detail/transcript logic
    (`MeetingToolDetailTests`) at the 350-line limit.

Two `ISO8601DateFormatter` behaviors surfaced in tests and are now pinned:
its default time zone is **GMT** (the bare-date branch pins
`TimeZone.current` explicitly), and it parses a `yyyy-MM-dd` *prefix* of a
longer string (so `parse` whole-matches the bare-date shape before using it —
a zone-less datetime is rejected, not silently date-truncated).

## Tests

- **`MeetingToolProviderTests`** (direct, in-memory store): query validation
  (no filter, `limit` alone, empty `query`, bad date, `after > before`, `limit`
  0/51/double); query relevance order (title beats transcript match);
  date-only newest-first; bare date accepted; inclusive `after`/`before`
  bounds; `results_truncated` true at exactly `limit` / false below;
  `query_snippet` only with `query`; empty result not an error.
  `get_meeting`: rich payload (calendar + tags + people + transcript + audio);
  omitted-optionals variants (no calendar, no transcript → `available: false`,
  empty summary/notes/tags omitted); unknown id → `isError`; deleted audio →
  `present: false` with the stored paths still reported; stats math on a known
  fixture (3 segments / 6 words / 34 chars, 2 speakers, mapped name). `get_transcript`: unknown id / no-transcript tool errors;
  empty-segment transcript → empty text, zero counts; text matches the
  formatter output.
- **`TranscriptTextFormatterTests`**: same-speaker collapsing; mapped vs
  unmapped names; `59:59` vs `01:00:00` boundary; nil-speaker segments; empty
  input; whitespace trimming.
- **`ToolDateFormattingTests`**: round-trip of a full timestamp; known literal
  (`1_700_000_000` → `2023-11-14T22:13:20Z`); offset `+02:00` equivalence;
  bare date → local midnight; garbage → nil.
- **`MeetingToolPayloadTests`**: golden-JSON key-shape assertions — snake_case
  keys present, optional keys absent (not `null`), nested calendar/transcript
  keys — decoded via `JSONSerialization` so the wire contract cannot drift.
- **`MCPToolRoundTripTests`** (real listener, seeded store): `initialize` →
  `tools/list` (3 tools, non-empty descriptions and schemas) → `tools/call`
  query → get_meeting → get_transcript chain over `URLSession`; unknown tool →
  `-32601`; invalid params → `-32602`; unknown id → HTTP 200 `isError` result.
  (Updates `MCPRoundTripTests`' Phase-1 "empty tools" expectations to the
  three-tool catalog.)
- **`Tests/DataStoreTests/MeetingPeopleTests.swift`**: uncapped (>5)
  participants; organizer excluded from participants and reported separately;
  dedupe by id; nil for unknown id. Review addendum:
  **`Tests/DataStoreTests/AudioRefTests.swift`** gains `storedAudioFileRefs`
  cases: deleted files keep paths with `present: false` (contrasted against
  `audioFileRefs` dropping them), mixed per-file presence, no-refs nils.
