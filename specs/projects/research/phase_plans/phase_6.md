---
status: complete
---

# Phase 6: AudioLab (E1)

## Overview

Build a disposable macOS SwiftUI reference app at `/experiments/AudioLab/` that exercises the audio research recommendation from R1. The app implements both global and per-process Core Audio process taps for system audio, AVAudioEngine for microphone capture, live audio stream/process monitoring, and dual-file AAC-LC/CAF recording with crash-safe streaming. The capture mode (global vs per-process) is user-selectable in the UI.

## Steps

### 1. Project scaffold
- Create `project.yml` for XcodeGen with macOS 15+ target, arm64, ad-hoc signing, non-sandboxed.
- Info.plist with `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription`.
- App entry point (`AudioLabApp.swift`) with a two-tab SwiftUI layout: Streams and Record.

### 2. Audio process/stream model layer
- `AudioProcess` model: wraps Core Audio process object properties (bundle ID, PID, name, isRunningInput, isRunningOutput).
- `AudioStreamMonitor`: polls/listens to `kAudioHardwarePropertyProcessObjectList`, publishes a live list of audio-active processes.

### 3. System audio capture (Core Audio process taps)
- `SystemAudioCapture`: encapsulates `CATapDescription` + `AudioHardwareCreateProcessTap` + aggregate device + IOProc.
- Supports two modes: global (all processes) and per-process (target a specific `AudioObjectID`).
- Writes PCM buffers to a CAF file via `ExtAudioFile` with AAC-LC encoding.
- RMS health monitor for zero-buffer detection.

### 4. Microphone capture (AVAudioEngine)
- `MicCapture`: wraps `AVAudioEngine`, installs a tap on `inputNode`, writes buffers to a separate CAF file with AAC-LC encoding.

### 5. Recording coordinator
- `RecordingCoordinator`: starts/stops both captures together, manages file paths, shared start timestamp, exposes file metadata (path, size, duration).
- Generates file names with ISO timestamp prefix.

### 6. SwiftUI views
- `StreamsView`: displays the live list from `AudioStreamMonitor` — bundle ID, PID, input/output status. Highlights known meeting apps.
- `RecordView`: capture mode picker (global / per-process with app selector), start/stop button, recording status, file info (paths, sizes, durations). Mic recording alongside system audio.

### 7. VALIDATION.md
- Write the V1 manual test script.

### 8. Unit tests
- Test AAC encoder settings construction.
- Test file naming logic (timestamp format, suffix).
- Test `AudioProcess` model initialization and known-meeting-app detection.
- Test RMS calculation on synthetic buffers.

## Tests

| Test | What it validates |
|------|-------------------|
| `testEncoderSettings` | AAC-LC format, 48 kHz, mono, 64 kbps values are correct |
| `testFileNaming` | Filenames contain ISO timestamp and correct suffixes (_mic.caf, _system.caf) |
| `testAudioProcessModel` | Model correctly stores bundle ID, PID, and running state |
| `testKnownMeetingApps` | Known bundle IDs (Zoom, Teams, Chrome, etc.) are recognized |
| `testRMSCalculation` | RMS of silence is 0.0; RMS of known signal matches expected value |
