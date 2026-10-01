---
status: complete
---

# Phase 4: Wiring, UI, and docs

## Overview

Wire the Phase 3 engine into the app: AppCore's three import/export
actions plus the debug pair, the Settings Import/Export section (rows,
panels, spinners, alerts), the debug Delete Imported Meetings row, and
the user-facing `App/ImportingExporting.md`. Includes the deliberate
handling of the header-only-CSV state carried in from the Phase 3 CR
(`canProceed == false, needsReview == false, drafts.isEmpty` → commit
zero meetings, show "Imported 0 meetings.").

## Steps

1. **`Package.swift`** — `AppCore` target deps += `ImportExport`;
   `SettingsUI` target deps += `ImportExport`; `AppCoreTests` and
   `SettingsUITests` deps += `ImportExport`.
2. **`Sources/AppCore/AppCore+ImportExport.swift`** (new) —
   `ImportCommitSummary` and the architecture §5 actions:
   - `scanMeetingImport(at:)` — fetch `existingMeetingIdentity()` on the
     store actor, run `MeetingCSVImporter.scan` in a detached task
     (parsing must not block the main actor). A failed identity fetch
     degrades to no dedupe (commented); the commit still throws on a
     broken store.
   - `commitMeetingImport(_:)` — **header-only guard first**: zero
     drafts returns `imported == 0` without touching the store (the
     carried-in state, handled deliberately); otherwise
     `nextImportBatchID` + `insertImportedMeetings` + `reloadSummaries()`,
     skip counts derived from the scan's warnings.
   - `exportMeetingsCSV()` — `MeetingCSVExporter(store: store).export()`
     (the exporter is stateless; built per call so AppCore's class body
     gains no stored property).
   - `#if DEBUG` `importedMeetingCounts()` / `deleteImportedMeetings()`
     (delete reloads summaries).
3. **`Sources/SettingsUI/SettingsViewModel.swift`** — class body gains
   the §6.1 state (`importExportBusy`, `exportInFlight`,
   `importInFlight`, `pendingImport`, `importAlert`) and the §6.3 panel
   seams; init gains optional `presentOpenPanel` / `presentSavePanel`
   closures (live defaults: `NSOpenPanel` limited to
   `.commaSeparatedText` single selection; `NSSavePanel` pre-filled with
   the generated filename), tests inject stubs — the
   `readLaunchAtLoginStatus` pattern.
4. **`Sources/SettingsUI/SettingsViewModel+ImportExport.swift`** (new) —
   `ImportAlertState` (`blocked(title:body:)`, `review(body:)`,
   `result(title:body:)`, `failure(title:body:)`, DEBUG
   `confirmDeleteImported(title:body:)`; `.result`/`.failure` carry a
   title so import vs debug-delete results and import vs export failures
   can name themselves — the only deviation from the architecture §6.1
   sketch) plus the actions: `beginImport` (open panel → scan →
   blocked / review / commit-straight-through), `confirmImport`,
   `cancelImportReview`, `beginExport` (spinner → generate → save panel
   → move or delete temp), `dismissImportAlert`, and the DEBUG
   `promptDeleteImportedMeetings` / `confirmDeleteImportedMeetings`.
   Alert copy lives in testable statics; review/result bodies per
   functional spec §3.3/§3.4. (The busy/spinner properties are
   `public internal(set)` — not `private(set)` — because the actions
   live in this separate file.)
5. **`Sources/SettingsUI/SettingsImportExportSection.swift`** (new) —
   the two rows (title, subtitle + sage "Learn more" link to
   `App/ImportingExporting.md` on GitHub, trailing button replaced by a
   spinner while in flight, both disabled while `importExportBusy`), the
   section `.alert` (Cancel default / Continue secondary on review, per
   §3.3), and — behind `#if DEBUG` — the Delete Imported Meetings row
   with its own confirmation alert (Cancel / destructive Delete). The
   section alert excludes the delete-confirmation state (binding filter)
   so the two modifiers never double-present.
6. **`Sources/SettingsUI/SettingsView.swift`** — `sectionTitles` gains
   `"Import/Export"` at index 5; body inserts `importExportSection`
   after `customVocabularySection`; the debug section gains the delete
   row.
7. **`Sources/SettingsUI/SettingsCalendarSection.swift`** — Calendars
   header index `[5]` → `[6]`.
8. **`Tests/SettingsUITests/SettingsLayoutTests.swift`** — expected
   section titles += "Import/Export" before "Calendars".
9. **`App/ImportingExporting.md`** (new) — the user-facing guide
   (columns + aliases + ignored extras, accepted date formats,
   transcript format with example, duplicate handling, warning/error
   meanings, export naming/sort).

No manual-test staleness: nothing under `Packages/Transcription`,
`Packages/AudioCapture`, `Packages/LocalLLM`, or `Sources/MCPServer` is
touched.

## Tests

- `AppCoreImportExportTests` (new): scan returns drafts / unreadable
  path → `.unreadableFile`; commit inserts + reloads summaries + stamps
  batch; **header-only CSV commits zero meetings and leaves the store
  untouched** (the carried-in case); skip counts derived from warnings
  (existing + new row); export writes the canonical header to a temp
  file; DEBUG counts split imported/remaining and the bulk delete
  removes only imported meetings.
- `SettingsImportExportTests` (new, stubbed panels): open-panel cancel
  is a no-op; critical errors → `.blocked` and no commit; warnings →
  `.review`, Cancel leaves the store untouched, Continue commits; clean
  file commits with no review alert; header-only file →
  "Imported 0 meetings." result and no store writes; `.result` body
  carries imported + skipped lines; export — busy raised and spinner
  cleared while the save panel is up, panel receives the
  `Biscotti_export_*.csv` name, cancel deletes the temp file, move
  failure → `.failure` + temp deleted; debug delete — exact prompt copy
  for N imported / M remaining, zero case shows "No imported meetings
  to delete." and deletes nothing, Cancel deletes nothing, Delete
  reports the count and leaves recorded meetings.
- `SettingsLayoutTests` — updated section order assertion.

Test-isolation notes: the Settings suite is `.serialized` and the
AppCore export test sleeps past a second boundary (with one retry)
because the export filename has second granularity in the shared temp
directory — a sibling test's cancel-path delete could otherwise remove
another test's just-written temp file.
