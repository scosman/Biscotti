---
status: complete
---

# Stage A Foundations — Transcription, Audio Capture, Data Store (+ Manual Test App)

This is **one spec covering four parts**, designed to be built as a single large agentic run. The four parts are essentially separate projects and are planned as such — but combined into one spec so they can be implemented back-to-back with no human interaction until the very end.

The four parts:

1. **Transcription Library** — Stage A / Project 1. Productionize `experiments/ArgMaxKit` into the `Transcription` package: on-device STT + diarization, model management, crash-isolated worker (XPC + CoreML), custom-vocab biasing, output sanitization, re-transcribe, CLI harness.
2. **Audio Capture Library** — Stage A / Project 2. Productionize `experiments/AudioLab` into the `AudioCapture` package: mic + global system-audio two-stream crash-safe capture, route-change survival, long-term-storage repackage/convert, per-process audio monitoring for meeting detection.
3. **Data Store** — Stage A / Project 3. The `DataStore` module in `BiscottiKit`: the SwiftData schema (Meeting/Event, versioned Transcript records, audio-file refs, calendar-snapshot sub-item, notes, settings), container/config, queries/utilities, association + correction, simple V1 search, sync-ready config.
4. **Manual Test App** — the harness from `specs/projects/manual_test_app/project_overview.md`: a macOS app with one tab per library, each tab implementing the library's manual hardware/system test plan in interactive form, saving pass/fail/not-run results to a file in the repo.

## How this spec is structured (per the requested shape)

- **Separate architecture / component docs for each of parts 1, 2, 3** — one component design doc per library, designing its real API inside the boundary the repo `architecture.md` already draws. Parts 1 and 2 are largely a **packaging, testing, and API-design exercise**: the hard technical unknowns are already resolved by the completed `research/` project and proven in `experiments/`. We consume those findings; we do not re-derive them.
- **A separate architecture / component doc for part 4** (the manual test app) — its own design, its own UI shape, its own set of phases.
- **An implementation plan with 4 clear stages** (one per part), each broken into as many phases as needed.

## The core constraint: no human interaction until the final phase

The whole point of combining these is **one big agentic run**. The implementation plan must be ordered so that **every phase up to the last can be completed by an agent autonomously** (build + unit/integration tests via `hooks-mcp`, no hardware, no human). The hardware-, system-, and human-dependent validation (real mic/system audio, real CoreML/XPC on-device, "did you see two permission dialogs", "is the audio quality acceptable") is **all deferred to the very last phase: "run the manual test app."** That final phase is the single point where a human is needed.

## Notes / starting points

- For Projects 1 and 2: look at the `research/` project. Most unknowns are solved — this becomes a packaging, testing, and API-design exercise.
- Component homes, boundaries, and dependencies are already fixed by the repo `architecture.md`; this spec designs the concrete APIs inside those boundaries.
- The `Transcription` and `AudioCapture` packages are their own SPM packages; `DataStore` is a module inside `BiscottiKit`.
</content>
</invoke>
