---
status: draft
---

# Implementation Plan: CSV Import/Export

Four phases, bottom-up: the shared formatters land first (and immediately pay for
themselves by replacing two duplicated copies), then the store, then the CSV engine,
then the UI that wires it together.

## Phases

- [ ] **Phase 1 — `Formatting` module.** New Foundation-only module. Move `TimeFormatting`
  out of `DesignSystem` (and its tests), add `ISO8601Formatting` and
  `TranscriptTextFormatting` (render + parse). Rewire the three existing call sites:
  `MeetingDetailUI` Copy, `TranscriptListView`, and `MeetingToolProvider` in `MCPServer`
  (deleting its private `TranscriptTextFormatter`). Update MCP tests for the new
  timestamp form and mark the `mcp_*` manual-test steps `not-run`.

- [ ] **Phase 2 — DataStore.** Add `externalID` and `importBatch` to `Meeting`. Add the
  import write path (`existingMeetingIdentity`, `nextImportBatchID`,
  `insertImportedMeetings`), the export read path (`meetingIDsForExport`,
  `exportData(for:)`), and the debug-build bulk delete (`importedMeetingCounts`,
  `deleteImportedMeetings`), with the draft/read model types.

- [ ] **Phase 3 — `ImportExport` module.** CSV parser and writer, `MeetingCSVImporter.scan`
  with its full error/warning taxonomy, and the chunk-streaming `MeetingCSVExporter`.
  Entirely unit-testable — no UI, no app target.

- [ ] **Phase 4 — Wiring, UI, and docs.** AppCore's three actions plus the debug pair;
  the Settings Import/Export section with panels, spinners, and alerts; the debug
  Delete Imported Meetings row; and `App/ImportingExporting.md` linked from both rows.
