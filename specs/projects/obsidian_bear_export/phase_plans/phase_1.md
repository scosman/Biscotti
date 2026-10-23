---
status: complete
---

# Phase 1: Data model + pure logic

## Overview

Build the persistence layer (`ExportDestination`, `SentExport`, `Meeting.sentExports`, store API, `MeetingDetailData.sentExports`) and all pure-logic types in `ImportExport/SendTo/` (source, markdown, tags, filenames, encoding, hash, payload, plan, decision). No AppKit, no UI.

## Steps

1. **`DataStore/Models/SentExport.swift`** -- new file with `ExportDestination` (enum, `String` raw, `Codable`, `Sendable`, `CaseIterable`) and `SentExport` (struct, `Codable`, `Sendable`, `Equatable`; fields: `destination`, `contentHash`, `sentAt`).

2. **`DataStore/Models/Meeting.swift`** -- add `sentExportsData: Data` (private, default `Data()`) and a `@Transient var sentExports: [SentExport]` computed accessor using the `vocabularyUsed` JSON-encode/decode pattern.

3. **`DataStore/DataStore+SentExports.swift`** -- new file with `sentExports(meetingID:)` and `recordSentExport(_:meetingID:)`. The record function replaces any existing record for the same destination.

4. **`DataStore/DataStore+ReadModels.swift`** -- add `sentExports: [SentExport]` to `MeetingDetailData` (init default `[]`); populate it in `meetingDetail(id:)`.

5. **`ImportExport/SendTo/ExportDestination+Info.swift`** -- `DestinationDetection` enum and `ExportDestination` extension with `displayName` and `detection`.

6. **`ImportExport/SendTo/ExportSource.swift`** -- `ExportSource` struct with `init(detail:)` and `hasContent`.

7. **`ImportExport/SendTo/SendMarkdown.swift`** -- `body(_:timeZone:)`, `obsidianFrontmatter(_:tags:timeZone:)`, `notesTagFooter(_:)`.

8. **`ImportExport/SendTo/SendTags.swift`** -- `tags(_:for:)` with per-destination sanitization.

9. **`ImportExport/SendTo/SendFilename.swift`** -- `sanitize(_:)` and `obsidianName(_:timeZone:)`.

10. **`ImportExport/SendTo/StrictPercentEncoder.swift`** -- `encode(_:)` and `query(_:)`.

11. **`ImportExport/SendTo/SendPayload.swift`** -- `SendPayload` struct with `build(_:for:timeZone:)` using CryptoKit SHA-256.

12. **`ImportExport/SendTo/SendPlan.swift`** -- `SendPlan` enum with `make(_:source:timeZone:)`.

13. **`ImportExport/SendTo/SendDecision.swift`** -- `SendDecision` enum with `decide(_:for:currentHash:)`.

14. **`Package.swift`** -- add `AppLinks` to ImportExport's dependency list (needed for `AppLink.meeting` URL in `SendMarkdown.body`).

## Tests

**`DataStoreTests/SentExportTests.swift`:**
- `roundTrip`: write and read back `sentExports` via the transient property
- `replaceForSameDestination`: `recordSentExport` replaces the existing record for the same destination, leaves others
- `missingMeetingNoOp`: `recordSentExport` on a missing meeting ID is a silent no-op
- `corruptDataReturnsEmpty`: garbage `sentExportsData` decodes as `[]`
- `newMeetingReturnsEmpty`: a fresh meeting has `sentExports == []`
- `meetingDetailExposesSentExports`: `meetingDetail(id:)` includes the records

**`ImportExportTests/SendTo/EncoderTests.swift`:**
- space, `/`, `+`, `&`, `#`, `?`, `=`, `,`, newline, emoji, CJK and accented characters encode correctly
- unreserved characters (`A-Z a-z 0-9 - . _ ~`) pass through
- `query` joins pairs correctly

**`ImportExportTests/SendTo/MarkdownTests.swift`:**
- golden body with fixed UUID, date, `America/New_York`
- each omission (summary, notes, attendees, duration)
- duration formats (42 min, 1 h 05 min)
- CRLF normalisation
- title fallback to `Untitled Meeting`
- double render is identical
- golden frontmatter with quote, backslash and emoji escaping
- Notes footer

**`ImportExportTests/SendTo/TagTests.swift`:**
- parameterised per destination: spaces, commas, `#`, `/`, digits-only, mixed-case duplicates, `biscotti` duplicate, empty after cleanup, sort order

**`ImportExportTests/SendTo/FilenameTests.swift`:**
- each disallowed character
- leading dot
- whitespace collapse
- 120-character cut at an emoji ZWJ boundary
- empty title
- Obsidian `<title> <date>` format

**`ImportExportTests/SendTo/PayloadTests.swift`:**
- hash is 64 lowercase hex
- hash is stable across calls
- hash changes when title, summary, notes or tags change
- hash differs between destinations

**`ImportExportTests/SendTo/PlanTests.swift`:**
- golden URLs for Obsidian and Bear (no `+`, no raw `/` `?` `&` in values)
- size limit at 511,999 / 512,000 / 512,001 URL bytes
- Notes produces `.handOffFile` with `.md` name

**`ImportExportTests/SendTo/DecisionTests.swift`:**
- no record -> `.send`
- same hash -> `.alreadySent(changed: false)`
- different hash -> `.alreadySent(changed: true)`
- another destination's record is ignored
