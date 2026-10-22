---
status: complete
---

# Implementation Plan: Apple STT Validation

All code is in `experiments/STTLab/` (see `architecture.md` and `components/`). Build and test through hooks-mcp `build`/`test` after phase 1 (the Makefile includes the package locally).

## Phases

- [x] Phase 1: Package scaffold (`Package.swift`, targets, `.gitignore`), `STTLabCore` (schemas, JSON IO, WAV IO, SHA-256, MemorySampler, MachineInfo, RunLog, ErrorInfo, BundleLoader, RunnerResume, AppleMeetingResult), Makefile `EXPERIMENT_PACKAGES` + hooks-mcp actions, Core tests.
- [x] Phase 2: Prep: StoreReader (store snapshot via DataStore), Selector, Confirm + ConsentGate, BundleBuilder (AudioMerger → Float32 WAV, meta, manifest, README), the `sttlab` CLI with `select`/`confirm`/`bundle`, tests.
- [x] Phase 3: Home engines: ProductionSettings (+ drift test), WhisperRunner, DiarizationRunner (+ SavedDiarization round trip), ChunkPlanner, OpenRouterClient + retry/split policy + response parsing, ReferenceRunner (+ probe, cost prompt), `whisper`/`diarize`/`reference`/`home-run` commands, tests.
- [ ] Phase 4: Runner app: RunnerApp/View/Model, RunnerJob, AppleTranscription (macOS 26+), ResultsWriter, CLI mode, `scripts/package_runner.sh`, tests for the pure parts.
- [ ] Phase 5: Analysis core: model types, AppleWordGrouper, Normalizer, Aligner (Hirschberg + naive), WER, TieBreak, Flags, TextQuality, Timing, tests.
- [ ] Phase 6: Speaker alignment (bridge + ProductionAssembly + sanitizer), AnalyzeInputs, SpeakerMetrics, ReportModel + MarkdownRenderer + transcripts, the `analyze` command, `NOTES.md` (how to run, end to end), tests.
