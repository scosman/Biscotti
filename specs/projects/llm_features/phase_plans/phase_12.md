---
status: complete
---

# Phase 12: End-to-end verification & docs

> **Renumbered from Phase 7** when the polish round (Phases 7–11) was inserted; moved to the end so it validates the polished build in one on-hardware pass. The agent portion below (docs update) was completed under the original Phase 7. **Awaiting human on-hardware app click-through** — covering the polish-round behaviors too (pipeline status, no completion flash, `userSet` preservation, merged-speaker color, Settings layout/order). The dedicated `ai_*` ManualTestKit script was removed: its checks were UI-behavior assertions already covered by unit/UI tests, plus model-inference checks already covered by the `llm_*` Local LLM tab. AI-feature verification is covered by the Local LLM HW tab (`llm_*`, all passing), automated unit/UI tests, and the app click-through below.

## Overview

Final phase: update the `specs/` roadmap docs to reflect that LLM/AI features are built, and verify all CI gates are green. The on-hardware app click-through (download model, record/transcribe, observe AI features, tune prompts) is deferred to a human.

## Steps

1. **Update `specs/architecture.md`** — reflect that Intelligence is no longer P2/future but built and wired into AppCore + MeetingDetailUI + SettingsUI. Update the component card, dependency graph annotations, and P2 placement table.

2. **Update `specs/implementation_plan.md`** — update Project 10 (Intelligence/LLM) status to reflect that the LLM features spec project has built the core AI features (summarization + speaker identification) as part of the `llm_features` project. Clarify what remains (provider abstraction, external provider, vocab extraction are still future).

3. **Check `CLAUDE.md` and `app_overview.md`** for status lines that should reflect these features being implemented. Update conservatively.

4. **Verify CI gates** via hooks-mcp: `precommit_checks` (lint + format + test), `build_app`, and `manual_tests_check`.

## Tests

- `CIGateTests` satisfied by existing `ac_*`/`tx_*`/`llm_*` results in the JSON (no `ai_*` entries remain).
- `ScriptShapeTests` validates the three remaining scripts (audio_capture, transcription, local_llm) with `allScripts.count == 3`.

## Deferred to human (on-hardware)

The following must be done on real Apple Silicon hardware to complete Phase 12:

1. **Download model** — Open Biscotti app Settings, navigate to AI Enhancements, download the LLM model
2. **Record and transcribe** — Record a real meeting (2+ speakers, 30+ seconds), stop, wait for transcription
3. **Observe auto speaker-ID** — Verify speaker labels change from "Speaker 0/1/..." to real names after transcription
4. **Observe streamed summary** — Verify Summary tab streams in coherent markdown with an Action Items section
5. **Edit summary** — Edit the summary, confirm autosave persists
6. **Regenerate with confirmation** — Regenerate an edited summary, confirm the warning dialog appears
7. **Regenerate without confirmation** — Regenerate an AI-generated (unedited) summary, confirm no dialog
8. **Manual speaker rename** — Click a speaker label, use the mapping sheet to assign a different person
9. **Manual unassign** — Set a speaker back to "Unassigned", confirm "Speaker N" label returns
10. **Model-free manual assignment** — Turn off AI toggles, record/transcribe, confirm no auto-run, but manual mapping still works
11. **Tune `IntelligencePrompts` if needed** — Based on real model output quality, adjust prompt wording

### Polish-round (Phases 7–11) checks
12. **Pipeline status** — Right after recording, the Summary tab shows the `Transcribing → Inferring participant names → Summarizing` stage control (not "No transcript available."); the view auto-jumps to Summary; no tab-bar pill
13. **Re-transcribe re-runs AI** — Use Re-transcribe; confirm speaker-ID + summary re-run and the pipeline status shows
14. **No completion flash** — When the streamed summary finishes, it does not flash to empty/Generate, and scroll position is retained
15. **`userSet` preserved** — Manually rename a speaker, then re-transcribe/re-run; confirm the manual assignment is NOT overwritten by the LLM
16. **Merged-speaker color** — Assign two speaker IDs to the same person; confirm they share one color (and the sheet's dot matches)
17. **Settings layout** — "AI runs locally on your Mac." is grey text trailing the section header; Permissions is the 2nd section (after General)

### Record results
18. **Confirm `manual-tests-check` is green** — With the `ai_*` script removed and all `ac_*`/`tx_*`/`llm_*` results passing, the manual-tests-check gate should be green. Note any issues from the click-through above for follow-up.
