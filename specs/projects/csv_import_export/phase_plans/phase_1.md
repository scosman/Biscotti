---
status: complete
---

# Phase 1: `Formatting` module

## Overview

Create the Foundation-only `Formatting` module in BiscottiKit (three shared
formatters), rewire the three existing transcript-text call sites onto it
(`MeetingDetailUI` Copy, `TranscriptListView`, `MCPServer`'s
`MeetingToolProvider`), and delete the two duplicated implementations
(`TranscriptContent.plainText`/`displayName`, `MCPServer.TranscriptTextFormatter`).
The MCP transcript output timestamp changes from `[00:04]` to `[0:04]`
(`TimeFormatting.formatPlaybackTime`), so MCP tests are updated and the
`mcp_*` manual-test steps are marked `not-run` per the staleness rule.

## Steps

1. **New module sources** under `Packages/BiscottiKit/Sources/Formatting/`:
   - `TimeFormatting.swift` — moved verbatim from `DesignSystem`.
   - `ISO8601Formatting.swift` — `string(from:)` renders
     `2026-01-03T14:26:42.017Z` via a per-call `ISO8601DateFormatter`
     (UTC, `.withFractionalSeconds` — the `Date.ISO8601FormatStyle`
     originally sketched here truncates sub-millisecond error downward,
     see architecture §3.2); `date(from:)` lenient parse: ISO-8601 with
     fractional seconds → without → whole-string `^-?\d+$` epoch
     (ms when `abs >= 100_000_000_000`, else s) → whole-string
     `\d{4}-\d{2}-\d{2}` local midnight. Input trimmed.
   - `TranscriptTextFormatting.swift` — `displayName(for:names:)` (moved
     from `TranscriptContent`), `render(_:names:)` (`[M:SS] Name` headers,
     same-`speakerID` collapse joined by a space, nil-speaker never
     collapses, blank segments dropped, `formatPlaybackTime` timestamps),
     `parse(_:)` → `[TranscriptSegmentDraft]` (header regex
     `^\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})\]\s*(.*)$`, `Name: inline text`
     split, one segment per non-header line, `Unknown Speaker` at 0 before
     any header, sequential speaker IDs in first-appearance order).
2. **DataStore**: add `TranscriptSegmentDraft` (architecture §2.1 shape) in a
   new `Sources/DataStore/ImportDrafts.swift` — needed now by
   `TranscriptTextFormatting.parse`; the meeting-level drafts follow in
   Phase 2.
3. **`Package.swift`**: add `Formatting` product + target (deps: `DataStore`)
   and `FormattingTests` (deps: `Formatting`, `DataStore`); add `Formatting`
   to `DesignSystem`, `MCPServer`, `MeetingDetailUI`, `HomeUI`,
   `MeetingListUI`, `AppShellUI`, `MenuBarUI` and to the test targets that
   name its symbols (`AppCoreTests`, `HomeUITests`, `MeetingListUITests`,
   `MeetingDetailUITests`).
4. **Rewire call sites** (each gains `import Formatting`):
   - `TranscriptContent`: delete `displayName` + `plainText`; speaker colors
     stay.
   - `MeetingDetailViewModel.copyTranscript` → `TranscriptTextFormatting.render`.
   - `TranscriptListView` → `TranscriptTextFormatting.displayName`.
   - Delete `MCPServer/TranscriptTextFormatter.swift`;
     `MeetingToolProvider.getTranscript` → `TranscriptTextFormatting.render`.
5. **Tests**:
   - Move `DesignSystemTests/TimeFormattingTests.swift` →
     `FormattingTests/` (import swapped).
   - New `ISO8601FormattingTests.swift` and `TranscriptTextFormattingTests.swift`
     (render / parse / round-trip / displayName cases, architecture §9).
   - Delete `MCPServerTests/TranscriptTextFormatterTests.swift`; update
     `[00:xx]` expectations in `MCPTranscriptWindowTests`,
     `MeetingToolDetailTests`, `MCPToolRoundTripTests` to `[0:xx]`.
   - `MeetingDetailUITests`: drop the `plainText`/`displayName` suites
     (superseded by FormattingTests; color suites stay); switch
     `SpeakerMappingTests` to `render`.
6. **Manual tests**: set `mcp_real_client` to `not-run` (no timestamp) in
     `ManualTestApp/Results/manual_test_results.json` — the only recordable
     `mcp_*` step (`mcp_connect` is `.instruction`).

## Tests

- `TimeFormattingTests` — moved unchanged.
- `ISO8601FormattingTests` — exact render; every accepted input form
  (fractional/offset/no-fractional, bare date local midnight, epoch s/ms,
  both sides of the 1e11 boundary); rejects `yesterday`, `2026-13-45`,
  `2026-01-03T14:26`, empty; trims whitespace.
- `TranscriptTextFormattingTests` — render: single/alternating speakers,
  same-speaker collapse, nil-speaker never collapses, name resolution +
  label fallback, hour-plus timestamps, blank dropped, empty → "";
  parse: plain text (no headers), own format, inline `Name: text`,
  `H:MM:SS`, blank lines dropped, one segment per line, sequential speaker
  IDs, nameless header, text before first header, empty → []; round-trip
  preserves speakers/times/words; displayName resolution.
- MCP + MeetingDetailUI suites updated to the new shared output, all green.
