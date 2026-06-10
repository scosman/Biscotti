---
status: complete
---

# Phase 8: Rich Meeting Detail (completes Project 7)

## Overview

Extends `MeetingDetailViewModel` with four features: audio playback (behind a testable
`AudioPlaybackProviding` seam), transcript-version switching, notes autosave with debounce, and
polishing the association-correction flow to wire re-transcribe after correction. Phase 3 already
built the association correction/removal/event-picker/re-transcribe prompt; Phase 8 completes it by
actually triggering re-transcription when the user accepts the prompt.

All logic stays in the view model; views remain thin. New DesignSystem components: `AudioTransport`,
`VersionPicker`. Reuses Phase 1 DTOs (`TranscriptVersionData`, `AudioFileRefsResult`, `setNotes`,
`transcript(id:)`, `audioFileRefs`, `transcriptVersions`), Phase 3 VM (association correction,
event picker), and `TranscriptionService.reTranscribe`.

## Steps

### 1. AudioPlaybackProviding protocol + AVAudioPlayerWrapper

Create `MeetingDetailUI/AudioPlaybackProviding.swift`:

```swift
public protocol AudioPlaybackProviding: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    func play()
    func pause()
    func load(url: URL) throws
}
```

Create `MeetingDetailUI/AVAudioPlayerWrapper.swift` -- production implementation wrapping
`AVAudioPlayer`. The wrapper imports `AVFoundation`.

### 2. Extend MeetingDetailViewModel with new state and actions

Add to `MeetingDetailViewModel.swift`:

**New state properties:**
- `notes: String = ""` -- bound to the text editor; autosaved
- `versions: [TranscriptVersionData] = []` -- all versions
- `selectedVersionID: UUID?` -- which version is displayed; nil = preferred
- `selectedTranscript: TranscriptData?` -- loaded transcript for selected version
- `audioPlayer: (any AudioPlaybackProviding)?` -- nil if no audio
- `isAudioAvailable: Bool = false` -- from audioFileRefs.present
- `notesAutosaveTask: Task<Void, Never>?` -- debounce handle

**New computed:**
- `isPlaying: Bool` -- audioPlayer?.isPlaying ?? false
- `playbackCurrentTime: TimeInterval` -- audioPlayer?.currentTime ?? 0
- `playbackDuration: TimeInterval` -- audioPlayer?.duration ?? 0
- `canPlay: Bool` -- isAudioAvailable && audioPlayer != nil
- `activeVersionID: UUID?` -- selectedVersionID ?? preferred version's ID
- `displayedTranscript: TranscriptData?` -- selectedTranscript ?? detail?.preferredTranscript

**New actions:**
- `selectVersion(_ versionID: UUID) async` -- sets selectedVersionID, loads via store.transcript(id:)
- `updateNotes(_ text: String)` -- debounce 1s, then store.setNotes
- `playPause()` -- toggles audio player
- `seek(to time: TimeInterval)` -- sets audioPlayer.currentTime
- `reTranscribeAfterCorrection() async` -- dismiss prompt + reTranscribe

**Extended `load()`:**
After loading detail, also load:
- `notes = detail.notes`
- `versions = detail.versions`
- Audio file refs: if present, create player via an injectable factory (default
  `AVAudioPlayerWrapper`), load mic URL

**Injectable player factory:**
The init gains an optional `makePlayer` closure (defaults to creating `AVAudioPlayerWrapper()`).
Tests inject a fake.

### 3. DesignSystem: AudioTransport component

Create `DesignSystem/AudioTransport.swift`:
- Props: `isPlaying`, `currentTime`, `duration`, `isDisabled`, `onPlayPause`, `onSeek`
- Play/pause button + Slider scrubber + elapsed/total time labels
- Disabled state: grayed out with "Audio not available" text
- Ship a `#Preview`

### 4. DesignSystem: VersionPicker component

Create `DesignSystem/VersionPicker.swift`:
- Props: `versions: [TranscriptVersionData]`, `selectedID: UUID`, `onSelect: (UUID) -> Void`
- macOS `Menu` button dropdown listing versions by date + method + preferred badge
- Ship a `#Preview`

### 5. Update MeetingDetailView

- Add `VersionPicker` in the header (when `versions.count > 1`)
- Add `AudioTransport` between calendar section and notes
- Add `TextEditor` for notes with `onChange` -> `viewModel.updateNotes`
- Update transcript section to use `displayedTranscript` instead of `detail.preferredTranscript`
- Wire the re-transcribe prompt's "Re-transcribe" button to `reTranscribeAfterCorrection()`

### 6. Unit tests

Write thorough tests in `MeetingDetailUITests/`:

**Audio playback tests:**
- `playbackDisabledWhenAudioMissing` -- canPlay == false when no audio files
- `playPauseToggles` -- play/pause toggles fake player state
- `seekUpdatesCurrentTime` -- seek(to:) updates fake player currentTime
- `playbackEnabledWhenAudioPresent` -- canPlay == true after load with audio + fake player

**Version picker tests:**
- `detailLoadsVersions` -- versions populated after load when transcripts exist
- `versionPickerLoadsSelectedVersion` -- selectVersion sets selectedVersionID and loads transcript
- `displayedTranscriptReflectsSelection` -- displayedTranscript returns selected version's data

**Notes autosave tests:**
- `notesAutosaveDebounces` -- updateNotes debounces before calling store.setNotes
- `notesLoadedFromDetail` -- notes populated from detail.notes after load

**Association correction tests (completing Phase 3 flow):**
- `associationCorrectionOffersReTranscribe` -- after correctAssociation, showReTranscribeAfterCorrection is true
- `reTranscribeAfterCorrectionTriggersJob` -- calling reTranscribeAfterCorrection triggers transcription.reTranscribe
- `removeAssociationClearsContext` -- already exists; ensure it still passes

## Tests

| Test name | Verifies |
|---|---|
| `playbackDisabledWhenAudioMissing` | `canPlay == false` when audioFileRefs.present == false |
| `playbackEnabledWhenAudioPresent` | `canPlay == true` after load with audio files and fake player |
| `playPauseToggles` | `playPause()` toggles the fake player between play/pause |
| `seekUpdatesCurrentTime` | `seek(to: 30.0)` sets player.currentTime to 30.0 |
| `detailLoadsVersions` | `versions` contains all TranscriptVersionData after load |
| `versionPickerLoadsSelectedVersion` | `selectVersion(id)` sets selectedVersionID and loads transcript |
| `displayedTranscriptReflectsSelection` | `displayedTranscript` returns selected version, not preferred |
| `notesAutosaveDebounces` | `updateNotes("text")` debounces ~1s before calling store.setNotes |
| `notesLoadedFromDetail` | `notes` populated from detail.notes after load |
| `associationCorrectionOffersReTranscribe` | After correctAssociation(eventKey:), showReTranscribeAfterCorrection is true |
| `reTranscribeAfterCorrectionTriggersJob` | reTranscribeAfterCorrection dismisses prompt + calls reTranscribe |
| `removeAssociationClearsContext` | removeAssociation sets calendarContext to nil (existing test) |
