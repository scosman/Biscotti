---
status: complete
---

# Model Download UX

We want to improve the UX around model downloads. There are two UI surfaces that
trigger downloads: **Settings** and **Onboarding**. There are two kinds of model
being downloaded: the **LLM** (language model, via `Packages/LocalLLM`) and the
**ArgMax/WhisperKit** transcription + speaker-ID models (via `Packages/Transcription`).

## What we want improved

- **Cancel button when downloading LLMs.** While an LLM download is in flight,
  the user can cancel it. Cancelling stops the download and deletes any
  partially-downloaded file.
- **Cancel button when downloading ArgMax models — if the API supports it.**
  Same intent as the LLM cancel (stop + clean up partial files), but only if the
  WhisperKit/SpeakerKit download API can be cancelled cleanly. If it can't, we
  fall back to a defined behavior rather than shipping a broken cancel.
- **Check available disk space before downloading any model.** There's no point
  starting an 8 GB download with 2 GB free. Before a download begins, check that
  there's enough free space for the model. If there isn't, warn the user and ask
  them to free up space (rather than silently failing or starting a doomed
  download).

These improvements apply to **both** the Settings and Onboarding surfaces.
