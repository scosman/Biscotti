---
status: done
---

# Phase 1: Single-track audio and placeholder titles

## Overview

Makes mic and system audio paths optional through the entire Transcription pipeline, so single-track imported meetings can be transcribed. Adds placeholder-title support so imported meetings get replaceable titles instead of "Untitled Meeting". These are behavior-neutral foundations for the import feature.

## Steps

### Transcription package (optional paths)

1. **`AudioLoading.swift`** -- change `loadAndMerge(micPath:systemPath:)` to accept `String?` for both. If both nil, throw `.invalidInput`. Load each non-nil path, pass `[]` for absent stream to `AudioMerger.merge`.

2. **`TranscriptionEngine.swift`** -- change `processAudio(micPath:systemPath:customVocabulary:)` to `micPath: String?, systemPath: String?`. Update doc: "At least one path is required."

3. **`InProcessTranscriptionEngine.swift`** -- thread optionals through `processAudio` and `loadAndMergeAudio`.

4. **`XPCProcessRequest.swift`** -- change `micPath` and `systemPath` to `String?`. Synthesized `Codable` handles nil/missing keys.

5. **`XPCEngineAdapter.swift`** -- thread optionals through the `processAudio` call and `XPCProcessRequest` init.

6. **`XPCServices/BiscottiTranscriber/main.swift`** -- pass `request.micPath` and `request.systemPath` (now optional) through.

7. **`Transcriber.swift`** -- change `processAudio(mic:system:customVocabulary:)` and `reTranscribe` to `mic: URL?, system: URL?`. Validate at least one non-nil. Convert to path strings.

8. **`SpeakerAnalyzer.swift`** -- change `analyze(micPath:systemPath:)` to `micPath: String?, systemPath: String?`.

9. **`transcribe-cli/TranscribeCLI.swift`** -- make `--mic` and `--system` `String?`. Validate at least one. Update help text and `validateAudioPaths`.

### DataStore changes

10. **`Meeting.swift`** -- add `public var titleIsPlaceholder: Bool = false` (additive, no migration).

11. **`Meeting.swift`** -- add `public static func isAIReplaceableTitle(title:editedTitle:titleIsPlaceholder:) -> Bool`.

12. **`DataStore+LLMFeatures.swift`** -- `applyGeneratedTitle`: gate on `Meeting.isAIReplaceableTitle(...)`. When applying, set `titleIsPlaceholder = false`.

13. **`DataStore+ReadModels.swift`** -- `setTitle`: also set `titleIsPlaceholder = false`. `applyEventTitle`: also set `titleIsPlaceholder = false`.

14. **`DataStore+ReadModels.swift`** -- `audioPaths(meetingID:)`: return `(mic: URL?, system: URL?)?`. Change the guard to require at least one present ref.

15. **`DataStore+ReadModels.swift` / `MeetingDetailData`** -- add `public let titleIsPlaceholder: Bool` to `MeetingDetailData`, default `false`. Populate in `meetingDetail(id:)`.

### TranscriptionService + Transcribing protocol

16. **`Transcribing.swift`** -- change `processAudio(mic:system:customVocabulary:)` to `mic: URL?, system: URL?`.

17. **`TranscriptionService.swift`** -- `resolveAudioPaths` returns `(mic: URL?, system: URL?)?`, fires "No audio files" only when store returns nil.

18. **`AppCore+Live.swift`** -- `LiveTranscriberAdapter.processAudio` threads optional URLs.

### Intelligence gates

19. **`Intelligence.swift`** (~line 217) -- replace `detail.title == Meeting.defaultTitle && !detail.editedTitle` with `Meeting.isAIReplaceableTitle(title: detail.title, editedTitle: detail.editedTitle, titleIsPlaceholder: detail.titleIsPlaceholder)`.

20. **`MeetingAnalyzer.swift`** (~line 319) -- same replacement.

### FakeTranscriber + test support

21. **`FakeTranscriber.swift`** -- record `lastMicURL: URL?` and `lastSystemURL: URL?` (already optional).

### voiceprint-cli backfill

22. **`BackfillCommand.swift`** -- `skipReason`: change guard from "both required" to "at least one". `processOne`: handle single-track (pass nil for absent path).

### Manual test staleness

23. **`manual_test_results.json`** -- set all `tx_*` steps to `"status": "not-run"`.

## Tests

### Transcription package (`TranscriptionTests`)
- `AudioLoadingTests.loadAndMerge_systemOnly`: real AAC file, micPath nil, check sample count.
- `AudioLoadingTests.loadAndMerge_micOnly`: mirror case.
- `AudioLoadingTests.loadAndMerge_bothNil_throwsInvalidInput`.
- `XPCProcessRequestTests.roundTrip_nilMic`: encode with nil mic, decode, verify nil.
- `XPCProcessRequestTests.decode_missingMicKey_isNil`: raw JSON without `micPath` key.
- Existing two-track tests pass unchanged.
- `CLITests` updated for optional args.

### DataStore tests
- `titleIsPlaceholder_defaultsFalse`.
- `isAIReplaceableTitle_truthTable`: default title -> true, placeholder -> true, edited -> false, custom non-placeholder -> false.
- `applyGeneratedTitle_replacesPlaceholder_andClearsFlag`.
- `applyGeneratedTitle_keepsCustomNonPlaceholderTitle`.
- `setTitle_clearsPlaceholder`.
- `applyEventTitle_replacesPlaceholder_andClearsFlag`.
- `meetingDetail_exposesTitleIsPlaceholder`.
- `audioPaths_singleTrack_returnsSystemOnly`.
- `audioPaths_noPresentRefs_returnsNil`.

### TranscriptionService tests
- `transcribe_singleTrackMeeting_passesNilMic`.

### Intelligence tests
- `autoRun_placeholderTitle_getsAITitle`.
- `autoRun_afterAITitle_doesNotRetitle`.
- `autoRun_editedTitle_untouched`.
