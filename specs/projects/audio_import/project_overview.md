---
status: draft
---

# Audio Import

Let the user upload a media file (sound only) and have Biscotti transcribe and
summarize it exactly as it does a live recording: diarized transcript, AI summary,
title, action items, and speaker-name inference.

- Entry points: a toolbar button next to Record, **File > Import Audio…**, and
  drag-and-drop of audio files onto the meeting list.
- The result is an ordinary `Meeting`: it appears in the sidebar, has playback, a
  transcript, and a Summary tab, and is searchable and exportable.
- Everything stays on-device, like the rest of the app.

## How it works, in plain language

1. You choose an audio file (or drop it on the app).
2. Biscotti makes a private copy inside its own recordings folder and creates a new meeting
   for it, dated with the file's date and marked **Imported audio**.
3. It then does exactly what it does after a live call: listens to the audio on your Mac,
   writes a speaker-labelled transcript, then writes the summary, title and action items.
4. You find the result in your meeting list like any other meeting.

The only real engineering change is that the transcriber currently expects *two* audio files
(your mic and the other side of the call). An uploaded file is one file, so the transcriber
is taught to accept a single file. See `architecture.md` for the layer-by-layer changes and
`implementation_plan.md` for the order of work.
