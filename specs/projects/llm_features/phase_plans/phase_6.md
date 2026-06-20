---
status: complete
---

# Phase 6: Meeting detail -- Speaker names + mapping sheet

## Overview

Extend `TranscriptContent` to render assigned speaker names in transcript segments, make speaker spans clickable to open a mapping sheet, and build the `SpeakerMappingSheet` for manual speaker-to-person assignment. This is independent of the LLM -- pure manual assignment works with no model present.

## Steps

1. **Add `SpeakerLink` helper** (new file `MeetingDetailUI/SpeakerLink.swift`):
   - `SpeakerLink.url(speakerID: Int) -> URL` builds `biscotti://speaker?id=<speakerID>`
   - `SpeakerLink.speakerID(from: URL) -> Int?` parses it back
   - Mirrors the existing `SeekLink` pattern exactly.

2. **Extend `TranscriptContent.attributedString` with `names` parameter**:
   - Add `names: [Int: String] = [:]` parameter.
   - Speaker span text: `names[seg.speakerID] ?? seg.speakerLabel`.
   - Speaker color: key on `speakerID` when available (format "speaker-\(id)"), fall back to `speakerLabel` hash. New helper `speakerColor(for segment: SegmentData) -> Color`.
   - Make speaker span a `.link` via `SpeakerLink.url(speakerID:)` when `speakerID != nil`.
   - Similarly update `plainText` to accept names.

3. **Update `CachedTranscriptKey` to include speaker names**:
   - Add `names: [Int: String]` to the key struct so the cache rebuilds when assignments change.
   - Update `rebuildTranscriptCacheIfNeeded()` to pass names from `displayedTranscript.speakerAssignments`.

4. **Wire `SpeakerLink` into `SelectableTranscriptView`**:
   - Add `onSpeaker: (Int) -> Void` callback.
   - In the `OpenURLAction`, check `SpeakerLink.speakerID(from:)` first; if matched, call `onSpeaker(id)` and return `.handled`.
   - Update `Equatable` to also include a `speakerNames: [Int: String]` key (since names affect rendering, and the speaker-link callback changes).

5. **Add VM state + actions for speaker sheet**:
   - `speakerSheetTranscriptID: UUID?` (sheet binding item).
   - `func openSpeakerSheet(speakerID: Int)` sets sheet state.
   - `SpeakerRow` and `SpeakerSheetData` DTOs.
   - `func buildSpeakerSheetData() async -> SpeakerSheetData?` assembles rows from `displayedTranscript`, invitees from `calendarContext`, people from `store.allPersonData()`.
   - `func assignSpeaker(speakerID: Int, personID: UUID)` calls `store.setSpeakerAssignment` then reloads.
   - `func assignNewPerson(speakerID: Int, name: String)` calls `findOrCreatePerson` then assigns.
   - `func unassignSpeaker(speakerID: Int)` clears assignment.

6. **Build `SpeakerMappingSheet` view**:
   - Presented via `.sheet(item:)` on `MeetingDetailView`.
   - Shows one row per distinct speakerID with a color dot + "Speaker N" label.
   - Each row has a `Menu` picker with sections: Invitees, People, Add person (inline TextField), Unassigned.
   - Apply-on-change; Done button dismisses.

7. **Wire the sheet in `MeetingDetailView`**:
   - Add `.sheet(item: $viewModel.speakerSheetTranscriptID)`.
   - Pass `onSpeaker` callback from `SelectableTranscriptView` to `viewModel.openSpeakerSheet(speakerID:)`.

## Tests

- `SpeakerLink.url` + `speakerID(from:)` round-trip; non-speaker URLs return nil.
- `TranscriptContent.attributedString` with names: shows "Daniel" instead of "Speaker 0"; unmapped speakers keep "Speaker N".
- `TranscriptContent.attributedString` with names: speaker links present for segments with speakerID.
- Color stability: same speakerID yields same color regardless of name change.
- `plainText` with names substitutes correctly.
- VM `buildSpeakerSheetData`: assembles invitees, deduped people, and speaker rows.
- VM `assignSpeaker` / `unassignSpeaker`: persists and reloads.
- VM `assignNewPerson`: creates person and assigns.
- Cache key includes names: changing names invalidates the cache.
