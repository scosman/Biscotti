---
status: complete
---

# Import Audio File

Import an existing audio (or video) file and transcribe it as a meeting, the same way a just-recorded meeting is transcribed (upstream scosman/Biscotti#104).

## Goals

- Pick one or more audio/video files and get a meeting per file, with transcript, speakers and the usual auto-enhancements (summary, title, speaker names).
- Reuse the existing recording/transcription/enhancement pipeline instead of building a second one.
- Importing must not interfere with an in-progress recording or transcription.

## Non-goals

- Numeric transcription progress (the UI shows Queued / Transcribing with elapsed time, as for recordings).
- Streaming very large files (the whole file is still loaded into memory by transcription).
- Calendar association, voiceprint backfill, or any format conversion.

See `functional_spec.md` for behavior and `architecture.md` for the implementation.
