---
status: complete
---

# Architecture: CSV Import/Export

Single architecture doc — the components are numerous but individually shallow (a CSV
state machine, two formatters, a scanner, an exporter, a settings section). None has
enough internal complexity to justify its own component design.

## 1. Module layout

Two new modules in `BiscottiKit`, plus additive changes to four existing ones.

```
Formatting  (new)          Foundation + DataStore. Pure, no UI, no I/O.
  ├── TimeFormatting              moved here verbatim from DesignSystem
  ├── ISO8601Formatting           CSV date render + lenient parse
  └── TranscriptTextFormatting    render + parse the "[0:23] Steve" format

ImportExport (new)         Foundation + DataStore + Formatting. No UI, no AppKit.
  ├── CSVParser / CSVWriter       RFC 4180
  ├── MeetingCSVImporter          scan → ImportScanResult (pure; no store access)
  └── MeetingCSVExporter          streams the CSV to a temp file

DataStore    (changed)     externalID + importBatch fields; import/export read+write API
AppCore      (changed)     owns the importer/exporter, exposes three async actions
SettingsUI   (changed)     new Import/Export section, panels, alerts
MeetingDetailUI (changed)  Copy uses the shared renderer; local plainText deleted
MCPServer    (changed)     local TranscriptTextFormatter deleted; uses the shared one
DesignSystem (changed)     depends on Formatting; TimeFormatting no longer declared here
```

Dependency direction stays acyclic: `Formatting → DataStore`, `ImportExport →
{DataStore, Formatting}`, `DesignSystem → {DataStore, Formatting}`, `AppCore →
ImportExport`, `SettingsUI → AppCore`.

### 1.1 Why a `Formatting` module

`TimeFormatting` is already pure Foundation — it imports nothing but `Foundation` and
happens to live in `DesignSystem`, which drags in SwiftUI. Three non-UI consumers now
need timestamp rendering (export, MCP, import parsing), so the enum moves down into a
Foundation-only module rather than being duplicated a third time (`MCPServer` already
carries a private copy today).

`Formatting` depends on `DataStore` for `SegmentData` and the transcript draft types.
That mirrors `DesignSystem`, which already depends on `DataStore`.

**Cost of the move:** `TimeFormatting` is referenced by 10 sources and 5 test files.
Each gains one `import Formatting` line — Swift does not re-export transitively, and
`@_exported import` is underscored API we should not adopt. The change is purely
mechanical and the compiler finds every site.

## 2. Data model

Two additive properties on `Meeting`:

```swift
/// The row's `id` from an imported CSV when it was not a UUID. Nil for
/// recorded meetings and for imports whose ID parsed as a UUID.
public var externalID: String?

/// Epoch milliseconds identifying the import run that created this meeting.
/// Nil for every recorded meeting. Written once, never read yet — it exists
/// so a future "undo this import" can find the batch.
public var importBatch: Int?
```

Both are optional with nil defaults, so SwiftData handles them without a migration
stage (the existing `DataStoreMigrationPlan` comment covers exactly this case). No
`DataStoreSchemaV2` is needed.

`importBatch` is `Int?` holding epoch **milliseconds** — SwiftData stores it as an
integer, it sorts naturally, and it needs no formatter.

### 2.1 Write model (defined in DataStore)

The scanner produces these; `DataStore` consumes them. They live in `DataStore` so that
`Formatting` (which produces the segment drafts) and `ImportExport` (which produces the
meeting drafts) both depend *downward* onto them — defining them in `ImportExport` would
force `DataStore` to depend on `ImportExport` and create a cycle.

```swift
public struct TranscriptSegmentDraft: Sendable, Equatable {
    public let speakerID: Int
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let text: String
}

public struct ImportedMeetingDraft: Sendable, Equatable {
    public let meetingID: UUID          // parsed UUID, or freshly minted
    public let externalID: String?      // raw id when it was not a UUID
    public let title: String
    public let created: Date
    public let summary: String
    public let notes: String
    public let transcript: [TranscriptSegmentDraft]   // empty = no transcript record
}

/// Everything already in the database that an import must not duplicate.
public struct ExistingMeetingIdentity: Sendable, Equatable {
    public let meetingIDs: Set<UUID>
    public let externalIDs: Set<String>
}
```

### 2.2 Read model for export

```swift
public struct MeetingExportData: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date                 // startDate ?? createdAt
    public let summary: String
    public let notes: String
    public let segments: [SegmentData]    // preferred transcript, empty when none
    public let speakerNames: [Int: String] // resolved person names by speaker ID
}
```

### 2.3 New DataStore methods

```swift
// Import
public func existingMeetingIdentity() throws -> ExistingMeetingIdentity
public func nextImportBatchID(now: Date = Date()) throws -> Int
public func insertImportedMeetings(
    _ drafts: [ImportedMeetingDraft], batchID: Int
) throws -> Int

// Export
public func meetingIDsForExport() throws -> [UUID]           // newest first
public func exportData(for ids: [UUID]) throws -> [MeetingExportData]

// Debug-build bulk delete (functional spec §6.1)
public func importedMeetingCounts() throws -> (imported: Int, remaining: Int)
public func deleteImportedMeetings() throws -> Int
```

`existingMeetingIdentity()` fetches all meetings and maps `id` / `externalID` into two
sets. At the expected scale (thousands) this is a single cheap fetch; if it ever needs
to scale, `FetchDescriptor.propertiesToFetch` narrows it without changing the signature.

`nextImportBatchID` returns `Int(now.timeIntervalSince1970 * 1000)`, incrementing while
a meeting with that exact `importBatch` already exists, so two imports inside the same
millisecond cannot share a batch.

`insertImportedMeetings` creates, per draft: a `Meeting` (with `editedTitle = true`,
`editedSummary = !summary.isEmpty`, `importBatch = batchID`, `startDate`/`endDate` nil),
and when `transcript` is non-empty a `TranscriptRecord` with
`transcriptionMethodId = "imported"`, `language = ""`, `speakerCount` = distinct speaker
IDs, plus one `TranscriptSegmentRecord` per draft segment with `index` set in order and
`endTime = startTime`. `preferredTranscriptID` points at the new record. One `save()` at
the end of the batch. Returns the number of meetings inserted.

`importedMeetingCounts()` runs two `fetchCount` calls with
`#Predicate<Meeting> { $0.importBatch != nil }` and its negation — no objects
materialized. `deleteImportedMeetings()` fetches the matching meetings, and for each one
removes its search-index entry (`searchIndex.removeMeeting(uuid:)`) before
`context.delete`, exactly as `delete(meetingID:)` does, then saves once. Transcripts,
segments, words, audio refs, and calendar snapshots go with them via the existing
`.cascade` delete rules.

**Search index:** nothing extra is needed for insertion. `syncSearchIndex()` is lazy and driven by
SwiftData history at query time, so imported meetings are indexed on the next search.

## 3. `Formatting` module

### 3.1 `TimeFormatting`

Moved from `DesignSystem` unchanged, along with its test file. `DesignSystem` gains a
dependency on `Formatting`; `AudioTransport.formatTime` keeps delegating to it.

### 3.2 `ISO8601Formatting`

```swift
public enum ISO8601Formatting {
    /// "2026-01-03T14:26:42.017Z" — UTC, milliseconds, always.
    public static func string(from date: Date) -> String
    /// Lenient parse per functional spec §1.3. Nil when nothing matches.
    public static func date(from string: String) -> Date?
}
```

Rendering uses a per-call `ISO8601DateFormatter` (UTC,
`.withFractionalSeconds`). The originally prescribed `Date.ISO8601FormatStyle`
(with `.time(includingFractionalSeconds: true)`) was found during
implementation to truncate the sub-millisecond `Date` representation error
downward — a `.017` instant renders `.016` — which breaks both the exact
output string (§1.3) and the render→parse round-trip; `ISO8601DateFormatter`
rounds to the nearest millisecond and round-trips exactly.

Parsing tries, in order: ISO-8601 with fractional seconds; ISO-8601 without; a
whole-string `^-?\d+$` integer (epoch — milliseconds when `abs(value) >= 100_000_000_000`,
otherwise seconds); a whole-string `\d{4}-\d{2}-\d{2}` date at local midnight. The
whole-string match on the bare-date branch matters: `ISO8601DateFormatter` happily
parses a `yyyy-MM-dd` *prefix* and silently drops the time, which is the bug
`ToolDateFormatting` already documents. Input is trimmed before matching.

`ISO8601DateFormatter` instances are created per call (not `Sendable` as statics); the
cost is irrelevant next to file I/O.

### 3.3 `TranscriptTextFormatting`

```swift
public enum TranscriptTextFormatting {
    public static func displayName(for segment: SegmentData, names: [Int: String]) -> String
    public static func render(_ segments: [SegmentData], names: [Int: String] = [:]) -> String
    public static func parse(_ text: String) -> [TranscriptSegmentDraft]
}
```

**Render.** Emits `[<time>] <name>` followed by the text, blank line between turns.
Consecutive segments sharing the same non-nil `speakerID` collapse into one turn, their
text joined by a space (this is what `MCPServer` does today, and it is much more
readable than a header per WhisperKit fragment). Segments with nil `speakerID` never
collapse. Blank segments are dropped. Timestamps come from
`TimeFormatting.formatPlaybackTime` — `0:23`, `1:02:03`.

> **Change from functional spec §4.1.** The spec claimed byte-exact round-tripping.
> With collapsing, a round-trip preserves every speaker, timestamp, and word, but
> adjacent same-speaker segments merge into one. That is the right trade: segment
> boundaries are diarization artifacts, not meaning, and a header per fragment makes
> both the Copy output and the CSV unreadable. The functional spec is updated to match.

**Parse.** Per functional spec §4.2:

- Split on `\r\n`, `\n`, or `\r`. Trim each line; drop empty lines.
- Header pattern: `^\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})\]\s*(.*)$`. Two numeric groups =
  `M:SS`, three = `H:MM:SS`.
- The trailing capture is the speaker name. If it contains a colon, everything before
  the first colon is the name and everything after is treated as a content line for that
  speaker (`[0:23] Steve: hello` → speaker `Steve`, text `hello`). An empty name means
  `Unknown Speaker`.
- Non-header lines become one draft segment each, carrying the current speaker and
  timestamp. **No merging** — one line, one segment.
- Before any header: `Unknown Speaker` at `0`.
- Speaker IDs are assigned sequentially (0, 1, 2 …) per distinct name in first-appearance
  order, so the existing speaker-mapping UI works on imported transcripts.

## 4. `ImportExport` module

### 4.1 CSV parsing and writing

```swift
enum CSVParser {
    /// Rows of fields. Throws `CSVParseError.unterminatedQuote(row:)`.
    static func parse(_ text: String) throws -> [[String]]
}
enum CSVWriter {
    static func field(_ value: String) -> String   // quotes + doubles when needed
    static func row(_ fields: [String]) -> String  // joined, CRLF-terminated
}
```

A hand-rolled RFC 4180 state machine over `text.unicodeScalars` — three states
(`fieldStart`, `inUnquoted`, `inQuoted`) plus a "just saw a quote inside a quoted field"
flag to handle `""`. No dependency is worth adding for ~80 lines, and a dependency would
not give us the leniency (mixed line endings, ragged rows, BOM) we need anyway.

The BOM is stripped by the caller before parsing. Row terminators inside quotes are
literal content; outside quotes, any of CRLF/LF/CR ends a row. A trailing terminator at
EOF does not produce a phantom empty row.

### 4.2 The importer

Pure and store-free — it is handed the existing identity rather than reaching for a
database, which makes every case in §3 of the functional spec a plain unit test.

```swift
public struct ImportScanResult: Sendable, Equatable {
    public let drafts: [ImportedMeetingDraft]   // importable rows only, in file order
    public let warnings: [ImportWarning]
    public let criticalErrors: [ImportCriticalError]
    public var canProceed: Bool { criticalErrors.isEmpty && !drafts.isEmpty }
    public var needsReview: Bool { !warnings.isEmpty || !criticalErrors.isEmpty }
}

public enum ImportCriticalError: Sendable, Equatable {
    case unreadableFile(String)
    case notUTF8
    case emptyFile
    case missingColumns([String])       // canonical names, in canonical order
    case malformedCSV(row: Int)
    case nothingToImport
    public var message: String { … }    // verbatim alert copy
}

public enum ImportWarning: Sendable, Equatable {
    case misformattedRows(count: Int, exampleRows: [Int])
    case emptyContent(count: Int)
    case alreadyInDatabase(count: Int)
    case duplicateInFile(count: Int, exampleRows: [Int])
    case raggedRows(count: Int, exampleRows: [Int])
    case ambiguousColumns([String])
    public var message: String { … }    // verbatim alert copy
}

public enum MeetingCSVImporter {
    public static func scan(
        fileURL: URL, existing: ExistingMeetingIdentity
    ) -> ImportScanResult
}
```

`scan` never throws — every failure is a `criticalError` in the result, so the caller has
one code path. Example row numbers are capped at 5 and are 1-based counting the header
as row 1.

Scan algorithm:

1. Read `Data`, strip a UTF-8 BOM, decode as UTF-8 (`notUTF8` on failure).
2. `CSVParser.parse` (`malformedCSV` on throw). Empty → `emptyFile`.
3. Resolve the header: trim + lowercase each cell, map aliases, take the first occurrence
   of each canonical column, drop unknown columns, record `ambiguousColumns` when both a
   canonical name and its alias appear. Missing any of id/title/created →
   `missingColumns`, stop.
4. Per data row: pad or truncate to the header width (counting into `raggedRows`); trim
   id/title; parse `created` via `ISO8601Formatting.date(from:)`. Any of the three
   invalid → count into `misformattedRows`, skip the row.
5. Identity: UUID-parse the id. UUID that is in `existing.meetingIDs`, or a non-UUID
   string in `existing.externalIDs` → count into `alreadyInDatabase`, skip. Already
   claimed by an earlier row in this file → count into `duplicateInFile`, skip.
6. Content: all three of summary/notes/transcript blank → count into `emptyContent`, but
   keep the row.
7. Parse the transcript with `TranscriptTextFormatting.parse`.
8. Emit the draft. After the loop, if `drafts.isEmpty` and there was at least one data
   row, append `.nothingToImport`.

### 4.3 The exporter

```swift
public struct MeetingCSVExporter: Sendable {
    public init(store: DataStore, chunkSize: Int = 50)
    /// Writes the CSV to `directory` and returns the file URL.
    public func export(
        to directory: URL = URL.temporaryDirectory, now: Date = Date()
    ) async throws -> URL
}
```

Streams rather than materializing everything: `meetingIDsForExport()` gives the ordered
IDs, then `exportData(for:)` hydrates 50 at a time, each chunk appended to the temp file
through a `FileHandle`. Memory stays bounded regardless of library size — a few thousand
meetings with long transcripts would otherwise be hundreds of megabytes of `String`.

The file is named `Biscotti_export_{yyyy-MM-dd-HHmmss}.csv` (local time) at creation, so
the temp file already carries the name the save dialog will offer. Failures clean up the
partial file in a `defer`.

## 5. AppCore

`AppCore` owns an exporter and exposes three actions. It is `@MainActor`, so the heavy
work is pushed off it explicitly:

```swift
public func scanMeetingImport(at url: URL) async -> ImportScanResult
public func commitMeetingImport(_ result: ImportScanResult) async throws -> ImportCommitSummary
public func exportMeetingsCSV() async throws -> URL

#if DEBUG
    public func importedMeetingCounts() async -> (imported: Int, remaining: Int)
    public func deleteImportedMeetings() async throws -> Int
#endif
```

```swift
public struct ImportCommitSummary: Sendable, Equatable {
    public let imported: Int
    public let skippedExisting: Int
    public let skippedMisformatted: Int
}
```

- `scanMeetingImport` fetches `existingMeetingIdentity()` from the store actor, then runs
  `MeetingCSVImporter.scan` inside a detached task — parsing a large CSV must not block
  the main actor.
- `commitMeetingImport` calls `nextImportBatchID` then `insertImportedMeetings` on the
  store actor, then `reloadSummaries()` so the sidebar reflects the new meetings, and
  derives the skip counts from the scan's warnings.
- `exportMeetingsCSV` awaits the exporter and returns the temp URL.
- The two debug-only methods are wrapped in `#if DEBUG` so the bulk delete cannot be
  reached from a release build even through the AppCore API, not just through the UI.
  `deleteImportedMeetings` calls `reloadSummaries()` afterwards.

## 6. SettingsUI

New file `SettingsImportExportSection.swift` — an extension on `SettingsView`, matching
the existing one-file-per-section pattern (`SettingsVocabularySection`, `SettingsMCPRow`).
`"Import/Export"` is inserted into `SettingsView.sectionTitles` at index 5, after Custom
Vocabulary and before Calendars.

Each row is a `VStack` of title + subtitle with a trailing button, matching
`vocabularyListRow`. "Learn more" is a borderless `Button` whose label is
`Text("Learn more").foregroundStyle(.sage)`, placed inline after the subtitle — the same
construction as the MCP row's "How to connect", which exists precisely because link and
Form-row styling ignore a `.tint` set at that scope.

### 6.1 View-model state

```swift
public private(set) var importExportBusy: Bool          // disables both buttons
public private(set) var exportInFlight: Bool            // spinner in the Export row
public private(set) var importInFlight: Bool            // spinner in the Import row
var pendingImport: ImportScanResult?                    // held between review and commit
var importAlert: ImportAlertState?                      // drives .alert
```

```swift
enum ImportAlertState: Equatable, Identifiable {
    case blocked(title: String, body: String)           // critical errors; one button
    case review(body: String)                           // warnings; Cancel / Continue
    case result(body: String)                           // post-commit summary
    case failure(body: String)                          // commit or export failure
    #if DEBUG
        // functional spec §6.1
        case confirmDeleteImported(title: String, body: String)
    #endif
}
```

Flow: `beginImport()` presents the open panel → sets `importInFlight` → `scanMeetingImport`
→ if `criticalErrors` non-empty `.blocked`; else if warnings `.review` (Continue calls
`confirmImport()`); else commit straight through. `confirmImport()` commits and sets
`.result`. `beginExport()` sets `exportInFlight`, awaits `exportMeetingsCSV()`, clears the
spinner, presents the save panel, and moves or deletes the temp file.

Import gets a spinner too (the functional spec only mentioned one for export) — scanning
and committing a large file is not instant and the button must not look dead.

### 6.2 Debug row (functional spec §6.1)

`debugSection` gains a third `Button` — **Delete Imported Meetings**, `.sage`-styled with
a `trash` symbol, matching its two neighbours — inside the existing `#if DEBUG`. It calls
`viewModel.promptDeleteImportedMeetings()`, which asks AppCore for the counts and sets
either `.confirmDeleteImported(title: "Delete \(n) meetings?", body: "This will delete
\(n) meetings (and leave \(m) meetings).")` or, when `n == 0`, `.result(body: "No
imported meetings to delete.")`. The confirmation renders Cancel (`role: .cancel`) and
Delete (`role: .destructive`); Delete calls `viewModel.confirmDeleteImportedMeetings()`,
which deletes, reloads, and sets `.result(body: "Deleted \(n) meetings.")`. The whole
addition — view-model state and methods included — sits behind `#if DEBUG`.

### 6.3 Panels

`NSOpenPanel` (`.commaSeparatedText`, single selection, no directories) and `NSSavePanel`
(pre-filled `nameFieldStringValue`) are presented from the view model behind injected
closures, following the `readLaunchAtLoginStatus` seam already in `SettingsViewModel`:

```swift
private let presentOpenPanel: @MainActor () -> URL?
private let presentSavePanel: @MainActor (String) -> URL?
```

Live defaults call AppKit; tests inject stubs, which is what makes the whole flow
testable without a running app.

## 7. Changes to existing formatter call sites

- **`MeetingDetailUI`** — `TranscriptContent.plainText` and `TranscriptContent.displayName`
  are deleted; `copyTranscript()` calls `TranscriptTextFormatting.render`, and
  `TranscriptListView` calls `TranscriptTextFormatting.displayName`. The rest of
  `TranscriptContent` (speaker colors) stays put, since it is SwiftUI-typed.
- **`MCPServer`** — `TranscriptTextFormatter.swift` is deleted and
  `MeetingToolProvider` calls the shared renderer. Output changes only in the timestamp
  (`[00:23]` → `[0:23]`); tool tests asserting the padded form are updated.
- **Manual-test staleness:** touching `Sources/MCPServer` triggers the CLAUDE.md rule.
  The `mcp_*` recordable steps in `ManualTestApp/Results/manual_test_results.json` must be
  marked `not-run` (excluding the `.instruction` step `mcp_connect`), which turns
  `make manual-tests-check` red until a human re-runs them on hardware.

## 8. Error handling

| Failure | Handling |
|---|---|
| File unreadable / not UTF-8 / malformed CSV / missing columns | `ImportCriticalError` in the scan result → blocking alert. Nothing written. |
| Bad row (id/title/created) | Warning, row skipped, rest imports. |
| Commit throws (`DataStoreError`) | `.failure` alert. The batch `save()` is atomic, so the store is unchanged. |
| Export generation throws | `.failure` alert; partial temp file deleted in a `defer`. |
| Save-panel cancelled | Temp file deleted. Not an error. |
| Temp→destination move fails | `.failure` alert naming the reason; temp file left for the next attempt is *not* kept — it is deleted. |

Logging follows the existing pattern: a module `Logger(subsystem: "net.scosman.biscotti",
category: "ImportExport")`, info on scan/commit/export counts, error on failures. **File
contents, titles, notes, summaries, and transcripts are never logged** — only counts and
row numbers.

## 9. Testing

Swift Testing (`@Suite` / `@Test`), matching the repo. All of it runs under
`swift test` — no hardware, no app target, no manual tests beyond the MCP re-run above.

**`FormattingTests`** (new target)
- `TimeFormattingTests` moved over unchanged.
- `ISO8601Formatting`: exact render string for a known date; each accepted input form;
  offset zones; bare date at local midnight; epoch seconds; epoch milliseconds; the 1e11
  boundary on both sides; rejects (`"yesterday"`, `"2026-13-45"`, `"2026-01-03T14:26"`,
  empty); whitespace trimmed.
- `TranscriptTextFormatting.render`: single speaker; alternating speakers; consecutive
  same-speaker collapse; nil `speakerID` never collapses; name resolution from the map;
  falls back to `speakerLabel`; hour-plus timestamps; blank segments dropped; empty input
  → empty string.
- `TranscriptTextFormatting.parse`: plain text with no headers → all `Unknown Speaker` at
  0; our own format; `[0:23] Steve: inline text`; `H:MM:SS` headers; blank lines dropped;
  one segment per line; sequential speaker IDs in first-appearance order; header with no
  name; text before the first header; empty input → no segments.
- Round-trip: render → parse preserves speakers, times, and words.

**`ImportExportTests`** (new target)
- `CSVParser`: embedded commas; embedded newlines in quoted fields; doubled quotes; CRLF,
  LF, and CR separators; BOM; trailing newline; ragged rows; unterminated quote throws;
  empty input.
- `CSVWriter`: quoting only when needed; doubling; round-trip through `CSVParser`.
- `MeetingCSVImporter.scan`, one test per functional-spec case:
  - **alias-only CSV** (`document_id,document_title,document_created,summary`) imports —
    the explicitly requested test case
  - extra unknown columns ignored
  - missing `created` column → `.missingColumns`
  - blank id / blank title / unparseable date → `misformattedRows`, other rows still
    import
  - id already in `meetingIDs` → `alreadyInDatabase`, skipped
  - non-UUID id already in `externalIDs` → `alreadyInDatabase`, skipped
  - non-UUID id, new → draft carries `externalID` and a minted UUID
  - UUID id, new → draft's `meetingID` is that UUID
  - duplicate id inside the file → first wins, `duplicateInFile`
  - row with no summary/notes/transcript → `emptyContent`, still imported
  - transcript with embedded newlines survives parse → segments
  - every row bad → `.nothingToImport`, `canProceed == false`
  - both `id` and `document_id` → `ambiguousColumns`, canonical wins
- `MeetingCSVExporter`: header row is exactly the canonical string; newest-first order;
  fields containing commas/quotes/newlines are escaped; a meeting with no transcript
  writes an empty field; empty store → header only; chunking boundary (chunkSize 2 with
  5 meetings) produces the same output as one chunk; filename shape.

**`DataStoreTests`** (existing target)
- `insertImportedMeetings`: creates meetings with the given UUIDs; sets `externalID`,
  `importBatch`, `editedTitle`, `editedSummary`; creates a transcript record with correct
  segment order/indices and sets `preferredTranscriptID`; empty transcript creates no
  record; returns the inserted count.
- `existingMeetingIdentity` returns both sets.
- `nextImportBatchID` increments on collision.
- `meetingIDsForExport` sorts by `startDate ?? createdAt` descending.
- `importedMeetingCounts` returns the imported/remaining split.
- `deleteImportedMeetings` removes only meetings with a non-null `importBatch`, leaves
  recorded meetings untouched, cascades their transcripts, clears their search-index
  entries, and returns the deleted count.
- `exportData(for:)` resolves speaker names from assignments and returns segments in
  index order.

**`SettingsUITests`** (existing target), with stubbed panels and a fake AppCore
- Cancelling the open panel does nothing.
- Critical errors → `.blocked`, no commit performed.
- Warnings → `.review`; Cancel leaves the store untouched; Continue commits.
- Clean file → commits with no review alert.
- `.result` body reflects imported and skipped counts.
- Export: spinner raised then cleared, save panel receives the generated filename,
  cancelling deletes the temp file.
- Buttons disabled while busy.
- Debug delete: prompt copy for N imported / M remaining; the zero case shows
  "No imported meetings to delete." and performs no delete; Cancel performs no delete;
  Delete calls through and reports the count.

**`MCPServerTests`** (existing target) — update the timestamp expectations.

## 10. Documentation

`App/ImportingExporting.md`, written for users, covering the column list and aliases,
accepted date formats, the transcript format with an example, duplicate handling, the
warning/error meanings, and export naming and sort order. Linked from both Settings rows
via the `main`-branch GitHub URL.
