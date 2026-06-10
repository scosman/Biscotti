---
status: complete
---

# Phase 2.3: ADTS AAC Rewrite + Permission Preflight + Watchlist

## Overview

Eliminate the PCM-to-M4A encode-on-stop step by writing ADTS AAC directly during capture via `ExtAudioFile` with `kAudioFileAAC_ADTSType`. Add mic permission preflight via `AVCaptureDevice.authorizationStatus(for: .audio)` before starting engines. Expand the seed watchlist with two new system-level bundle IDs.

This phase simplifies the recording pipeline (4 URLs down to 2, no post-recording encode step), removes `RecordingFileManager` entirely, and adds a `MicPermissionChecker` protocol seam for testability.

## Steps

### 1. Rewrite `EncoderSettings`

- Rename `.voiceM4A` to `.voice`
- Remove `avSettings` dictionary (no longer needed without AVAudioFile/AVAudioConverter encode step)
- Add `formatID: AudioFormatID` (kAudioFormatMPEG4AAC) and `fileType: AudioFileTypeID` (kAudioFileAAC_ADTSType) stored properties
- Add `outputASBD() -> AudioStreamBasicDescription` method returning encoder-configured ASBD
- Add `static func applyBitRate(to extFile: ExtAudioFileRef) -> OSStatus` using the AudioConverter + NULL CFArrayRef commit pattern
- Keep `processingFormat` unchanged

### 2. Simplify `CapturePaths`

- Collapse from 4 URLs (micCAF, systemCAF, micOutput, systemOutput) to 2 URLs (micAAC, systemAAC)
- ADTS files are the only output; no separate encode destination needed

### 3. Clean up `CaptureError`

- Remove `conversionFailed(String)` and `partialEncodeFailed(result:underlying:)` cases
- Remove entire `EncodeResult` struct
- Add `micPermissionDenied` case for mic permission denial

### 4. Add `MicPermissionChecker` protocol

- Add to `CaptureEngine.swift` alongside existing protocol seams
- Single method: `func authorizationStatus() -> AVAuthorizationStatus`
- Add `import AVFoundation` to the file

### 5. Create `LiveMicPermissionChecker`

- Thin wrapper: calls `AVCaptureDevice.authorizationStatus(for: .audio)`
- Place in a new file `LiveMicPermissionChecker.swift`

### 6. Rewrite `LiveMicCaptureEngine` for ADTS AAC

- Store full `encoder: EncoderSettings` instead of just `processingFormat`
- Change `createExtAudioFile` to create ADTS AAC file using `encoder.outputASBD()` and `encoder.fileType`
- Set client format to `encoder.processingFormat` (PCM -> AAC conversion by ExtAudioFile)
- Call `EncoderSettings.applyBitRate(to:)` after setting client format

### 7. Rewrite `LiveSystemCaptureEngine` for ADTS AAC

- Add `encoder: EncoderSettings` to init (default `.voice`)
- Change `openAudioFile` to create ADTS AAC file using `encoder.outputASBD()` and `encoder.fileType`
- Set client format to the tap's PCM format (so ExtAudioFile handles PCM -> AAC conversion)
- Call `EncoderSettings.applyBitRate(to:)` after setting client format

### 8. Rewrite `AudioRecorder`

- Add `micPermissionChecker: some MicPermissionChecker` parameter to init
- Change `encoder` default from `.voiceM4A` to `.voice`
- `start()`: add mic permission preflight before starting engines; update path references from `systemCAF`/`micCAF` to `systemAAC`/`micAAC`
- `stop()`: change from `throws -> EncodeResult?` to just `async` (no return, no throw); remove entire encode-on-stop block
- `live()` factory: pass `LiveMicPermissionChecker()`, pass encoder to `LiveSystemCaptureEngine`

### 9. Update watchlist in `AudioProcess`

- Add `com.apple.avconferenced` (display: "avconferenced") to both `knownMeetingBundleIDs` and `meetingAppNames`
- Add `com.apple.WebKit.GPU` (display: "WebKit (GPU Process)") to both collections

### 10. Delete `RecordingFileManager.swift`

- CAF-to-M4A encode step is eliminated; this file is no longer needed

### 11. Update tests

- Rewrite `EncoderSettingsTests`: test `.voice`, `formatID`, `fileType`, `outputASBD()`; remove `avSettings` tests
- Rewrite `AudioRecorderTests`: remove `EncodeResult` references, `createTestCAF` helper; `stop()` no longer returns or throws; add mic permission denial test
- Update `AudioProcessTests`: add tests for new watchlist entries
- Update `StartAlignmentTests`: `systemCAF` -> `systemAAC`, `micCAF` -> `micAAC`
- Update `TestRecorderFactory`: 2-URL `CapturePaths`, add `FakeMicPermissionChecker`
- Delete `RecordingFileManagerTests.swift`

## Tests

- `EncoderSettingsTests.voiceSampleRate`: `.voice` has sampleRate 24000
- `EncoderSettingsTests.voiceChannels`: `.voice` is mono
- `EncoderSettingsTests.voiceBitRate`: `.voice` has bitRate 64000
- `EncoderSettingsTests.voiceFormatID`: `.voice.formatID` == kAudioFormatMPEG4AAC
- `EncoderSettingsTests.voiceFileType`: `.voice.fileType` == kAudioFileAAC_ADTSType
- `EncoderSettingsTests.outputASBD`: ASBD has correct formatID, sampleRate, channelCount
- `EncoderSettingsTests.processingFormat`: PCM format matches settings
- `EncoderSettingsTests.equatable`: value equality works
- `AudioRecorderTests.startAndStopLifecycle`: start/stop with fakes, engines stopped
- `AudioRecorderTests.stopWhenNotRecordingIsNoOp`: stop before start is no-op
- `AudioRecorderTests.stateStreamEmitsUpdates`: state stream emits isRecording=true
- `AudioRecorderTests.idleStateBeforeStart`: idle state defaults
- `AudioRecorderTests.captureStateIdle`: CaptureState.idle defaults
- `AudioRecorderTests.micPermissionDenied`: denied status throws micPermissionDenied
- `AudioProcessTests.avconferencedRecognized`: com.apple.avconferenced is meeting app
- `AudioProcessTests.webkitGPURecognized`: com.apple.WebKit.GPU is meeting app
- `StartAlignmentTests.systemStartsFirst`: paths use systemAAC/micAAC
