---
status: complete
---

# Phase 4: Play links start playback

## Overview

Transcript timestamp links (`biscotti://seek?t=...`) and notes deep-links (`biscotti://meeting/{id}?time=...`) currently only seek the audio player without changing play/pause state. This phase adds a `seekAndPlay(to:)` method that seeks AND starts playback if currently paused. Already-playing stays playing. The transport bar scrubber continues to use pure `seek(to:)`.

## Steps

1. **Add `seekAndPlay(to:)` to `MeetingDetailViewModel`** (`MeetingDetailUI/MeetingDetailViewModel.swift`):
   - New public method `func seekAndPlay(to time: TimeInterval)` in the audio playback section.
   - Calls `seek(to: time)` then, if the player exists and is not playing, starts playback and the ticker (reuse the play branch logic from `playPause()`).

2. **Wire transcript `onSeek` to `seekAndPlay`** (`MeetingDetailUI/MeetingDetailView.swift`, ~line 573):
   - Change `SelectableTranscriptView`'s `onSeek` closure from `viewModel.seek(to: $0)` to `viewModel.seekAndPlay(to: $0)`.
   - The `AudioTransport` `onSeek` (scrubber, ~line 245) stays as `viewModel.seek(to: $0)` -- scrubbing should not auto-play.

3. **Wire deep-link `applySeekIfReady` to `seekAndPlay`** (`MeetingDetailUI/MeetingDetailViewModel.swift`, ~line 578):
   - In `applySeekIfReady()`, change `seek(to: clamped)` to `seekAndPlay(to: clamped)` so deep-links also auto-play.

## Tests

- **`seekAndPlay starts playback when paused`**: Create VM with audio, verify paused, call `seekAndPlay(to: 30)`, verify `isPlaying == true` and `currentTime == 30`.
- **`seekAndPlay keeps playing when already playing`**: Start playback, call `seekAndPlay(to: 45)`, verify still playing and time updated, verify `play()` was not called a second time (no restart).
- **`seekAndPlay is no-op when no player`**: VM with no audio files, call `seekAndPlay(to: 10)`, no crash, stays not-playing.
- **`seek does not start playback`**: Pure `seek(to:)` while paused stays paused (regression guard).
- **`deep-link pending seek auto-plays via applySeekIfReady`**: Set `pendingSeek` via the deep-link mechanism, verify playback starts after the seek is applied.
