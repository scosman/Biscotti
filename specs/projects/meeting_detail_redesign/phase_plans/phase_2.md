---
status: complete
---

# Phase 2: Transcript — selectable block, seek links, copy

## Overview

Replace the per-row `TranscriptSegmentRow` transcript with a single selectable
`Text(AttributedString)` block. Add clickable timestamps that seek playback via
a custom URL scheme, per-speaker coloring from the avatar palette, and a
`copyTranscript()` action that writes a plain-text rendering to the pasteboard.

This phase builds the data builders and view, adds the VM method, and wires the
seek-link interception. Phase 4 will integrate the view into the new layout.

## Steps

1. **Add `TranscriptContent` enum** to
   `MeetingDetailUI/TranscriptContent.swift` (new file):
   - `static func attributedString(_ segments: [SegmentData], canSeek: Bool) -> AttributedString`
     Builds one `AttributedString` with per-turn speaker label (semibold,
     palette color), timestamp (mono, `.inkTertiary`, optional seek link), and
     utterance text (system 14, `.inkSecondary`), separated by paragraph spacing.
   - `static func plainText(_ segments: [SegmentData]) -> String`
     Builds `"<speaker>  MM:SS\n<text>"` per turn, joined by `"\n\n"`
     (no trailing newline -- cleaner for clipboard paste).
   - `static func speakerColor(for label: String) -> Color`
     Returns `Tokens.avatarPalette[avatarColorIndex(forKey: label, paletteCount:)]`.

2. **Add `SeekLink` enum** to `MeetingDetailUI/SeekLink.swift` (new file):
   - `static func url(seconds: TimeInterval) -> URL`
     Returns `biscotti://seek?t=<seconds>`.
   - `static func seconds(from url: URL) -> TimeInterval?`
     Parses scheme `biscotti`, host `seek`, query `t` -> `Double`.

3. **Add `SelectableTranscriptView`** to
   `MeetingDetailUI/SelectableTranscriptView.swift` (new file):
   - Takes `attributed: AttributedString`, `onSeek: (TimeInterval) -> Void`.
   - Renders `Text(attributed).textSelection(.enabled).tint(.inkTertiary)`
     with an `OpenURLAction` that calls `SeekLink.seconds(from:)` and passes
     non-seek URLs through. Lives in MeetingDetailUI (not DesignSystem) to
     avoid duplicating the seek-URL parser.

4. **Add `copyTranscript()` to `MeetingDetailViewModel`**:
   - Builds `TranscriptContent.plainText(...)` from `displayedTranscript` and
     writes to `NSPasteboard.general`.

5. **Wire the transcript view into `MeetingDetailView`** (temporary — Phase 4
   will rewrite the layout, but this lets us verify the view works):
   - Replace the `LazyVStack/ForEach/TranscriptSegmentRow` with the new
     `SelectableTranscriptView`, passing `canSeek: viewModel.canPlay` and
     `onSeek: viewModel.seek(to:)`.

## Tests

New file: `MeetingDetailUITests/TranscriptContentTests.swift`

- `plainText formats multi-turn transcript`: verify exact
  `"Speaker 0  0:14\nHello\n\nSpeaker 1  0:31\nHi"` output (no trailing newline).
- `plainText formats H:MM:SS for times >= 1 hour`: verify `1:02:03` format.
- `attributedString includes seek links when canSeek is true`: verify `.link`
  attribute is present on timestamp runs with correct `biscotti://seek?t=`
  URL.
- `attributedString omits links when canSeek is false`: verify no `.link`
  attribute on timestamp runs.
- `speakerColor returns same color for same label`: stability check.
- `speakerColor returns different colors for different labels`: verify
  distinct speakers get distinct palette entries (modulo palette collisions).

New file: `MeetingDetailUITests/SeekLinkTests.swift`

- `seconds parses valid seek URL`: `biscotti://seek?t=14.0` -> `14.0`.
- `seconds returns nil for wrong scheme`: `https://seek?t=14` -> `nil`.
- `seconds returns nil for wrong host`: `biscotti://play?t=14` -> `nil`.
- `seconds returns nil for missing t`: `biscotti://seek` -> `nil`.
- `seconds returns nil for non-numeric t`: `biscotti://seek?t=abc` -> `nil`.
- `url round-trips through seconds`: build URL, parse back, get same value.

In existing `MeetingDetailPhase8Tests.swift` (or new file):

- `copyTranscript writes plain text to pasteboard`: verify pasteboard content
  after calling `viewModel.copyTranscript()` with a loaded transcript.
