---
status: complete
---

# Phase 7: Docs + Final Pass (was Phase 6)

## Overview

Update the four documentation targets listed in architecture.md section 8. Verify that all `tx_*` manual-test steps exist in the results file and are marked `not-run`, ready for the human's on-hardware pass on macOS 26/27 and macOS 15.

## Steps

1. **`specs/research/stt-engine-swap/summary.md`** — (done in 074826e) added "Decision Outcome" section recording the dual-engine path.

2. **`CLAUDE.md`** — (done in 074826e) updated the current-stage paragraph and added the `apple_speech_engine` entry in "Process & planning records." Fixed the manual-test parenthetical: "except the pending `tx_*` hardware pass" → "70/70" (the pass is done).

3. **`experiments/STTLab/NOTES.md`** — (done in 074826e) added "Graduated" section.

4. **`specs/projects/initial_implementation/architecture.md`** — not edited (point-in-time record; later projects win).

5. **`README.md`** — updated the "Which AI does it use?" FAQ to list both engines (Apple Speech on macOS 26, Whisper via WhisperKit, user chooses during setup, Whisper only on macOS 15). Updated the "Which languages" FAQ to cover both engines.

6. **Manual-test pass** — the user ran all `tx_*` steps on macOS 27 (M2) and macOS 15; results committed. 70/70 steps pass (`make manual-tests-check` green).

## Tests

- No new tests (docs-only phase). Existing tests must still pass.
