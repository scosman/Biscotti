---
status: draft
---

# Functional Spec: Audio Import

## 1. Entry points

1. **Toolbar button** "Import Audio" beside the Record button (icon: `square.and.arrow.down`).
2. **File > Import Audio…** (⌘O) menu command.
3. **Drag-and-drop** of one or more audio files onto the meeting list.

The first two open an `NSOpenPanel` (SwiftUI `.fileImporter`) with
`allowsMultipleSelection = true`. Selecting several files imports each as its own
meeting, queued one after another (the transcription service runs one job at a time).

Disabled while a live recording is active (one pipeline at a time keeps memory
bounded; transcription of a live recording starts right after stop).

## 2. Accepted files

Audio-only. Accepted: `.mp3 .m4a .aac .wav .aiff/.aif .caf .flac`. Detection is by
`UTType` conformance to `.audio`, then confirmed by opening with `AVAudioFile`
(or `AVAsset` for container formats) and requiring ≥ 1 audio track, **no video tracks**, and duration > 0.

Rejected with an alert (nothing is created): unreadable/corrupt file, no audio
track, zero duration, or video files (v1 is sound-only; video is a follow-up).

## 3. What import does

1. Create a `Meeting` titled `Meeting.defaultTitle` (so AI titling still applies).
   Set the dates and duration as described in §3.1.
2. Copy the file into `<storageRoot>/<meetingID>/imported.<ext>` (the original is
   never modified or moved). Attach one `AudioFileRef` with role `.imported`.
3. Select the new meeting (route to Meeting Detail).
4. Run the same background pipeline as a stopped recording:
   `transcription.transcribe(meetingID:)` then `intelligence.runAutoEnhancements`.
5. Meeting Detail shows the existing job-status UI (downloading model → transcribing →
   summarizing) with the existing retry affordance on failure.

### 3.1 Which date does the meeting get?

The meeting's `startDate` (the date shown in the list and detail header, and used for
sorting) is the **audio file's own date, not the moment you imported it**. Picked in
this order, first one available wins:

1. The file's **creation date** on disk (read from the original, *before* copying, since
   copying resets it).
2. The file's **last-modified date**.
3. **Now** (import time), if the file has neither.

`endDate` = `startDate` + the audio duration. `createdAt` is always the import time (it is
the record's creation time, as for every meeting). Known limit: a file that was downloaded
or copied between machines may carry the download time rather than the real recording
time. v1 does not read metadata embedded in the audio, and the date is not yet editable;
see Open questions.

## 3.2 "Imported" indicator in the UI

A meeting made from an uploaded file must be visibly different from a live recording, so
nobody mistakes it for something Biscotti captured:

- **Meeting Detail:** an **"Imported audio"** pill (icon `square.and.arrow.down`, same
  capsule style as `SourcePill`) in the meta line under the title, with a
  tooltip ("Imported from an audio file"). The original filename isn't stored in v1.
- **Sidebar / meeting list row:** the second line reads "Jun 9, 2026 · 34m · Imported".
- **Transcript tab:** a one-line note at the top: "Transcribed from an imported audio file.
  Speaker labels come from voice analysis only."
- **Recording-only UI** (live-recording notes, "You" labelling) is hidden for imported meetings.

No new database field is needed: a meeting is "imported" when its audio file has the
`.imported` role, so the indicator can't drift out of sync with the data.

## 4. Differences from live recordings

| Aspect | Live | Imported |
|---|---|---|
| Audio files | `mic.aac` + `system.aac` | single `imported.<ext>` |
| Mic/system channel hints | available | none: speakers come from diarization alone |
| "You" speaker identification | via mic channel | not available; speakers are labelled generically and the AI step may name them |
| Re-transcribe | supported | supported (same single file) |
| Delete meeting | removes recording dir | removes recording dir (includes the copy) |
| Notes during recording | yes | n/a (notes can still be edited afterwards) |

## 5. Errors

- Copy fails (disk full / permission): alert, meeting and partial files are removed.
- Transcription failure: existing `.failed(message:retriable:)` UI.
- Not enough disk space is surfaced by the existing `insufficientDisk` path.

## 6. Non-goals (v1)

Video files, URL import, trimming, language override, importing existing transcripts.

## 7. Open questions

- Should the user be able to edit the meeting date after import (useful when the file date is wrong)?
- Should a later version prefer date metadata embedded in the audio (e.g. m4a/mp3 tags) over the file-system date?
