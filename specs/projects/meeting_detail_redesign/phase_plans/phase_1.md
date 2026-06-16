---
status: complete
---

# Phase 1: Audio playback rate + transport restyle

## Overview

Add playback speed control to the audio seam and restyle `AudioTransport` into a
card with a speed `Menu`. This is a prerequisite for the Phase 4 screen rewrite
and can be built/tested in isolation.

## Steps

1. **Add `rate` to `AudioPlaybackProviding` protocol**
   (`MeetingDetailUI/AudioPlaybackProviding.swift`):
   - Add `var rate: Float { get set }` with a default of 1.0.

2. **Implement `rate` in `AVAudioPlayerWrapper`**
   (`MeetingDetailUI/AudioPlaybackProviding.swift`):
   - Add `private var currentRate: Float = 1.0`.
   - In `load(urls:)`, set `player.enableRate = true` before `prepareToPlay()`,
     then apply `player.rate = currentRate`.
   - Implement the property:
     `get { players.first?.rate ?? currentRate }`
     `set { currentRate = newValue; players.forEach { $0.rate = newValue } }`

3. **Add `playbackRate`, `setPlaybackRate`, `speedOptions` to `MeetingDetailViewModel`**
   (`MeetingDetailUI/MeetingDetailViewModel.swift`):
   - `public private(set) var playbackRate: Float = 1.0`
   - `public func setPlaybackRate(_ r: Float) { playbackRate = r; audioPlayer?.rate = r }`
   - `public static let speedOptions: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]`

4. **Restyle `AudioTransport` into a card + add speed menu**
   (`DesignSystem/AudioTransport.swift`):
   - Add inputs: `rate: Float`, `speedOptions: [Float]`, `onRate: (Float) -> Void`.
   - Restyle the enabled content into a card (rounded rect, cardFill/cardStroke).
   - Play/pause button: circular with hover fill.
   - Elapsed/total times: `.monoCaption`, tabular digits, `.inkSecondary`.
   - Slider: `.tint(.sage)`.
   - Speed menu: soft-secondary styled, showing current rate label (e.g. "1x").
   - Disabled state: existing treatment + speed menu disabled.
   - Update `formatTime` label format: keep `MM:SS` / `H:MM:SS`.

5. **Update `AudioTransport` call site in `MeetingDetailView`** to pass
   `rate`, `speedOptions`, `onRate`.

6. **Update `FakeAudioPlayer` (and `DualFakePlayer`)** in test files to add
   `var rate: Float = 1.0`.

## Tests

- `setPlaybackRate updates VM property and calls through to fake player`:
  verify `viewModel.playbackRate` and `fakePlayer.rate` both update.
- `setPlaybackRate persists rate across play/pause`:
  set rate, play, pause, verify rate is still the set value.
- `speedOptions contains expected values`:
  verify the static array equals `[0.5, 1.0, 1.25, 1.5, 2.0]`.
- `default playbackRate is 1.0`:
  after load, verify `viewModel.playbackRate == 1.0`.
