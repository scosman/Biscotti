---
status: draft
---

# Import Audio

I want an option to import audio files into Biscotti.

## UX

- 2 ways to initiate:
  - **File > Import Audio File** option that opens a file picker.
  - **Whole window is a drag and drop target.** When you drag a file over it, it shows the "drop state" (see the attached design brief).
- **Importing screen:** after initiating, you end up on the importing screen, a new screen in the main area. Pretty simple: just a spinner and status message while it converts the audio file into our standard format. On complete it jumps to the meeting view, and you get the usual post-recording UX (transcribing, etc.) — all of that is reused. If re-encode fails, the import screen shows an error.
- Use the default meeting name you get from the Record button, and let the LLM-given name replace it (it already does that, just don't break it).
- **Invalid files dragged over:**
  - Single: the overlay shows "Can't import this file", and modifies colors.
  - Multi, a mix where some are okay and others are not: the title still says "Drop to import N files", with an error message below: "N files are unsupported file types and will be skipped."

## Technical

- **Multi-file drop works.**
  - The drag and drop and the import screen both support it.
  - "Drop to import" just becomes "Drop to import N files" for multi.
  - The import screen shows a list and processes in order. Next to each: a spinner at first, then "Go to Meeting" when the encode is done (instead of automatically jumping to the meeting, which we do for a single file).
- **File formats:** allow all the standard audio file extensions (wav, mp3, mp4, m4a, caf, etc.).
  - File > Import Audio File filters to these extensions.
  - The drag and drop has a state (described in the attached design brief).
- **Video files are accepted:** extract the audio track only.
- **Re-encode:** use the standard macOS audio stack to re-encode.

## Design

A design brief from the design agent is attached:

- [`design/design_handoff.md`](design/design_handoff.md) — the handoff README (states, copy, tokens, behavior).
- [`design/import_audio_mockups.html`](design/import_audio_mockups.html) — HTML mockups of every state (open in a browser).

**Our design guide in this repo trumps it on details** (fonts, sizes, colors, etc.), but the HTML version looks good, so use it as reference.
