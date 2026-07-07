---
status: complete
---

# Research

Up-front technical research for the Biscotti app (see [`specs/app_overview.md`](../../app_overview.md)). The goal is to resolve the real technical unknowns — Core Audio, system permissions, on-device STT/diarization, EventKit — before we design and build the core app. Once these are settled, the app layer can be designed in detail with no major technical unknowns remaining.

## Scope

A project covering the 3 highlighted research efforts, plus any other unknowns worth researching that come out of planning:

1. **Audio integration** — recording, detecting streams, capturing system + mic audio, permissions, format/compression, crash-safe streaming.
2. **EventKit** — read calendar/events, permissions, filtering calendars, the data available to enrich our Meeting model.
3. **ArgMax wrapper** — WhisperKit (Parakeet V3 STT) + SpeakerKit (sortformer diarization) wrapped into a simple `processAudio(audioFile) -> transcriptObject` library. May graduate to a real library later, so it warrants more testing than the other two.

Add other genuine unknowns worth researching. We do **not** need to research well-known ground (using SwiftData, building SwiftUI apps). Focus on the deeper tech: Core Audio, system permissions and their limits, on-device STT, SpeakerKit/diarization, ML model lifecycle/isolation, etc.

Experiments live in an `experiments/` folder (per `app_overview.md`), each independent, with a lighter testing bar since they're throwaway / reference code.

## Implementation Shape

Implementation should be broken into three kinds of phases:

- **Research phases** — research SDKs/APIs and save the knowledge to docs under `/research/X` folders. Done by research sub-agents during implementation.
- **Coding phases** — no user interaction; just build the experiment apps/libraries.
- **Validation phases** — the user validates things that can't be unit-tested (system integration, real audio recording, permissions UI). These are well-defined manual test scripts (per the skill's manual-testing approach). They come **after** all coding so we're not blocked constantly.

## Planning Notes

- Planning the spec does **not** need to do the research itself — just plan it. Some basic searches may aid planning, but the actual research is done by sub-agents during implementation.
- The spec should enumerate **all** the technical research we want to do.
