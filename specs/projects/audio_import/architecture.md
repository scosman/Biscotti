---
status: draft
---

# Architecture: Audio Import

Changes are additive and bottom-up through the existing layers.

## DataStore
- `AudioRole`: add `case imported` (stored as raw string; no migration needed).
- `audioPaths(meetingID:)` returns a new `MeetingAudio` value: `.pair(mic:system:)` or
  `.single(URL)`. Gate on `isPresent` as today. Update `TranscriptionService` accordingly.
- `createImportedMeeting(startDate:duration:)`-style helper (or reuse `createMeeting` +
  `attachAudio` + `markAudioPresence`, as `RecordingController` does).

## Transcription package
- `XPCProcessRequest.systemPath` becomes `String?`. Compatibility is one-directional: a new
  decoder accepts payloads that omit the key (and legacy payloads that include it). An *old*
  worker could reject a request whose `systemPath` is nil. This is safe in practice because the
  app and `BiscottiTranscriber.xpc` ship in the same bundle and always match; no version
  negotiation is needed. Tests cover decoding both payload shapes.
- `TranscriptionEngine.processAudio(micPath:systemPath:…)`, `Transcriber.processAudio(mic:system:…)`,
  `XPCEngineAdapter`, and `BiscottiTranscriber.xpc` `main.swift` accept an optional system path.
  For a single file the caller passes it as `micPath` with `systemPath == nil`.
- `AudioLoading.loadAndMerge` loads the system file only when present; `AudioMerger`
  already supports a single non-empty stream (`LabeledRange.label == .mic`).
- `SpeakerAnalyzer` (voiceprint backfill) gets the same optionality.

## TranscriptionService
- `Transcribing.processAudio(mic:system:customVocabulary:)` → `system: URL?`. `FakeTranscriber`
  and tests updated.

## AppCore
- New `AppCore+ImportAudio.swift`:
  `func importAudio(urls: [URL]) async -> [UUID]` — validates (AVFoundation), copies,
  creates meetings, then enqueues one `pendingTranscriptionTask` chain per file
  (sequential). Validation/copy run off the main actor. For each URL it calls
  `startAccessingSecurityScopedResource()` first and `stopAccessingSecurityScopedResource()` in a
  `defer`, so access is released on validation, copy, and failure paths alike.
- Pure helper `AudioImportValidator` (UTType + AVFoundation probe) behind a protocol seam
  so tests don't need real audio decoding for most cases.

## UI
- `DesignSystem`: new `ImportedAudioPill` (modelled on `SourcePill`) in the Meeting Detail meta line; the list row appends "· Imported" to its second line.
- Read models: `MeetingSummary.isImported` / `MeetingDetailData.isImported`, derived from the audio role.
- `AppShellUI`: toolbar `Import Audio` button, `.fileImporter`, `.dropDestination` on the window (passes every dropped file to `importAudio`, which reports rejects),
  `File > Import Audio…` command in `BiscottiApp`.
- `MeetingDetailUI`: playback loads `[mic, system].compactMap`. The read models map the single
  `.imported` file into the `mic` slot so this works unchanged; confirming it plays on real
  hardware is part of Phase 4.
- Alerts reuse the existing alert pattern from Settings import.

## Testing
- Unit: validator, `audioPaths` single/pair, XPC request back-compat decode,
  `AudioLoading` single-file path, `importAudio` happy path/failure cleanup
  (fake transcriber), role handling in DataStore.
- Manual-test script entry in `ManualTestApp` for a real mp3/m4a end to end.
