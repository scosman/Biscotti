---
status: complete
---

# Implementation Plan: Speaker Embeddings (Voiceprint Database)

Details for every phase are in [`architecture.md`](architecture.md) (section
numbers below). Public GitHub actions (sync, rename, push, PR) need the
developer's confirmation first.

## Phases

- [x] Phase 1: SpeakerKit fork (§2).
  - **First step:** use the developer's existing fork,
    `https://github.com/scosman/WhisperKit` (the repo's old name, about two
    years old). Sync its `main` with upstream `argmaxinc/argmax-oss-swift`
    `main` and fetch upstream tags. Stop and ask if the fork has commits that
    upstream does not. Then rename it to `argmax-oss-swift`, so the SwiftPM
    package identity matches the existing `package: "argmax-oss-swift"`
    references.
  - Add `speakerPLDACentroidEmbeddings` + SDK tests on a `v1.1.0`-based branch,
    pin `Packages/Transcription` to that commit, add the `CLAUDE.md` gotcha,
    open the upstream PR from a `main`-based branch.
- [ ] Phase 2: Transcription capture — `.trainableOnly`, `embeddingSets` (raw +
  PLDA) replacing `speakerEmbeddings`, `speakerSpeechDurations`,
  `SpeakerEmbeddingSpace`, sanitizer pass-through, `SpeakerAnalyzer` + shared
  helpers, test and CLI-output updates, mark `tx_*` manual tests `not-run` (§3).
- [ ] Phase 3: Storage — `Voiceprint` model, `addTranscript` writes, corpus /
  query / backfill reads, `currentUserPersonID` on `CalendarSnapshot`,
  `setParticipants(currentUser:)`, `calendarContext` marker, AppCore
  `persistSnapshot` (§4, §7).
- [ ] Phase 4: `VoiceprintMatching` module — config, vector math, prepared
  corpus, matcher + `explain`, backfill speaker mapper, evaluator, metrics
  formatter (§5).
- [ ] Phase 5: LLM integration and debug window — prompt changes, report
  rendering, evidence builder, `runAnalysisSession` wiring, `#if DEBUG` debug
  report + `VoiceprintDebugView`, `IntelligenceAITests` + `make test-ai` (§6, §8,
  §10).
- [ ] Phase 6: CLI, docs, calibration — `voiceprint-cli backfill` and `metrics`
  (§9), documentation updates (§13), then the developer's calibration pass and
  `calibration.md` (§12).
