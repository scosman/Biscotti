---
status: complete
---

# Apple STT Validation (Apple SpeechTranscriber vs WhisperKit vs SOTA)

## Context

We use WhisperKit + SpeakerKit on Argmax's free tier. Research (`specs/research/stt-engine-swap/summary.md`) showed we can swap the STT engine cleanly while keeping SpeakerKit.

Apple's SpeechTranscriber has a lot of upsides:

- About 4x faster than our current model, according to Argmax benchmarks.
- Comparable quality.
- Users often already have the model installed: zero download cost, no incremental disk cost.
- Users sometimes already have the model in memory: zero load time.
- No new libraries/deps.
- Apple optimized/tested.
- Downside: fewer languages.

FluidAudio's stability is questionable. We'd isolate it in a sub-process, but still.

## Intended product direction (only if this experiment passes)

- Apple SpeechTranscriber is the default where supported. WhisperKit (current large-v3-turbo) stays as the alternative ("Other"), which is better at some things (languages, WER), but most people won't see a difference. Other has less test coverage going forward, so lean on keeping what's working and tested. Moving Other to Parakeet is P3.
- The user chooses the engine at startup, using the same pattern as the language model choice (we already have that UI). We can "recommend" based on locale, but never hide the option — we don't know if a user sometimes speaks Polish.
- Language setting defaults to the system locale, with a setting to override it.

The app integration is designed **only if** this experiment passes.

## This project

Biscotti is all about technical validation up front (see our technical explorations pre-shipping). Before designing the app integration, we design a gate.

Build a new experiment in `/experiments` that runs Apple SpeechTranscriber on a number of real meetings, alongside our current WhisperKit pipeline. It checks:

1. Performance.
2. Word disagreements between Apple and Whisper.
3. Comparison to a SOTA server-side model (via OpenRouter keys), to see which local engine is closer to it.
4. Memory, if we can measure it.
5. Whether Apple's timings align with Whisper's and work well with SpeakerKit, or not.
6. Etc.

I'll need to run the app on my wife's Mac (she's on macOS 27; I'm on macOS 15). It should export a bunch of data I can bring back for analysis.
