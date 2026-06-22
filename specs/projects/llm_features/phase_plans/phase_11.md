---
status: complete
---

# Phase 11: Shared Color for Merged Speakers

## Overview

When multiple speaker IDs are assigned to the same person, they should share that person's color in both the transcript rendering and the speaker mapping sheet. This phase re-keys the speaker color on `Person.id` when assigned (so merged speakers read as one person visually) and falls back to the existing `"speaker-<id>"` key for unassigned speakers.

## Steps

1. **Add a `colorKeys` parameter to `TranscriptContent.speakerColor(for:colorKeys:)` and `attributedString(_:canSeek:names:colorKeys:)`.**
   - New parameter: `colorKeys: [Int: String]` — maps diarization speaker ID to a color-key string. When present, the color is derived from this key instead of the default `"speaker-<id>"`.
   - The caller (VM) precomputes this map: for assigned speakers, key is `"person-<Person.id>"` (so all speakers mapped to the same person share one color); for unassigned, key is absent (fallback to `"speaker-<id>"`).

2. **Add `displayedSpeakerColorKeys` computed property to `MeetingDetailViewModel`.**
   - Derives `[Int: String]` from `displayedTranscript?.speakerAssignments`: for each `(speakerID, personData)`, emit `speakerID -> "person-\(personData.id.uuidString)"`.
   - Used by `rebuildTranscriptCacheIfNeeded`, `SelectableTranscriptView` equality, and passed to `TranscriptContent`.

3. **Include color keys in `CachedTranscriptKey`.**
   - Add `colorKeys: [Int: String]` field to invalidate the cache when assignments change person IDs.

4. **Update `SpeakerMappingSheet.speakerColor(for:)` to accept and use the color-key map.**
   - Pass the map from `SpeakerSheetData` (add `colorKeys: [Int: String]` to the DTO) so sheet dots use the same merged-color rule.
   - Populate `SpeakerSheetData.colorKeys` in `buildSpeakerSheetData`.

5. **Update `SelectableTranscriptView` equality to include color keys.**

## Tests

- `mergedSpeakersShareColor`: Two speaker IDs assigned to the same person produce the same color from `TranscriptContent.speakerColor`.
- `unassignedSpeakersKeepStableColor`: Unassigned speakers with no color-key entry get their stable `"speaker-<id>"` color.
- `cacheKeyIncludesColorKeys`: Cache invalidates when `displayedSpeakerColorKeys` changes.
