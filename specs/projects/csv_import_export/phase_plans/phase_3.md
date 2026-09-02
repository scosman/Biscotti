---
status: complete
---

# Phase 3: `ImportExport` module

## Overview

Create the `ImportExport` module in BiscottiKit: the RFC 4180 CSV
parser/writer, the pure `MeetingCSVImporter.scan` with the full
error/warning taxonomy from functional spec §3, and the chunk-streaming
`MeetingCSVExporter` (functional spec §5). Entirely unit-testable — no UI,
no app target, no store writes during scan. `AppCore` wiring is Phase 4.

## Steps

1. **`Package.swift`** — add the `ImportExport` product + target (deps:
   `DataStore`, `Formatting`) and `ImportExportTests` (deps:
   `ImportExport`, `DataStore`, `Formatting`).
2. **`Sources/ImportExport/ImportExportLog.swift`** — module
   `Logger(subsystem: "net.scosman.biscotti", category: "ImportExport")`
   (architecture §8: counts and row numbers only, never file contents).
3. **`Sources/ImportExport/CSVParser.swift`** — internal
   `CSVParseError.unterminatedQuote(row:)` (typed throw, 1-based rows) and
   `CSVParser.parse(_:) -> [[String]]`: state machine over
   `unicodeScalars` (`fieldStart`/`inUnquoted`/`inQuoted` + a
   just-saw-a-quote flag for `""`); CRLF/LF/CR terminators outside quotes;
   terminators inside quotes are content; no phantom row for a trailing
   terminator; a leading U+FEFF BOM tolerated.
4. **`Sources/ImportExport/CSVWriter.swift`** — internal
   `CSVWriter.field(_:)` (quote when the field has a comma, quote, CR, or
   LF; double embedded quotes) and `CSVWriter.row(_:)` (comma-joined,
   CRLF-terminated).
5. **`Sources/ImportExport/CSVColumns.swift`** — internal column table:
   canonical names in order, the three `document_*` aliases, the required
   subset, and the canonical header row string. Shared by the importer
   (resolution), the exporter (header), and warning copy (alias names).
6. **`Sources/ImportExport/ImportScanResult.swift`** — public
   `ImportScanResult` (`drafts`/`warnings`/`criticalErrors`,
   `canProceed`, `needsReview`), `ImportCriticalError` (six cases,
   verbatim alert copy in `message`), `ImportWarning` (six cases with
   counts and ≤5 example row numbers, `message` copy matching functional
   spec §3.2 wording).
7. **`Sources/ImportExport/MeetingCSVImporter.swift`** — public
   `scan(fileURL:existing:)` (never throws) + internal
   `scan(data:existing:)` following architecture §4.2's eight steps:
   read → strip BOM bytes → UTF-8 decode → parse → header resolution
   (trim + lowercase, aliases, first occurrence, canonical-wins with
   `ambiguousColumns` warning) → per-row ragged pad/truncate → required
   validation → duplicate checks (DB identity, then in-file first-wins
   claims) → `emptyContent` tally → transcript parse → draft. Blank lines
   (a row parsing to a single empty field) are dropped, not reported as
   misformatted rows. Warnings assembled in a fixed order;
   `.nothingToImport` appended when no drafts and at least one data row.
8. **`Sources/ImportExport/MeetingCSVExporter.swift`** — public
   `MeetingCSVExporter` (`Sendable`, holds the `DataStore` actor +
   `chunkSize`): `export(to:now:) async throws -> URL` writes the header
   then streams `exportData(for:)` chunks of `chunkSize` through a
   `FileHandle`; `Biscotti_export_{yyyy-MM-dd-HHmmss}.csv` filename in
   local time; `CSVExportError.cannotCreateFile` for the Bool-returning
   create; partial file removed in a `defer` on any failure.
9. **Tests** — new `Tests/ImportExportTests/` target per architecture §9
   (CSVParser, CSVWriter, all thirteen scan cases plus the critical-path
   and ragged/example-cap cases, and the eight exporter cases). Exporter
   tests seed the store via `insertImportedMeetings`/`createMeeting`, so
   no `Transcription` dependency is needed.

## Tests

- `CSVParserTests` — embedded commas/newlines in quoted fields; doubled
  quotes; CRLF, LF, and CR separators; trailing terminator produces no
  phantom row; leading BOM; ragged rows passed through; unterminated
  quote throws with the 1-based row; empty input; final row kept without
  terminator; empty quoted field; text after a closing quote is kept
  (lenient).
- `CSVWriterTests` — quoting only when needed (comma/quote/CR/LF);
  doubling; CRLF row terminator; round-trip through `CSVParser`.
- `MeetingCSVImporterTests` — alias-only CSV imports (the explicit spec
  case); unknown columns ignored (with case/whitespace-lenient header);
  missing columns → `.missingColumns` in canonical order; blank
  id/title/unparseable date → `misformattedRows` with example rows while
  other rows import; UUID and non-UUID ids already in the database →
  `alreadyInDatabase`; non-UUID new id → `externalID` + minted UUID;
  UUID new id used directly; duplicate id in file → first wins +
  `duplicateInFile`; content-less row → `emptyContent` but still
  imported; multi-line quoted transcript → parsed segments;
  everything-bad → `.nothingToImport`, `canProceed == false`; both
  `id` and `document_id` → `ambiguousColumns`, canonical wins;
  unreadable path → `.unreadableFile`; non-UTF-8 bytes → `.notUTF8`;
  empty data → `.emptyFile`; unterminated quote in a data row →
  `.malformedCSV(row: 2)`; BOM-prefixed bytes import; blank lines among
  the data dropped without warnings; ragged short row padded (with
  content → ragged only; missing created → ragged + misformatted); long
  row truncated; example rows capped at 5; epoch-milliseconds `created`;
  clean file → `needsReview == false`; drafts keep file order.
- `MeetingCSVExporterTests` — header line exactly canonical; empty store
  → header-only file; newest-first row order; commas/quotes/newlines
  escaped (round-trip through `CSVParser`); no transcript → empty final
  field; chunkSize 2 with 5 meetings byte-identical to one chunk;
  `Biscotti_export_2026-09-01-142642.csv` filename shape from local-time
  components; export → `scan` round-trip preserves ids, dates, and
  transcript rendering (idempotent re-render).
