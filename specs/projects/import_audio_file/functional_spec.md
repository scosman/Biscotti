# Functional Spec: Import Audio File

## Entry points

All of them funnel into `AppCore.importAudioFiles(at:)`:

- **File > Import Audio File...** (app menu).
- **Toolbar** button ("Import audio file") in the main window.
- **Menu-bar popover** row "Import Audio File...". It opens the main window first, then shows the open panel.
- **Drag-and-drop** of files anywhere on the main window.

The open panel allows multiple selection of audio and movie types (`.audio`, `.movie`, mp4/m4a/mp3/wav/aiff, plus extension-only aac/flac). Supported formats are whatever AVFoundation can read; the type filter is only a first gate.

## Behavior per file

1. Unsupported types (not audio/movie) are skipped with "Only audio and video files can be imported."
2. The file is validated before anything is created: it must be a readable regular file, non-empty, have at least one audio track, and a duration greater than zero. Video files (mp4/mov) import via their audio track.
3. A new meeting is created:
   - Title: the file name without extension (default meeting title if empty).
   - Date: the file's creation date, else modification date, else now.
   - Duration: the audio duration.
   - No calendar event association.
4. The file is copied (never moved) into the meeting's recordings directory as `imported.<original extension>` and attached as a single `.mic` audio file. There is no system track.
5. Transcription then runs like after a recording (including auto summary / title / speaker-name inference). Speaker voiceprints are not backfilled for imports.
6. Any failure after the meeting row exists rolls back both the row and the directory.

Multiple files are imported one after another. Their transcriptions wait in a shared queue; a meeting shows "Queued" until its turn. Calling import while a batch is running appends to that batch. Import is allowed while a recording is active and does not navigate away from the live recording screen.

## Errors

Failures are collected per batch and shown in one alert: "Couldn't import <name>" (or "Couldn't import N files" with a per-file list). Reasons: unreadable/not audio, no audio track, empty audio, copy failed, storage failed.

## Transcription UI

- A queued meeting shows "Queued"; a running one shows elapsed time and a **Cancel** button.
- Cancelling gives a terminal `cancelled` state (no transcript). The user can re-run transcription; imported meetings can also be deleted from that state, since the audio is just a copy of a file the user still has.
- Transcription works for meetings that have only one audio track (mic only or system only).

## Imported-meeting marker

A meeting counts as imported when it has a single `.mic` ref whose file name starts with `imported.` and no system track. This is derived, not stored (no schema change); it drives the delete-when-cancelled affordance.

## Known limitations

- No numeric progress, only Queued / Transcribing with elapsed time.
- The whole file is loaded into memory for transcription, so very long files use a lot of RAM.
- Formats are limited to what AVFoundation reads; others fail with the unreadable error.
- Imports are not associated with calendar events and do not backfill speaker voiceprints.
