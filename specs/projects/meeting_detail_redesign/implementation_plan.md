---
status: complete
---

# Implementation Plan: Update Meeting Screen

Ordered so each phase lands a coherent, reviewable unit. Phases 1–3 build the
new/changed pieces (with unit tests); Phase 4 rewrites the screen to assemble
them. See `architecture.md` for signatures and `ui_design.md` for the visual
contract.

## Phases

- [x] **Phase 1 — Audio: playback rate + transport restyle.**
  Add `rate` to `AudioPlaybackProviding` + `AVAudioPlayerWrapper` (enableRate,
  apply to both tracks) and the test fake; add `playbackRate` / `setPlaybackRate`
  / `speedOptions` to the view model; restyle `AudioTransport` into a card and
  add the soft-secondary speed `Menu`. Unit-test `setPlaybackRate`.

- [x] **Phase 2 — Transcript: selectable block, seek links, copy.**
  `TranscriptContent` (attributed + plain-text builders, speaker color),
  `SeekLink.seconds` parser, `SelectableTranscriptView` (`.textSelection` +
  `OpenURLAction` → `seek`, `.tint(.inkTertiary)`), and `vm.copyTranscript()`.
  Unit-test the builders + parser + color stability. Verify drag-select and
  tap-to-seek coexist on macOS 15.

- [ ] **Phase 3 — Calendar card + data.**
  Add `eventNotes` to `CalendarContextData` and populate it from
  `CalendarSnapshot` in the DataStore read query. Build `CalendarInfoCard`
  (avatar cluster, summary, "Open in Calendar", `DisclosureGroup` definition list
  WHEN/WHERE/DESCRIPTION/INVITED) + `SourcePill`. Add the VM's `calendarCard`
  mapping + `whenText` / `invitedText` helpers (unit-tested).

- [ ] **Phase 4 — Screen rewrite (assembly).**
  Rewrite `MeetingDetailView`: pinned-chrome + scrolling-tab-content layout, 760
  reading cap; serif inline-editable title; the "…" overflow menu (incl. new
  `revealInFinder()` + `hasAudioFiles`, link/change/unlink, re-transcribe, and
  destructive delete — removing the standalone delete section); meta line with
  `SourcePill`; segmented Transcript|Notes tab bar with version picker + Copy
  Transcript on the Transcript tab; Notes tab editor at fill height; integrate
  the Phase 2 transcript view and Phase 3 calendar card. Wire the speed menu to
  the VM.
