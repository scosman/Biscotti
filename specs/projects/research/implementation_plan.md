---
status: complete
---

# Implementation Plan: Research

Batched by stage: all research → all coding → all validation. Phases reference `functional_spec.md` (key questions per area) and `architecture.md` (scaffolding, templates, build/check commands) for details.

Each coding phase also **writes** its experiment's `VALIDATION.md` manual test script. The validation phases (P9–P11) are purely human-in-the-loop: run the script, record results back into the matching research doc.

## Phases

### Research → decision docs under `/research/<area>/`
- [x] Phase 1: Audio research (R1) → `research/audio/README.md`
- [x] Phase 2: EventKit research (R2) → `research/eventkit/README.md`
- [x] Phase 3: ArgMax STT + diarization + ML isolation research (R3) → `research/argmax/README.md`
- [x] Phase 4: Permissions matrix research (R4) → `research/permissions/README.md`
- [x] Phase 5: Research summary → `research/README.md` (recommendations + links)

### Coding → reference apps/libs under `/experiments/<Name>/` (each also writes its `VALIDATION.md`)
- [x] Phase 6: AudioLab (E1) — implement R1; write `VALIDATION.md` (V1 script)
- [x] Phase 6b: AudioLab live auto-refresh (E1) — Streams tab updates without manual refresh; resolve the poll-vs-notify decision for per-process input/output state. Surfaced during Phase 9 V1 Test 1. Add `VALIDATION.md` Test 8.
- [x] Phase 7: EventKitLab (E2) — implement R2; write `VALIDATION.md` (V2 script)
- [x] Phase 8: ArgMaxKit (E3) — implement R3 library + CLI harness; write `VALIDATION.md` (V3 script)

### Validation → human-in-the-loop runs of the pre-written scripts; record results into research docs
- [x] Phase 9: Run V1 (audio) with user; fold results into `research/audio/README.md` — **done**. All V1 tests run on M4/macOS 15 (Test 3 descoped to global-only). Added `VALIDATION.md` Test 9 (build & runtime logs/warnings audit) as a catch-all sanity sweep — clean build, only known-benign Core Audio log noise. Key decisions: ADTS AAC 24 kHz/64 kbps (crash-safe), plain `AVAudioEngine` mic with route-change recovery (VPIO rejected), notify-not-poll stream monitoring, zero-buffer backstop deferred (doesn't reproduce on macOS 15). Results folded into the research doc + `phase9_validation_findings.md`.
- [x] Phase 10: Run V2 (eventkit) with user; fold results into `research/eventkit/README.md` — **done**. All 10 V2 tests run (M4/macOS 15). Found+fixed a live-toggle observation bug (Test 4); decided to punt Contacts enrichment (Test 7, resolves Open Q#3); conference detection validated. Results folded into the research doc.
- [x] Phase 11: Run V3 (argmaxkit) with user; fold results into `research/argmax/README.md` — **done**. 8/10 V3 tests run on M4/macOS 15 against a 25s 3-speaker clip (models pre-cached); Test 7 optional/not-run, Test 6 functional (memory unquantified). Found+fixed a `--json` stdout-pollution bug (diagnostics → stderr). Findings folded into research doc: segment-level confidence unpopulated, trailing hallucinated segments past audio length, ~0.43x RTF. XPC isolation reframed (Gotcha #3) as standard tech with a few integration details to confirm during implementation, not a research unknown.
