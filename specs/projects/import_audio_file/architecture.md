# Architecture: Import Audio File

Built in six commits (see `git log`), bottom-up.

## Components

- **Transcription package / `TranscriptionService`**: `Transcribing` and `TranscriptionService` accept meetings with a single audio track (mic or system) instead of requiring both. The engine/XPC request gained cancel support; `TranscriptionService` exposes `cancel(meetingID:)`.
- **`JobStatus`** gained `.queued` (waiting its turn) and `.cancelled` (terminal, like `.failed`, no transcript).
- **`TranscriptionQueue`** (`AppCore`): serializes transcription jobs so imports wait for the running job instead of failing or racing. `AppCore.spawnTranscription(meetingID:)` enqueues; dequeuing a waiting job marks it `.cancelled`.
- **`AudioFileImporter`** (`Recording`): `validate(_:)` (readable regular file, non-empty, audio track, duration > 0; returns duration, start date, byte size; creates nothing), `stage(source:into:)` (creates the meeting directory, writes the `.recording` marker first so orphan recovery handles a crash mid-copy, copies to `imported.<ext>`), `finalize(directory:)` (removes the marker) and `discard(directory:)`. The copy primitive is injectable for tests. Errors are `AudioImportError` with user-facing `LocalizedError` text.
- **`AudioImportSupport`** (`AppCore`): allowed content types, `isSupported(_:)`, the shared open panel, and `AudioImportAlert` / `AudioImportFailure` copy.
- **`AppCore.importAudioFile(at:importer:)`**: validate off the main actor, create the meeting, stage and attach the `.mic` ref, set the duration, roll back on error, reload summaries, select the meeting (without leaving a live recording screen), then `spawnTranscription`. Does not touch `runState`.
- **`AppCore.importAudioFiles(at:)`**: the single funnel for all entry points; sequential, re-entrant (appends to a running batch), publishes `audioImportFailures`, `isImportingAudio`.
- **UI**: `AppShellViewModel+AudioImport` (menu, toolbar, drop), `MenuBarViewModel.importAudioFiles()`, `AppShellView` alert, `MeetingDetailViewModel.isImportedAudio` and the Cancel / elapsed-time / queued states in `MeetingDetailView`.
- **DataStore read models** carry the audio refs needed to treat a single-track meeting as transcribable.

## Data model

No schema changes. An imported meeting is an ordinary `Meeting` with one `AudioFileRef(role: .mic)` at `<Recordings>/<meetingUUID>/imported.<ext>`.

## Tests

Swift Testing coverage in `AppCoreTests` (import, edge cases, support, queue), `AppShellUITests`, `MenuBarUITests`, `MeetingDetailUITests`, `TranscriptionServiceTests`, `TranscriptionTests` (audio loading, hosted client), and `DataStoreTests`. A hardware pass is tracked by the `tx_import_audio_file` ManualTestApp step (Transcription tab): import a real m4a, mp3 and mp4/mov.
