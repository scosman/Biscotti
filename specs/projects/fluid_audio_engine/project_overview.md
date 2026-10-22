---
status: draft
---

# FluidAudio Engine

This project is another transcription and diarization engine for macOS:
https://github.com/FluidInference/FluidAudio

I want this branch to be swapping out WhisperKit driving Whisper V3 Turbo /
pyannote with FluidAudio driving NVIDIA Parakeet V3 and Sortformer (or any
model supported by FluidAudio).

It should be essentially transparent to the app: this runs in a sub-process, in
its own lib (correct?), so should be quite isolated.

Read the API docs, and plan the transition.

**P2:** keep both, with the model API param selecting engine as well as model.

---

## Confirmation of the isolation assumption

Yes. The blast radius is small:

- `Packages/Transcription` is a standalone SPM package. Its only ML dependency
  is `argmax-oss-swift` (WhisperKit + SpeakerKit).
- `XPCServices/BiscottiTranscriber` is a thin XPC host that links that package
  and runs the engine in a separate, crash-isolated process.
- The app talks to it only through `Transcriber` (actor) → `TranscriptResult`
  (a `Codable` value type), behind the `Transcribing` protocol seam in
  `BiscottiKit/TranscriptionService`.

Nothing above `Packages/Transcription` imports WhisperKit or SpeakerKit. So the
swap is contained to that package plus the parts of `TranscriptResult` that the
new SDK cannot populate the same way.
