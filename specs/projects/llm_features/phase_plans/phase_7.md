---
status: draft
---

# Phase 7: End-to-end verification & docs

> **Agent portion done; awaiting human on-hardware run.**

## Overview

Final phase: update the repo-root roadmap docs to reflect that LLM/AI features are built, add a new ManualTestKit script for the app-level AI features, and verify all CI gates are green. The on-hardware manual run (download model, record/transcribe, observe AI features, tune prompts) is deferred to a human.

## Steps

1. **Update root `architecture.md`** — reflect that Intelligence is no longer P2/future but built and wired into AppCore + MeetingDetailUI + SettingsUI. Update the component card, dependency graph annotations, and P2 placement table.

2. **Update root `implementation_plan.md`** — update Project 10 (Intelligence/LLM) status to reflect that the LLM features spec project has built the core AI features (summarization + speaker identification) as part of the `llm_features` project. Clarify what remains (provider abstraction, external provider, vocab extraction are still future).

3. **Check `CLAUDE.md` and `app_overview.md`** for status lines that should reflect these features being implemented. Update conservatively.

4. **Author `AIFeaturesScript.swift`** in `ManualTestKit/Scripts/` — a new manual-test script with prefix `ai_*` that covers the end-to-end app-level AI features: model download in Settings, record/transcribe flow, auto speaker-ID, streamed summary, edit summary, regenerate with confirmation, manual speaker rename via mapping sheet, model-free manual assignment. Follow existing script patterns (`.instruction` for setup, `.humanQuestion` for pass/fail observations).

5. **Register the script** in `AllScripts.swift`.

6. **Verify CI gates** via hooks-mcp: `precommit_checks` (lint + format + test), `build_app`, and `manual_tests_check`.

## Tests

- Structural tests added to `ScriptShapeTests.swift` for the new AI Features script (identity, step count, step IDs, uniqueness).
- `CIGateTests` satisfied by adding 18 `not-run` entries to the results JSON for the new recordable `ai_*` steps.
- The new `ai_*` steps appear as `not-run` in `manual_tests_check`, which is expected (the gate is non-gating).

## Deferred to human (on-hardware)

The following must be done on real Apple Silicon hardware to complete Phase 7:

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
12. **Fill in `ai_*` manual test results** — Record pass/fail for all 18 `ai_*` steps in `ManualTestApp/Results/manual_test_results.json`, then commit
